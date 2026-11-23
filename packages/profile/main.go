// Command claude-profile makes a claude profile ready for a launch, and
// drops what one session can leave there for the next. claude-launch runs it
// on the host before every launch, outside the sandbox:
//
//	claude-profile prepare --config DIR --profile DIR [--os linux|darwin]
//	claude-profile project --dir DIR
//
// prepare makes the config (DIR/.claude of claude's config tree) own the
// profile's user-level config, and removes what a session could plant there:
// a session can write its profile, and what it leaves there loads into every
// later session of the profile, a credential or unsandboxed one included.
//   - rules/, agents/, commands/ and CLAUDE.md are links to the config's copy;
//     one the config lacks is removed.
//   - skills/ is removed whole: claude downloads the account's synced skills
//     into skills/synced again at every start, so nothing else belongs there.
//     plugins/synced goes for the same reason.
//   - settings.json is the config's settings.json with this OS's overlay
//     (settings.<os>.json) deep-merged over it. Running sessions of the
//     profile reload the file when it changes, and the sandbox pins it
//     read-only in each of them, on the file itself. So it is left alone when
//     it already says this, and otherwise written over in place, never
//     replaced, which would drop that pin. Anything there but a plain file of
//     its own (a link, a directory, a hard link) is removed first.
//   - The MCP servers in .claude.json, which start without approval, and the
//     plugins installed in the profile, which load at the next start, are
//     emptied.
//   - The directories the plugins' MCP servers keep their caches in, and
//     open-sessions/, where claude-launch makes the file claude-sessions
//     reads, are made directories of the profile's own.
//
// prepare only touches a directory that is its own: one it creates, an empty
// one, or one that holds its marker file. Anything else, ~/.claude say, whose
// CLAUDE.md, agents and skills prepare would delete, is refused.
//
// project cuts DIR/.claude/settings.local.json, which claude reads as project
// settings and a session can write, to what claude itself writes there: its
// "don't ask again" permission rules and the Show tips toggle.
//
// Every change goes through an os.Root opened on the profile or the project,
// so a link a session planted can't take a removal or a write outside them.
// It fails closed: what it can't read or write refuses the launch, with the
// reason on stderr and exit status 1.
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"math/rand/v2"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
)

// marker is the file prepare leaves in each profile it owns.
const marker = ".claude-launch"

// owned are the profile entries the config owns: each a link to the config's
// copy, or absent when the config has none.
var owned = []string{"rules", "agents", "commands", "CLAUDE.md"}

// dirs are the directories made in the profile for what runs in it:
// claude-shell-guard lets nothing claude starts create entries directly in the
// profile, so the caches the plugins' MCP servers keep there are made here, and
// claude-launch makes the file it locks for claude-sessions in open-sessions/.
var dirs = []string{".npm-cache", ".uv-cache", ".uv-tools", "open-sessions"}

const usage = `usage: claude-profile prepare --config DIR --profile DIR [--os linux|darwin]
       claude-profile project --dir DIR`

func main() {
	os.Exit(run(os.Args[1:], os.Getenv, os.Stderr))
}

func run(args []string, getenv func(string) string, stderr io.Writer) int {
	if len(args) == 0 {
		_, _ = fmt.Fprintln(stderr, usage)
		return 2
	}
	set := flag.NewFlagSet(args[0], flag.ContinueOnError)
	set.SetOutput(io.Discard)
	var err error
	switch args[0] {
	case "prepare":
		config := set.String("config", "", "")
		profile := set.String("profile", "", "")
		goos := set.String("os", "", "")
		if set.Parse(args[1:]) != nil || set.NArg() != 0 || *config == "" || *profile == "" {
			_, _ = fmt.Fprintln(stderr, usage)
			return 2
		}
		err = prepare(*config, *profile, *goos, getenv("HOME"), getenv("XDG_RUNTIME_DIR"), stderr)
	case "project":
		dir := set.String("dir", "", "")
		if set.Parse(args[1:]) != nil || set.NArg() != 0 || *dir == "" {
			_, _ = fmt.Fprintln(stderr, usage)
			return 2
		}
		err = project(*dir, stderr)
	default:
		_, _ = fmt.Fprintln(stderr, usage)
		return 2
	}
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "claude: %v\n", err)
		return 1
	}
	return 0
}

