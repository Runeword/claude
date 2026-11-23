package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"testing"
)

func write(t *testing.T, path, data string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(data), 0o644); err != nil {
		t.Fatal(err)
	}
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func readJSON(t *testing.T, path string) map[string]any {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]any
	if err := json.Unmarshal(data, &doc); err != nil {
		t.Fatalf("%s: %v", path, err)
	}
	return doc
}

func inode(t *testing.T, path string) uint64 {
	t.Helper()
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	return uint64(info.Sys().(*syscall.Stat_t).Ino)
}

// config is a claude config with rules/ and commands/ but no agents/ or
// CLAUDE.md, settings and a Linux overlay.
func config(t *testing.T) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), ".claude")
	write(t, filepath.Join(dir, "rules", "a.md"), "rule")
	write(t, filepath.Join(dir, "commands", "x.md"), "command")
	write(t, filepath.Join(dir, "settings.json"), `{"hooks": {"Stop": []}, "sandbox": {"enabled": true, "network": {"a": 1}}, "env": {"A": "1"}}`)
	write(t, filepath.Join(dir, "settings.linux.json"), `{"sandbox": {"enabled": false}}`)
	return dir
}

func prepareIn(t *testing.T, cfg, profile string) (string, error) {
	t.Helper()
	var stderr bytes.Buffer
	err := prepare(cfg, profile, "linux", "/home/nobody", t.TempDir(), &stderr)
	return stderr.String(), err
}

func TestMerge(t *testing.T) {
	cases := []struct {
		name       string
		base, over string
		want       string
	}{
		{"objects merge key by key", `{"a": {"x": 1, "y": 2}, "b": 1}`, `{"a": {"y": 3, "z": 4}}`, `{"a": {"x": 1, "y": 3, "z": 4}, "b": 1}`},
		{"an array replaces an array", `{"a": [1, 2]}`, `{"a": [3]}`, `{"a": [3]}`},
		{"a scalar replaces an object", `{"a": {"x": 1}}`, `{"a": false}`, `{"a": false}`},
		{"an object replaces a scalar", `{"a": 1}`, `{"a": {"x": 1}}`, `{"a": {"x": 1}}`},
		{"null replaces a value", `{"a": 1}`, `{"a": null}`, `{"a": null}`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			dir := t.TempDir()
			write(t, filepath.Join(dir, "base.json"), c.base)
			write(t, filepath.Join(dir, "over.json"), c.over)
			got, err := mergeFiles(filepath.Join(dir, "base.json"), filepath.Join(dir, "over.json"))
			if err != nil {
				t.Fatal(err)
			}
			var gotDoc, wantDoc any
			must(t, json.Unmarshal(got, &gotDoc))
			must(t, json.Unmarshal([]byte(c.want), &wantDoc))
			if !reflect.DeepEqual(gotDoc, wantDoc) {
				t.Errorf("got %s, want %s", got, c.want)
			}
		})
	}
}

func TestMergeKeepsTextAsWritten(t *testing.T) {
	dir := t.TempDir()
	write(t, filepath.Join(dir, "base.json"), `{"n": 12345678901234567890, "s": "<a & b>"}`)
	got, err := mergeFiles(filepath.Join(dir, "base.json"), "")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(got), "12345678901234567890") || !strings.Contains(string(got), `"<a & b>"`) {
		t.Errorf("numbers or characters changed: %s", got)
	}
}

func TestMergeRefuses(t *testing.T) {
	cases := []struct{ name, base, over string }{
		{"an overlay that isn't JSON", `{}`, `not json`},
		{"an overlay that isn't an object", `{}`, `[1]`},
		{"settings that aren't an object", `"x"`, `{}`},
		{"two values in one file", `{} {}`, `{}`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			dir := t.TempDir()
			write(t, filepath.Join(dir, "base.json"), c.base)
			write(t, filepath.Join(dir, "over.json"), c.over)
			if _, err := mergeFiles(filepath.Join(dir, "base.json"), filepath.Join(dir, "over.json")); err == nil {
				t.Error("merged")
			}
		})
	}
}

func TestOwn(t *testing.T) {
	cases := []struct {
		name  string
		setup func(t *testing.T, dir string)
		ok    bool
	}{
		{"a directory that isn't there is created", func(*testing.T, string) {}, true},
		{"an empty directory is adopted", func(t *testing.T, dir string) { must(t, os.Mkdir(dir, 0o700)) }, true},
		{"a marked directory is its own", func(t *testing.T, dir string) {
			write(t, filepath.Join(dir, marker), "")
			write(t, filepath.Join(dir, "CLAUDE.md"), "")
		}, true},
		{"a directory with files and no marker is refused", func(t *testing.T, dir string) {
			write(t, filepath.Join(dir, "CLAUDE.md"), "")
		}, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			dir := filepath.Join(t.TempDir(), "profile")
			c.setup(t, dir)
			err := own(dir)
			if (err == nil) != c.ok {
				t.Fatalf("own: %v, want ok=%v", err, c.ok)
			}
			_, merr := os.Stat(filepath.Join(dir, marker))
			if c.ok && merr != nil {
				t.Error("no marker left")
			}
			if !c.ok {
				if _, err := os.Stat(filepath.Join(dir, "CLAUDE.md")); err != nil {
					t.Error("touched a directory it refused")
				}
			}
		})
	}
}

func TestPrepareRefuses(t *testing.T) {
	cfg := config(t)
	cases := []struct{ name, profile, want string }{
		{"a relative profile", "profile", "not an absolute path"},
		{"the home directory", "/home/nobody/", "home directory"},
		{"the root", "/", "home directory"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if _, err := prepareIn(t, cfg, c.profile); err == nil || !strings.Contains(err.Error(), c.want) {
				t.Errorf("prepare: %v, want %q", err, c.want)
			}
		})
	}
}

func TestPrepare(t *testing.T) {
	cfg := config(t)
	outside := t.TempDir()
	write(t, filepath.Join(outside, "synced", "keep"), "outside")
	profile := filepath.Join(t.TempDir(), "profile")
	write(t, filepath.Join(profile, marker), "")
	// What a session can plant.
	write(t, filepath.Join(profile, "rules", "planted.md"), "planted")
	write(t, filepath.Join(profile, "agents", "a.md"), "planted")
	write(t, filepath.Join(profile, "CLAUDE.md"), "planted")
	write(t, filepath.Join(profile, "skills", "planted", "SKILL.md"), "planted")
	write(t, filepath.Join(profile, "skills", "synced", "s", "SKILL.md"), "synced")
	if err := os.Symlink(outside, filepath.Join(profile, "plugins")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(profile, "open-sessions")); err != nil {
		t.Fatal(err)
	}
	write(t, filepath.Join(profile, ".claude.json"), `{"mcpServers": {"a": {}}, "projects": {"/p": {"mcpServers": {"b": {}}, "allowedTools": []}}, "numStartups": 3}`)

	said, err := prepareIn(t, cfg, profile)
	if err != nil {
		t.Fatalf("prepare: %v (%s)", err, said)
	}
	for _, name := range []string{"rules", "commands"} {
		if target, err := os.Readlink(filepath.Join(profile, name)); err != nil || target != filepath.Join(cfg, name) {
			t.Errorf("%s links to %q (%v), want the config's", name, target, err)
		}
	}
	for _, name := range []string{"agents", "CLAUDE.md", "skills", "plugins"} {
		if _, err := os.Lstat(filepath.Join(profile, name)); err == nil {
			t.Errorf("%s is still there", name)
		}
	}
	if _, err := os.Stat(filepath.Join(outside, "synced", "keep")); err != nil {
		t.Error("followed the plugins link out of the profile")
	}
	for _, want := range []string{"agents: claude's config has none", "CLAUDE.md: claude's config has none", "removed planted from", "a link to " + outside, "the MCP servers a, b"} {
		if !strings.Contains(said, want) {
			t.Errorf("didn't say %q: %s", want, said)
		}
	}
	if strings.Contains(said, "synced from") {
		t.Errorf("reported the synced skills as planted: %s", said)
	}
	for _, name := range dirs {
		if info, err := os.Lstat(filepath.Join(profile, name)); err != nil || !info.IsDir() {
			t.Errorf("no %s directory", name)
		}
	}
	settings := readJSON(t, filepath.Join(profile, "settings.json"))
	if got := settings["sandbox"].(map[string]any)["enabled"]; got != false {
		t.Errorf("the overlay didn't apply: sandbox.enabled is %v", got)
	}
	if _, ok := settings["sandbox"].(map[string]any)["network"]; !ok {
		t.Error("the overlay replaced the sandbox object instead of merging into it")
	}
	state := readJSON(t, filepath.Join(profile, ".claude.json"))
	if len(state["mcpServers"].(map[string]any)) != 0 || len(state["projects"].(map[string]any)["/p"].(map[string]any)["mcpServers"].(map[string]any)) != 0 {
		t.Errorf("MCP servers left: %v", state)
	}
	if state["numStartups"] == nil || state["projects"].(map[string]any)["/p"].(map[string]any)["allowedTools"] == nil {
		t.Errorf("dropped what claude keeps there: %v", state)
	}

	// A second launch finds nothing to do and says nothing.
	if said, err := prepareIn(t, cfg, profile); err != nil || said != "" {
		t.Errorf("second prepare: %v, said %q", err, said)
	}
}