// tree is a directory the changes are confined to, through an os.Root.
type tree struct {
	root *os.Root
	dir  string
	out  io.Writer
}

func (t *tree) note(format string, args ...any) {
	_, _ = fmt.Fprintf(t.out, "claude: "+format+"\n", args...)
}

// path names entry name of the tree in a message.
func (t *tree) path(name string) string {
	return filepath.Join(t.dir, name)
}

func prepare(config, profile, goos, home, runtime string, stderr io.Writer) error {
	if !filepath.IsAbs(profile) {
		return fmt.Errorf("the profile %s is not an absolute path; refusing to launch", profile)
	}
	profile = filepath.Clean(profile)
	if profile == "/" || (home != "" && profile == filepath.Clean(home)) {
		return fmt.Errorf("the profile %s is the root or your home directory, which claude-profile does not prepare; refusing to launch", profile)
	}
	unlock, err := lock(runtime, profile)
	if err != nil {
		return err
	}
	defer unlock()
	if err := own(profile); err != nil {
		return err
	}
	root, err := os.OpenRoot(profile)
	if err != nil {
		return fmt.Errorf("could not open %s: %v; refusing to launch", profile, err)
	}
	defer func() { _ = root.Close() }()
	t := &tree{root: root, dir: profile, out: stderr}
	steps := []func() error{
		t.dirs,
		func() error { return t.links(config) },
		t.skills,
		t.syncedPlugins,
		func() error { return t.settings(config, goos) },
		t.mcpServers,
		t.installedPlugins,
	}
	for _, step := range steps {
		if err := step(); err != nil {
			return err
		}
	}
	return nil
}

// lock holds a lock on a file of the profile's in the runtime dir, which the
// sandbox does not share, so two launches of a profile can't interleave their
// changes. Without a runtime dir, nothing is locked.
func lock(runtime, profile string) (func(), error) {
	if runtime == "" {
		return func() {}, nil
	}
	name := filepath.Join(runtime, "claude-prepare"+strings.ReplaceAll(profile, "/", "%")+".lock")
	f, err := os.OpenFile(name, os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, fmt.Errorf("could not open the lock %s: %v; refusing to launch", name, err)
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		_ = f.Close()
		return nil, fmt.Errorf("could not lock %s: %v; refusing to launch", name, err)
	}
	return func() { _ = f.Close() }, nil
}

// own makes dir a profile of claude-profile's: it creates it, marked, or marks
// it when it is empty, and refuses one that holds files but no marker.
func own(dir string) error {
	entries, err := os.ReadDir(dir)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return fmt.Errorf("could not create %s: %v; refusing to launch", dir, err)
		}
	case err != nil:
		return fmt.Errorf("could not read %s: %v; refusing to launch", dir, err)
	case slices.ContainsFunc(entries, func(e fs.DirEntry) bool { return e.Name() == marker }):
		return nil
	case len(entries) > 0:
		return fmt.Errorf("%s holds files but no %s marker, so it may be a profile something else keeps, and preparing it deletes what claude's config doesn't provide; refusing to launch. If claude-launch is to manage it, run `touch %s` once", dir, marker, filepath.Join(dir, marker))
	}
	f, err := os.OpenFile(filepath.Join(dir, marker), os.O_WRONLY|os.O_CREATE, 0o600)
	if err != nil {
		return fmt.Errorf("could not mark %s: %v; refusing to launch", dir, err)
	}
	return f.Close()
}

// dirs makes each of dirs a directory of the profile's own: anything else in
// its place, a link out of the profile say, is removed first.
func (t *tree) dirs() error {
	for _, name := range dirs {
		info, err := t.root.Lstat(name)
		switch {
		case errors.Is(err, fs.ErrNotExist):
		case err != nil:
			return fmt.Errorf("could not read %s: %v; refusing to launch", t.path(name), err)
		case !info.IsDir():
			if err := t.root.Remove(name); err != nil {
				return fmt.Errorf("could not remove %s: %v; refusing to launch", t.path(name), err)
			}
			t.note("removed %s, which was not a directory of the profile's own", t.path(name))
		}
		if err := t.root.MkdirAll(name, 0o700); err != nil {
			return fmt.Errorf("could not create %s: %v; refusing to launch", t.path(name), err)
		}
	}
	return nil
}

// links makes each owned entry a link to the config's copy, removing what is
// there first, or removes it when the config has none.
func (t *tree) links(config string) error {
	for _, name := range owned {
		src := filepath.Join(config, name)
		_, err := os.Stat(src)
		has := err == nil
		if err != nil && !errors.Is(err, fs.ErrNotExist) {
			return fmt.Errorf("could not read %s: %v; refusing to launch", src, err)
		}
		info, err := t.root.Lstat(name)
		present := err == nil
		if err != nil && !errors.Is(err, fs.ErrNotExist) {
			return fmt.Errorf("could not read %s: %v; refusing to launch", t.path(name), err)
		}
		if present && has && info.Mode()&fs.ModeSymlink != 0 {
			if target, err := t.root.Readlink(name); err == nil && target == src {
				continue
			}
		}
		if present {
			if err := t.root.RemoveAll(name); err != nil {
				return fmt.Errorf("could not remove %s: %v; refusing to launch", t.path(name), err)
			}
		}
		if has {
			if err := t.root.Symlink(src, name); err != nil {
				return fmt.Errorf("could not link %s to %s: %v; refusing to launch", t.path(name), src, err)
			}
		} else if present {
			t.note("removed %s: claude's config has none, and a session can plant one for every later session", t.path(name))
		}
	}
	return nil
}

// skills removes skills/, saying what was there but the synced skills.
func (t *tree) skills() error {
	info, err := t.root.Lstat("skills")
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("could not read %s: %v; refusing to launch", t.path("skills"), err)
	}
	var planted []string
	switch {
	case info.Mode()&fs.ModeSymlink != 0:
		target, _ := t.root.Readlink("skills")
		planted = []string{"a link to " + target}
	case info.IsDir():
		names, err := t.list("skills")
		if err != nil {
			return err
		}
		for _, name := range names {
			if name != "synced" {
				planted = append(planted, name)
			}
		}
	default:
		planted = []string{"a file"}
	}
	if err := t.root.RemoveAll("skills"); err != nil {
		return fmt.Errorf("could not remove %s: %v; refusing to launch", t.path("skills"), err)
	}
	if len(planted) > 0 {
		t.note("removed %s from %s: a session can plant skills there for every later session", strings.Join(planted, " "), t.path("skills"))
	}
	return nil
}

// syncedPlugins removes plugins/synced: claude downloads the account's synced
// plugins into it at every start, and one there loads, hooks and MCP servers
// included. plugins/ itself is claude's; a link in its place is removed rather
// than followed.
func (t *tree) syncedPlugins() error {
	info, err := t.root.Lstat("plugins")
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("could not read %s: %v; refusing to launch", t.path("plugins"), err)
	}
	if !info.IsDir() {
		target, _ := t.root.Readlink("plugins")
		if err := t.root.Remove("plugins"); err != nil {
			return fmt.Errorf("could not remove %s: %v; refusing to launch", t.path("plugins"), err)
		}
		what := "a file"
		if target != "" {
			what = "a link to " + target
		}
		t.note("removed %s, %s: claude keeps its plugins in a directory there", t.path("plugins"), what)
		return nil
	}
	if err := t.root.RemoveAll("plugins/synced"); err != nil {
		return fmt.Errorf("could not remove %s: %v; refusing to launch", t.path("plugins/synced"), err)
	}
	return nil
}