func TestPrepareReplacesLinksOut(t *testing.T) {
	cfg := config(t)
	outside := t.TempDir()
	write(t, filepath.Join(outside, "rules", "keep.md"), "outside")
	write(t, filepath.Join(outside, "CLAUDE.md"), "outside")
	profile := filepath.Join(t.TempDir(), "profile")
	write(t, filepath.Join(profile, marker), "")
	must(t, os.Symlink(filepath.Join(outside, "rules"), filepath.Join(profile, "rules")))
	must(t, os.Symlink(filepath.Join(outside, "CLAUDE.md"), filepath.Join(profile, "CLAUDE.md")))
	must(t, os.Symlink(outside, filepath.Join(profile, "skills")))
	if said, err := prepareIn(t, cfg, profile); err != nil {
		t.Fatalf("prepare: %v (%s)", err, said)
	}
	if target, _ := os.Readlink(filepath.Join(profile, "rules")); target != filepath.Join(cfg, "rules") {
		t.Errorf("rules links to %q", target)
	}
	for _, name := range []string{"CLAUDE.md", "skills"} {
		if _, err := os.Lstat(filepath.Join(profile, name)); err == nil {
			t.Errorf("%s is still there", name)
		}
	}
	for _, name := range []string{"rules/keep.md", "CLAUDE.md"} {
		if _, err := os.Stat(filepath.Join(outside, name)); err != nil {
			t.Errorf("removed %s through a link out of the profile", name)
		}
	}
}

func TestPrepareSettingsInPlace(t *testing.T) {
	cfg := config(t)
	cases := []struct {
		name  string
		setup func(t *testing.T, file string) (check func(t *testing.T))
	}{
		{"a file that says something else is written over in place", func(t *testing.T, file string) func(t *testing.T) {
			write(t, file, `{"hooks": {"Stop": [{"planted": true}]}}`)
			before := inode(t, file)
			return func(t *testing.T) {
				if inode(t, file) != before {
					t.Error("replaced the file instead of writing it in place")
				}
			}
		}},
		{"a file that already says it is left alone", func(t *testing.T, file string) func(t *testing.T) {
			want, err := mergeFiles(filepath.Join(cfg, "settings.json"), filepath.Join(cfg, "settings.linux.json"))
			if err != nil {
				t.Fatal(err)
			}
			write(t, file, string(want))
			must(t, os.Chmod(file, 0o444))
			return func(t *testing.T) {}
		}},
		{"a link is replaced, not written through", func(t *testing.T, file string) func(t *testing.T) {
			other := filepath.Join(t.TempDir(), "other.json")
			write(t, other, "kept")
			must(t, os.Symlink(other, file))
			return func(t *testing.T) {
				if data, _ := os.ReadFile(other); string(data) != "kept" {
					t.Error("wrote through the link")
				}
			}
		}},
		{"a hard link is replaced, not written through", func(t *testing.T, file string) func(t *testing.T) {
			other := filepath.Join(t.TempDir(), "other.json")
			write(t, other, "kept")
			must(t, os.Link(other, file))
			return func(t *testing.T) {
				if data, _ := os.ReadFile(other); string(data) != "kept" {
					t.Error("wrote through the hard link")
				}
			}
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			profile := filepath.Join(t.TempDir(), "profile")
			write(t, filepath.Join(profile, marker), "")
			file := filepath.Join(profile, "settings.json")
			check := c.setup(t, file)
			if said, err := prepareIn(t, cfg, profile); err != nil {
				t.Fatalf("prepare: %v (%s)", err, said)
			}
			check(t)
			info, err := os.Lstat(file)
			if err != nil || !info.Mode().IsRegular() {
				t.Fatalf("settings.json is not a plain file: %v", err)
			}
			if got := readJSON(t, file)["sandbox"].(map[string]any)["enabled"]; got != false {
				t.Errorf("sandbox.enabled is %v", got)
			}
		})
	}
}