func (t *tree) settings(config, goos string) error {
	base := filepath.Join(config, "settings.json")
	var overlay string
	if goos != "" {
		overlay = filepath.Join(config, "settings."+goos+".json")
	}
	merged, err := mergeFiles(base, overlay)
	if err != nil {
		return fmt.Errorf("could not merge %s over %s (%v); refusing to launch without the sandbox settings", overlay, base, err)
	}
	info, err := t.root.Lstat("settings.json")
	switch {
	case errors.Is(err, fs.ErrNotExist):
	case err != nil:
		return fmt.Errorf("could not read %s: %v; refusing to launch", t.path("settings.json"), err)
	case !info.Mode().IsRegular() || !singleLink(info):
		if err := t.root.RemoveAll("settings.json"); err != nil {
			return fmt.Errorf("could not remove %s: %v; refusing to launch", t.path("settings.json"), err)
		}
	default:
		if current, err := t.root.ReadFile("settings.json"); err == nil && bytes.Equal(current, merged) {
			return nil
		}
	}
	f, err := t.root.OpenFile("settings.json", os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return fmt.Errorf("could not write %s: %v; refusing to launch without the sandbox settings", t.path("settings.json"), err)
	}
	if _, err := f.Write(merged); err != nil {
		_ = f.Close()
		return fmt.Errorf("could not write %s: %v; refusing to launch without the sandbox settings", t.path("settings.json"), err)
	}
	return f.Close()
}

func singleLink(info fs.FileInfo) bool {
	st, ok := info.Sys().(*syscall.Stat_t)
	return !ok || st.Nlink == 1
}

func (t *tree) mcpServers() error {
	const name = ".claude.json"
	doc, ok, err := t.readObject(name, "the MCP servers it may name")
	if err != nil || !ok {
		return err
	}
	var names []string
	empty := func(holder map[string]any) {
		if servers, ok := holder["mcpServers"].(map[string]any); ok && len(servers) > 0 {
			for server := range servers {
				names = append(names, server)
			}
			holder["mcpServers"] = map[string]any{}
		}
	}
	empty(doc)
	if projects, ok := doc["projects"].(map[string]any); ok {
		for _, p := range projects {
			if p, ok := p.(map[string]any); ok {
				empty(p)
			}
		}
	}
	if len(names) == 0 {
		return nil
	}
	if err := t.writeObject(name, doc); err != nil {
		return err
	}
	slices.Sort(names)
	t.note("removed the MCP servers %s from %s: they would start without approval", strings.Join(slices.Compact(names), ", "), t.path(name))
	return nil
}

func (t *tree) installedPlugins() error {
	const name = "plugins/installed_plugins.json"
	doc, ok, err := t.readObject(name, "the plugins it may name")
	if err != nil || !ok {
		return err
	}
	plugins, _ := doc["plugins"].(map[string]any)
	if len(plugins) == 0 {
		return nil
	}
	names := make([]string, 0, len(plugins))
	for plugin := range plugins {
		names = append(names, plugin)
	}
	slices.Sort(names)
	doc["plugins"] = map[string]any{}
	if err := t.writeObject(name, doc); err != nil {
		return err
	}
	t.note("removed the plugins %s from %s: they would load at the next start", strings.Join(names, ", "), t.path(name))
	return nil
}

func project(dir string, stderr io.Writer) error {
	root, err := os.OpenRoot(dir)
	if err != nil {
		return fmt.Errorf("could not open %s: %v; refusing to launch", dir, err)
	}
	defer func() { _ = root.Close() }()
	t := &tree{root: root, dir: dir, out: stderr}
	const name = ".claude/settings.local.json"
	doc, ok, err := t.readObject(name, "the settings it may hold")
	if err != nil || !ok {
		return err
	}
	var dropped []string
	for key := range doc {
		if key != "permissions" && key != "spinnerTipsEnabled" {
			dropped = append(dropped, key)
			delete(doc, key)
		}
	}
	if perms, ok := doc["permissions"].(map[string]any); ok {
		for key := range perms {
			if key != "allow" && key != "deny" && key != "ask" {
				dropped = append(dropped, "permissions."+key)
				delete(perms, key)
			}
		}
	}
	if len(dropped) == 0 {
		return nil
	}
	if err := t.writeObject(name, doc); err != nil {
		return err
	}
	slices.Sort(dropped)
	t.note("dropped %s from %s: claude writes only its permission rules there", strings.Join(dropped, ", "), t.path(name))
	return nil
}

// readObject reads the JSON object in name; ok is false when there is none.
// A file that isn't plain, or isn't a JSON object, refuses the launch with
// what it may carry.
func (t *tree) readObject(name, carries string) (doc map[string]any, ok bool, err error) {
	info, err := t.root.Lstat(name)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, false, nil
	}
	if err == nil && !info.Mode().IsRegular() {
		err = errors.New("not a plain file")
	}
	var data []byte
	if err == nil {
		data, err = t.root.ReadFile(name)
	}
	if err == nil {
		doc, err = decodeObject(data)
	}
	if err != nil {
		return nil, false, fmt.Errorf("could not read %s (%v); refusing to launch with %s", t.path(name), err, carries)
	}
	return doc, true, nil
}

// writeObject replaces name with doc, atomically: a file of its own beside
// it, then a rename.
func (t *tree) writeObject(name string, doc map[string]any) error {
	data, err := encode(doc)
	if err == nil {
		tmp := name + "." + strconv.FormatUint(rand.Uint64(), 36)
		var f *os.File
		if f, err = t.root.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600); err == nil {
			_, err = f.Write(data)
			if cerr := f.Close(); err == nil {
				err = cerr
			}
			if err == nil {
				err = t.root.Rename(tmp, name)
			}
			if err != nil {
				_ = t.root.Remove(tmp)
			}
		}
	}
	if err != nil {
		return fmt.Errorf("could not rewrite %s: %v; refusing to launch", t.path(name), err)
	}
	return nil
}

// mergeFiles is the JSON object in base with the one in overlay, when named,
// deep-merged over it (jq's `*`): objects merge key by key, and anything else
// in the overlay replaces what base has.
func mergeFiles(base, overlay string) ([]byte, error) {
	doc, err := readObjectFile(base)
	if err != nil {
		return nil, err
	}
	if overlay != "" {
		over, err := readObjectFile(overlay)
		if err != nil {
			return nil, err
		}
		doc = merge(doc, over).(map[string]any)
	}
	return encode(doc)
}

func readObjectFile(name string) (map[string]any, error) {
	data, err := os.ReadFile(name)
	if err != nil {
		return nil, err
	}
	doc, err := decodeObject(data)
	if err != nil {
		return nil, fmt.Errorf("%s: %v", name, err)
	}
	return doc, nil
}

func merge(a, b any) any {
	am, aok := a.(map[string]any)
	bm, bok := b.(map[string]any)
	if !aok || !bok {
		return b
	}
	out := make(map[string]any, len(am)+len(bm))
	for k, v := range am {
		out[k] = v
	}
	for k, v := range bm {
		if old, ok := out[k]; ok {
			out[k] = merge(old, v)
		} else {
			out[k] = v
		}
	}
	return out
}

// decodeObject reads one JSON object, keeping numbers as written.
func decodeObject(data []byte) (map[string]any, error) {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		return nil, err
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return nil, errors.New("more than one JSON value")
	}
	doc, ok := v.(map[string]any)
	if !ok {
		return nil, errors.New("not a JSON object")
	}
	return doc, nil
}

// encode writes doc as indented JSON, with a final newline, and with <, > and
// & as they are.
func encode(doc any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(doc); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func (t *tree) list(name string) ([]string, error) {
	f, err := t.root.Open(name)
	if err != nil {
		return nil, fmt.Errorf("could not read %s: %v; refusing to launch", t.path(name), err)
	}
	defer func() { _ = f.Close() }()
	entries, err := f.ReadDir(-1)
	if err != nil {
		return nil, fmt.Errorf("could not read %s: %v; refusing to launch", t.path(name), err)
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		names = append(names, e.Name())
	}
	slices.Sort(names)
	return names, nil
}