func TestPrepareRefusesWhatItCannotRead(t *testing.T) {
	cases := []struct {
		name  string
		setup func(t *testing.T, cfg, profile string)
		want  string
	}{
		{"an overlay that doesn't merge", func(t *testing.T, cfg, _ string) {
			write(t, filepath.Join(cfg, "settings.linux.json"), "not json")
		}, "could not merge"},
		{"a missing overlay", func(t *testing.T, cfg, _ string) {
			must(t, os.Remove(filepath.Join(cfg, "settings.linux.json")))
		}, "could not merge"},
		{"a .claude.json that isn't JSON", func(t *testing.T, _, profile string) {
			write(t, filepath.Join(profile, ".claude.json"), "{")
		}, "the MCP servers it may name"},
		{"a .claude.json that isn't a plain file", func(t *testing.T, _, profile string) {
			must(t, os.Mkdir(filepath.Join(profile, ".claude.json"), 0o700))
		}, "the MCP servers it may name"},
		{"an installed_plugins.json that isn't JSON", func(t *testing.T, _, profile string) {
			write(t, filepath.Join(profile, "plugins", "installed_plugins.json"), "[")
		}, "the plugins it may name"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			cfg := config(t)
			profile := filepath.Join(t.TempDir(), "profile")
			write(t, filepath.Join(profile, marker), "")
			c.setup(t, cfg, profile)
			if _, err := prepareIn(t, cfg, profile); err == nil || !strings.Contains(err.Error(), c.want) {
				t.Errorf("prepare: %v, want %q", err, c.want)
			}
		})
	}
}

func TestPrepareInstalledPlugins(t *testing.T) {
	cfg := config(t)
	profile := filepath.Join(t.TempDir(), "profile")
	write(t, filepath.Join(profile, marker), "")
	write(t, filepath.Join(profile, "plugins", "installed_plugins.json"), `{"version": 2, "plugins": {"planted@market": [{}]}}`)
	write(t, filepath.Join(profile, "plugins", "synced", "bucket", "planted", "plugin.json"), "{}")
	said, err := prepareIn(t, cfg, profile)
	if err != nil {
		t.Fatal(err)
	}
	doc := readJSON(t, filepath.Join(profile, "plugins", "installed_plugins.json"))
	if len(doc["plugins"].(map[string]any)) != 0 || doc["version"] == nil {
		t.Errorf("installed_plugins.json: %v", doc)
	}
	if _, err := os.Stat(filepath.Join(profile, "plugins", "synced")); err == nil {
		t.Error("plugins/synced is still there")
	}
	if !strings.Contains(said, "removed the plugins planted@market") {
		t.Errorf("didn't say which plugins it removed: %s", said)
	}
}

func TestProject(t *testing.T) {
	cases := []struct {
		name  string
		local string
		want  string
		said  string
	}{
		{
			"keeps claude's permission rules and the tips toggle",
			`{"hooks": {}, "spinnerTipsEnabled": false, "permissions": {"allow": ["Bash(ls)"], "defaultMode": "bypassPermissions"}}`,
			`{"permissions":{"allow":["Bash(ls)"]},"spinnerTipsEnabled":false}`,
			"dropped hooks, permissions.defaultMode",
		},
		{
			"leaves settings with nothing else alone",
			`{"permissions": {"deny": ["Read(x)"]}}`,
			`{"permissions":{"deny":["Read(x)"]}}`,
			"",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			dir := t.TempDir()
			file := filepath.Join(dir, ".claude", "settings.local.json")
			write(t, file, c.local)
			var stderr bytes.Buffer
			if err := project(dir, &stderr); err != nil {
				t.Fatal(err)
			}
			got, _ := json.Marshal(readJSON(t, file))
			if string(got) != c.want {
				t.Errorf("got %s, want %s", got, c.want)
			}
			if !strings.Contains(stderr.String(), c.said) || (c.said == "" && stderr.Len() > 0) {
				t.Errorf("said %q, want %q", stderr.String(), c.said)
			}
		})
	}
}

func TestProjectRefusesALinkOut(t *testing.T) {
	outside := t.TempDir()
	write(t, filepath.Join(outside, "settings.local.json"), `{"hooks": {}}`)
	dir := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(dir, ".claude")); err != nil {
		t.Fatal(err)
	}
	if err := project(dir, &bytes.Buffer{}); err == nil {
		t.Error("read the project's settings through a link out of it")
	}
	if data, _ := os.ReadFile(filepath.Join(outside, "settings.local.json")); string(data) != `{"hooks": {}}` {
		t.Error("rewrote a file outside the project")
	}
}

func TestProjectWithoutSettings(t *testing.T) {
	if err := project(t.TempDir(), &bytes.Buffer{}); err != nil {
		t.Error(err)
	}
}

func TestRun(t *testing.T) {
	cases := []struct {
		name string
		args []string
		want int
	}{
		{"no command", nil, 2},
		{"an unknown command", []string{"wipe"}, 2},
		{"prepare without a profile", []string{"prepare", "--config", "/c"}, 2},
		{"project with an argument too many", []string{"project", "--dir", "/d", "x"}, 2},
		{"prepare, refused", []string{"prepare", "--config", "/c", "--profile", "relative"}, 1},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := run(c.args, func(string) string { return "" }, &bytes.Buffer{}); got != c.want {
				t.Errorf("exit %d, want %d", got, c.want)
			}
		})
	}
}
