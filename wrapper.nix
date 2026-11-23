# The claude wrapper: Claude Code with this repository's config (sources/.claude)
# and the tools its settings, hooks and plugins call on its PATH. flake.nix
# builds it through lib.mkClaude, for packages.default and for consumers such as
# github:Runeword/terminal.
{
  pkgs,
  files,
  permeance,
  # The git that the git shim runs once a command passes the allowlist:
  # nixpkgs' by default, the terminal's wrapped one (its bundled config) there.
  git,
  nixpkgs,
  nix-index-database,
  # github:Runeword/lefthook, whose toolchain puts a repository's formatters on
  # claude's PATH for claude-format.
  lefthook,
  # The lefthook hooks of that repository, as its dev shell enables them (a
  # lefthook-hooks.nix): this one's by default, the terminal's there.
  lefthookHooks,
  # github:Runeword/claude-sandbox's packages for this system.
  claudeSandbox,
}:

let
  claudeStatusline = import ./packages/statusline { inherit pkgs; };
  claudeDocsGuard = import ./packages/docs-guard { inherit pkgs; };
  # Its `mark` is the SessionStart hook that names the open session to the
  # backup and restore (packages/sessions/open.go).
  claudeSessions = import ./packages/sessions { inherit pkgs; };
  # Holds Claude's memory changes until its work is done: the memory-gate
  # plugin's PreToolUse, Stop and UserPromptSubmit hooks run it
  # (packages/memory-gate/main.go).
  claudeMemoryGate = import ./packages/memory-gate { inherit pkgs; };
  # CLAUDE_CODE_SHELL_PREFIX: runs every shell command, hook and MCP server
  # Claude Code starts under Landlock, with the config folders' projects/, which
  # holds memory, read-only (packages/shell-guard/main.go).
  claudeShellGuard = import ./packages/shell-guard { inherit pkgs; };
  # The PreToolUse hook on the read-only Explore agent's Bash: lets through only
  # commands that read (packages/explore-guard/main.go).
  claudeExploreGuard = import ./packages/explore-guard { inherit pkgs; };
  # The read-only Explore agent, which replaces the built-in one, as claude's
  # --agents value. Its hook runs the guard above by store path, so a claude
  # only ever loads the agent that its own build enforces
  # (packages/explore-guard/agent.nix).
  exploreAgents = builtins.toJSON {
    Explore = import ./packages/explore-guard/agent.nix { guard = claudeExploreGuard; };
  };
  gitAllowlistHook = claudeSandbox.git-allowlist-hook;
  # Point the shim at the wrapped git so config (excludesFile, pager, includes,
  # GIT_CONFIG_GLOBAL) applies whether git is invoked from claude or from the
  # interactive shell. The allowlist check still runs first on the same argv.
  gitShim = claudeSandbox.git-shim.override { realGit = "${git}/bin/git"; };
  playwrightMcpPkg = import ./packages/playwright-mcp.nix { inherit pkgs; };
  # claude-format (sources/.claude/hooks/format.sh) runs the formatters a
  # repository's lefthook config defines, through lefthook. Here those are the
  # format hooks of lefthookHooks, whose tools and lefthook go on claude's PATH,
  # so the hook finds them in a session started outside the dev shell too. Only
  # the format hooks: the whole toolchain also carries auto-commit, which
  # commits.
  lefthookLib = lefthook.lib.${pkgs.stdenv.hostPlatform.system};
  formatToolchain = lefthookLib.toolchain {
    hooks = pkgs.lib.filterAttrs (name: _: pkgs.lib.hasPrefix "format-" name) lefthookHooks;
  };
  # That repository's lefthook config, as its dev shell renders it, for the
  # smoke test's run of claude-format.
  repoLefthookConfig = (lefthookLib.mkShell { hooks = lefthookHooks; }).lefthookConfig;
  # The Playwright MCP's browser_run_code_unsafe runs any JavaScript in the
  # server's own process, which on macOS is outside Claude Code's sandbox. Denied
  # by glob for any server that offers it, and by full name for the plugin
  # shipped here too, so a narrower reading of the glob still covers that one.
  denyPlaywrightUnsafe = [
    "mcp__*__browser_run_code_unsafe"
    "mcp__plugin_playwright-mcp_playwright-mcp__browser_run_code_unsafe"
  ];

  tools = [
    claudeStatusline
    claudeDocsGuard
    claudeSessions
    claudeMemoryGate
    claudeShellGuard
    gitAllowlistHook
    pkgs.nixfmt
    pkgs.shfmt
    pkgs.go
    pkgs.taplo
    pkgs.rtk
    pkgs.nil
    pkgs.typescript-language-server
    pkgs.gopls
    pkgs.bash-language-server
    pkgs.lua-language-server
    pkgs.yaml-language-server
    pkgs.terraform-ls
    pkgs.marksman
    pkgs.vscode-langservers-extracted
    pkgs.shellcheck
    # claude-format reads its input and lefthook's config with jq: listed so the
    # hook doesn't depend on the caller's PATH.
    pkgs.jq
    # firebase CLI on claude's PATH so sessions can run `firebase …`. The
    # terminal ships it for the interactive shell too (usually inherited here),
    # but it is listed so availability doesn't depend on the caller's PATH.
    # Auth is a scoped service account, not your personal `firebase login`:
    # CLAUDE_SANDBOX_ALLOW_FIREBASE=1 (`firebase` in the leader `cc` picker,
    # wired through the terminal's claude.bash) makes claude-sandbox.bash read
    # the least-privilege SA key from `pass` (entry claude/firebase-sa-key) and
    # mount it read-only as Application Default Credentials for that session;
    # ~/.config/configstore stays masked. On macOS, claude-macos.bash hands it
    # over instead.
    pkgs.firebase-tools
    # jira-cli, listed for the same reason. Auth: CLAUDE_SANDBOX_ALLOW_JIRA=1
    # (`jira` in the `cc` picker) makes claude-sandbox.bash export claude's own
    # API token from `pass` (entry claude/jira-token, not your alias's
    # JIRA_API_TOKEN) as JIRA_API_TOKEN and point JIRA_CONFIG_FILE at the
    # session's own config, ~/.config/.jira/claude.yml. On macOS,
    # claude-macos.bash does.
    pkgs.jira-cli-go
    # comma with nix-index-database's prebuilt index: `, -p <cmd>` names the
    # nixpkgs packages that ship bin/<cmd>, offline. The always-on rule
    # sources/.claude/rules/nix-run.md has claude look a missing command up this
    # way, then run it with `nix shell` from the nixpkgs pinned below, never
    # install it.
    nix-index-database.packages.${pkgs.stdenv.hostPlatform.system}.comma-with-db
    # Runtimes for MCP servers launched from a plugin .mcp.json rather than being
    # Nix-packaged: nodejs/npx for figma-mcp; uv/uvx + python for the pure-Python
    # servers (nix-mcp, aws-api-mcp, google-workspace-mcp). uvx fetches the pinned
    # server from PyPI at run time (cached under $CLAUDE_CONFIG_DIR); python312 with
    # UV_PYTHON_PREFERENCE=only-system avoids a managed-Python download and gives
    # broad wheel coverage. playwright-mcp stays Nix-packaged because its browsers
    # come from nixpkgs and its wrapper gives it the scratch home they need.
    pkgs.nodejs
    pkgs.uv
    pkgs.python312
    playwrightMcpPkg
  ]
  ++ formatToolchain
  # Deps for claude's built-in `/sandbox` on Linux (Seatbelt is built in on macOS).
  # Recent claude-code turns that sandbox ON by default when these sit on PATH; it
  # can't nest inside the bubblewrap jail (claude-sandbox.bash passes
  # --disable-userns), so sources/.claude/settings.linux.json switches it back off
  # at user scope. Kept on PATH so /sandbox (project-local scope, above user) can
  # still opt an unsandboxed (CLAUDE_SANDBOX=0) session back in.
  ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
    pkgs.bubblewrap
    pkgs.socat
  ];

  # The config tree the launcher reads, and the copy of it the terminal's
  # claude.bash provisions each claude profile from (its rules/ and commands/
  # linked, settings.json merged with this OS's overlay) and loads the plugins
  # from, unless CLAUDE_SOURCES_ROOT names a live one.
  config = files.mkConfig "claude-config" [
    ".claude/rules"
    # User-level skills, such as /x: claude.bash clears the profile's
    # skills/ at each launch, so they ship as commands/<name>.md files.
    ".claude/commands"
    ".claude/plugins"
    ".claude/settings.json"
    # The per-OS sandbox overlays claude.bash merges into each profile.
    ".claude/settings.linux.json"
    ".claude/settings.darwin.json"
    ".claude/git-allowlist.toml"

    # Renamed and installed under bin/ so it's PATH-resolvable from
    # settings.json hooks (which invoke it as `claude-format`).
    {
      source = ".claude/hooks/format.sh";
      target = "bin/claude-format";
    }
  ];

  # claude's PATH, ahead of the inherited one (permeance.out: the launcher's $out).
  # gitShim ships a binary named `git`. It is injected only into claude's own
  # PATH (and inherited by its subprocesses: bash, Python, Make, …), not merged
  # into $out/bin, so the user's interactive shell still sees the wrapped git.
  # Prefixed first so it wins over git-with-config within claude's process
  # tree. The shim enforces the same allowlist policy as git-allowlist-hook,
  # then exec's the real git. One directory per element: permeance rejects a
  # ':'-joined makeBinPath string.
  pathPrefix = [
    "${gitShim}/bin"
    "${permeance.out}/bin"
  ]
  ++ map (pkg: "${pkgs.lib.getBin pkg}/bin") tools;

  self = pkgs.symlinkJoin {
    name = "claude-with-config";
    paths = [
      pkgs.claude-code
      config
    ];
    postBuild = permeance.installLauncher {
      binName = "claude";
      compiled = true;
      # A namespace of its own: CLAUDE_SOURCES_ROOT names a live copy of this
      # repository's sources/ (CLAUDE_SOURCES_TREE is what the launcher
      # resolved), and the PERMEANCE_ROOT of the tree claude runs from, say the
      # terminal's, which has no .claude, reaches claude's children untouched
      # instead of redirecting it there. Unset, claude reads the copy in the
      # store, which no session can edit.
      namespace = "CLAUDE_SOURCES";
      inherit pathPrefix;
      configEnv = {
        CLAUDE_GIT_ALLOWLIST_CONFIG = ".claude/git-allowlist.toml";
      };
      staticEnv = {
        RTK_TELEMETRY_DISABLED = "1";
        # The nixpkgs claude runs missing commands from: this flake's locked
        # input, already in the store, so resolving it downloads nothing (plain
        # `nixpkgs#` goes through the host's registry: maybe another revision,
        # and a fresh fetch each sandbox session, whose ~/.cache/nix starts cold)
        # and a tool on claude's PATH, or one a flake that has this one's nixpkgs
        # follow its own ships, resolves to the very same build. comma reads it
        # too, but only when NIX_PATH has no nixpkgs= entry, which is why the
        # rule runs through `nix shell` instead of `, <cmd>`.
        COMMA_NIXPKGS_FLAKE = "path:${nixpkgs}";
        # comma keeps its choice cache under $XDG_STATE_HOME, read-only in the
        # sandbox, where it would print an error on every call.
        COMMA_CACHING = "0";
      };
      unsetEnv = [ "TMUX" ];
      # --disallowedTools takes several values, so it comes first: the next flag
      # ends its list, where a prompt passed after the flags would join it.
      flags = [
        "--disallowedTools"
      ]
      ++ denyPlaywrightUnsafe
      ++ [
        "--settings"
        "${permeance.root}/.claude/settings.json"
        "--setting-sources"
        "user,project,local"
        "--agents"
        exploreAgents
      ];
    };
    passthru.tests.smoke = permeance.tests.mkSmoke {
      name = "claude";
      description = "Verify claude binary executes and takes its live config from CLAUDE_SOURCES_ROOT, not PERMEANCE_ROOT, settings.json, plugin hook and plugin MCP commands resolve, keep CLAUDE.local.md files out of context and keep the bypass-mode warning accepted, git-allowlist-hook blocks when it can't run, claude starts with the read-only Explore agent and its own build's guard, which blocks writes, memory changes are asked for and held until Claude's work is done, the status line renders, claude-format runs a repository's own lefthook formatters, only those, and the built-in ones elsewhere, comma looks packages up offline, the Playwright MCP starts in its scratch home with its testing and devtools tools, claude denies its unsafe tool and no plugin attaches it to an outside browser or widens its reach, and the Go and Lua language servers keep their caches where the sandbox can write";
      script = ''
        # claude-code does not expose a config-loading probe that works in a
        # sandbox without auth/network. This only verifies the wrapper's binary
        # executes — config-loading is exercised at runtime, not here.
        if ${self}/bin/claude --version > /dev/null 2>&1; then
          ok "binary executes"
        else
          fail "binary failed to execute"
        fi

        # The launcher's live root is CLAUDE_SOURCES_ROOT: claude runs from a
        # copy of the bundled config, refuses the same copy once the allowlist
        # it points the git shim at is gone, and isn't redirected by
        # PERMEANCE_ROOT, the root of the tree a shell around it runs from.
        cp -rL ${config} "$TMPDIR/live"
        chmod -R u+w "$TMPDIR/live"
        if CLAUDE_SOURCES_ROOT=$TMPDIR/live ${self}/bin/claude --version > /dev/null 2>&1; then
          ok "claude runs from the live tree CLAUDE_SOURCES_ROOT names"
        else
          fail "claude doesn't run from the live tree CLAUDE_SOURCES_ROOT names"
        fi
        rm "$TMPDIR/live/.claude/git-allowlist.toml"
        if CLAUDE_SOURCES_ROOT=$TMPDIR/live ${self}/bin/claude --version > /dev/null 2>&1; then
          fail "claude ignores CLAUDE_SOURCES_ROOT, or starts from a tree without its git allowlist"
        else
          ok "claude refuses a live tree without its git allowlist"
        fi
        if PERMEANCE_ROOT=$TMPDIR/live ${self}/bin/claude --version > /dev/null 2>&1; then
          ok "claude leaves PERMEANCE_ROOT, another tree's root, alone"
        else
          fail "claude follows PERMEANCE_ROOT, another tree's root"
        fi

        # settings.json names the status line, the hooks and the shell prefix by
        # bare command, and the plugins name their hooks' and MCP servers'
        # commands the same way, so each must resolve on claude's PATH; at
        # runtime a missing one fails (the status line just goes blank, without
        # the prefix every shell command fails, and a server never starts).
        claudePath=${
          pkgs.lib.concatMapStringsSep ":" (builtins.replaceStrings
            [ permeance.out ]
            [ "${self}" ]
          ) pathPrefix
        }
        settings=${self}/.claude/settings.json
        for cmd in $(
          {
            ${pkgs.jq}/bin/jq -r '[.statusLine.command] + [.hooks[][].hooks[] | .command // empty] + [.env.CLAUDE_CODE_SHELL_PREFIX // empty] | .[] | split(" ")[0]' "$settings"
            ${pkgs.jq}/bin/jq -r '.hooks[][].hooks[] | .command // empty | split(" ")[0]' ${self}/.claude/plugins/*/hooks/hooks.json
            ${pkgs.jq}/bin/jq -r '(.mcpServers // {})[] | .command // empty | split(" ")[0]' ${self}/.claude/plugins/*/.mcp.json
          } | sort -u
        ); do
          if PATH="$claudePath" command -v "$cmd" > /dev/null; then
            ok "on claude's PATH: $cmd"
          else
            fail "settings.json, plugin hook or plugin MCP command not on claude's PATH: $cmd"
          fi
        done

        # The Playwright MCP (packages/playwright-mcp.nix) starts from its
        # wrapper, in its own scratch home, and offers the testing and devtools
        # tools the wrapper turns on. Spoken to through a FIFO: a pipe would
        # close its stdin, and the server with it, before it answers.
        mcpDir=$(mktemp -d)
        mkfifo "$mcpDir/in"
        ${playwrightMcpPkg}/bin/playwright-mcp --headless < "$mcpDir/in" > "$mcpDir/out" 2> "$mcpDir/err" &
        mcpPid=$!
        exec 3> "$mcpDir/in"
        mcpSay() { (trap "" PIPE; printf '%s\n' "$@" >&3) || true; }
        mcpWait() {
          for _ in $(seq 60); do
            ${pkgs.jq}/bin/jq -e --argjson id "$1" 'select(.id == $id)' "$mcpDir/out" > /dev/null 2>&1 && return 0
            sleep 1
          done
          return 1
        }
        mcpSay '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}'
        if mcpWait 1; then
          mcpSay '{"jsonrpc":"2.0","method":"notifications/initialized"}' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
          mcpWait 2 || true
        fi
        exec 3>&-
        kill "$mcpPid" 2> /dev/null || true
        wait "$mcpPid" 2> /dev/null || true
        mcpTools=$(${pkgs.jq}/bin/jq -r 'select(.id == 2) | .result.tools[].name' "$mcpDir/out" 2> /dev/null || true)
        for tool in browser_navigate browser_verify_value browser_start_tracing; do
          if grep -qx -- "$tool" <<< "$mcpTools"; then
            ok "the Playwright MCP offers $tool"
          else
            fail "the Playwright MCP doesn't offer $tool: $(head -c 300 "$mcpDir/err")"
          fi
        done

        # claude starts with browser_run_code_unsafe denied (denyPlaywrightUnsafe).
        for rule in ${pkgs.lib.escapeShellArgs denyPlaywrightUnsafe}; do
          if grep -aqF -- "$rule" ${self}/bin/claude; then
            ok "claude denies $rule"
          else
            fail "claude doesn't deny $rule"
          fi
        done

        # A plugin starts the Playwright MCP under the name its deny rule spells
        # out, and passes none of the options that would attach it to an outside
        # browser (cdp-endpoint, endpoint, extension), swap its browser or profile
        # (executable-path, user-data-dir, storage-state, config), open it to the
        # network (host, port), run code in it at start (init-page), or widen
        # what it reaches (allow-unrestricted-file-access, no-sandbox). Its env
        # can't: the wrapper drops every PLAYWRIGHT_MCP_* it is handed.
        playwrightServers=0
        for mcp in ${self}/.claude/plugins/*/.mcp.json; do
          plugin=$(basename "$(dirname "$mcp")")
          for server in $(${pkgs.jq}/bin/jq -r '(.mcpServers // {}) | to_entries[] | select(.value.command == "playwright-mcp") | .key' "$mcp"); do
            playwrightServers=$((playwrightServers + 1))
            rule="mcp__plugin_''${plugin}_''${server}__browser_run_code_unsafe"
            if grep -aqF -- "$rule" ${self}/bin/claude; then
              ok "claude denies $plugin's browser_run_code_unsafe by name"
            else
              fail "claude doesn't deny $plugin's browser_run_code_unsafe by name: $rule"
            fi
            if ${pkgs.jq}/bin/jq -e --arg s "$server" --argjson deny '["--allow-unrestricted-file-access","--cdp-endpoint","--config","--endpoint","--executable-path","--extension","--host","--init-page","--no-sandbox","--port","--storage-state","--user-data-dir"]' '[.mcpServers[$s].args // [] | .[] as $a | $deny[] as $d | select($a == $d or ($a | startswith($d + "=")))] == []' "$mcp" > /dev/null; then
              ok "$plugin leaves the Playwright MCP's browser, profile and reach to its wrapper"
            else
              fail "$plugin attaches the Playwright MCP to an outside browser or widens what it can reach"
            fi
          done
        done
        if [ "$playwrightServers" -gt 0 ]; then
          ok "a plugin starts the Playwright MCP"
        else
          fail "no plugin starts the Playwright MCP (sources/.claude/plugins/playwright-mcp)"
        fi

        # A git command git-allowlist-hook can't vet (its binary missing, a
        # timeout) is blocked rather than let through; git-shim still checks the
        # same allowlist when git runs.
        if ${pkgs.jq}/bin/jq -e '[.hooks.PreToolUse[].hooks[] | select(.command == "git-allowlist-hook") | .onFailure] == ["block"]' "$settings" > /dev/null; then
          ok "git-allowlist-hook blocks a git command when it can't run"
        else
          fail "git-allowlist-hook lets git commands through when it can't run"
        fi

        # The Explore agent replaces the built-in, whose shell runs whatever the
        # permission mode lets through. claude gets it with --agents from the
        # build that holds its guard, which its hook on Bash runs by store path
        # and which blocks when it can't run. Claude Code checks an --agents
        # value before anything else and refuses to start on one it can't load,
        # so a print run without a prompt shows the value loads.
        agents=${pkgs.writeText "explore-agents.json" exploreAgents}
        guard=$(${pkgs.jq}/bin/jq -r '.Explore.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.onFailure == "block") | .command' "$agents")
        started=$(${self}/bin/claude -p < /dev/null 2>&1 || true)
        if ${pkgs.jq}/bin/jq -e '.Explore.tools == ["Read", "Bash", "LSP"]' "$agents" > /dev/null \
          && [ "$guard" = "${claudeExploreGuard}/bin/claude-explore-guard" ] && [ -x "$guard" ] \
          && grep -aqF -- "$(cat "$agents")" ${self}/bin/claude \
          && printf '%s' "$started" | grep -q 'Input must be provided'; then
          ok "claude starts with the Explore agent, which keeps to Read, LSP and a Bash its own build's guard vets"
        else
          fail "claude lacks the Explore agent, can't load it, or gives it more tools or an unguarded Bash: $started"
        fi
        vet() {
          ${pkgs.jq}/bin/jq -n --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}' | "$guard" 2> /dev/null
        }
        if vet 'git log --oneline -5' && vet "grep -rn 'a|b' src" \
          && ! vet 'git stash' && ! vet 'git log --output=x' \
          && ! vet 'cat a > b' && ! vet 'find . -delete'; then
          ok "claude-explore-guard lets reads through and blocks writes"
        else
          fail "claude-explore-guard lets a write through or blocks a read"
        fi

        # CLAUDE.local.md is git-ignored, so one a session plants, at the root
        # or in a subdirectory, would steer every later session without ever
        # showing in git status. settings.json keeps them all out of context.
        if ${pkgs.jq}/bin/jq -e '.claudeMdExcludes | index("**/CLAUDE.local.md")' "$settings" > /dev/null; then
          ok "settings.json keeps CLAUDE.local.md files out of context"
        else
          fail "settings.json lets CLAUDE.local.md files into context"
        fi

        # Claude records the accepted bypass-mode warning in the profile's
        # settings.json, which claude.bash re-provisions from this file at every
        # launch: the acceptance has to live here, or the warning comes back on
        # each start (the launcher passes --allow-dangerously-skip-permissions).
        if ${pkgs.jq}/bin/jq -e '.skipDangerousModePermissionPrompt == true' "$settings" > /dev/null; then
          ok "settings.json keeps the accepted bypass-mode warning"
        else
          fail "settings.json drops the accepted bypass-mode warning"
        fi

        # Memory changes: the ask rule asks before each write by Claude's file
        # tools, claude-shell-guard keeps shell commands from writing memory, and
        # the memory-gate plugin's hooks run claude-memory-gate, which holds the
        # prompts until Claude's work is done. Hooks stay on: this file outranks
        # a disableAllHooks a session could write into .claude/settings.local.json.
        if ${pkgs.jq}/bin/jq -e '(.permissions.ask | index("Edit(~/.claude*/projects/*/memory/**)")) and .env.CLAUDE_CODE_SHELL_PREFIX == "claude-shell-guard" and .disableAllHooks == false' "$settings" > /dev/null; then
          ok "settings.json asks before each memory change and keeps the shell out of memory"
        else
          fail "settings.json lets Claude change its memory without asking, or from the shell"
        fi
        memoryHooks=${self}/.claude/plugins/memory-gate/hooks/hooks.json
        if ${pkgs.jq}/bin/jq -e '[.hooks.PreToolUse, .hooks.Stop, .hooks.UserPromptSubmit] | all(any(.[].hooks[].command; . == "claude-memory-gate"))' "$memoryHooks" > /dev/null; then
          ok "the memory-gate plugin holds memory changes until Claude's work is done"
        else
          fail "the memory-gate plugin lets Claude change its memory mid-task"
        fi

        # Run the status line the way Claude Code does (sh -c, claude's PATH) on
        # a fixed payload. No rate_limits, so the line doesn't depend on the clock.
        payload='{"session_id":"3f2c8a9e-7b41-4d6a-9c05-1e8f6b2d4a73","model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"context_window":{"used_percentage":42,"current_usage":{"input_tokens":2000,"output_tokens":1500,"cache_creation_input_tokens":8000,"cache_read_input_tokens":120000}},"prompt_cache":{"ttl":"1h"},"cost":{"total_cost_usd":1.5}}'
        want='ctx ━━─── 42%  $1.50 +0.13  Opus 5.5  ↓2.0k ↑1.5k W8.0k R120k =132k'
        line=$(printf '%s' "$payload" \
          | COLUMNS=200 PATH="$claudePath" ${pkgs.runtimeShell} -c "$(${pkgs.jq}/bin/jq -r .statusLine.command "$settings")")
        if [ "$line" = "$want" ]; then
          ok "status line renders a sample payload"
        else
          fail "status line rendered: $line"
        fi

        # claude-format, the PostToolUse hook on Edit and Write, run the way
        # Claude Code runs it: the edit as JSON on stdin, in the session's
        # repository, with claude's PATH ahead of the caller's. A repository's
        # own formatters, the pre-commit jobs of its lefthook config that set
        # stage_fixed, run instead of the built-in ones, and only those.
        fmt=$(mktemp -d)
        fmtEdit() {
          ${pkgs.jq}/bin/jq -n --arg f "$2" '{tool_name: "Edit", tool_input: {file_path: $f}}' \
            | (cd "$1" && CLAUDE_PROJECT_DIR="$1" PATH="$claudePath:$PATH" \
              CLAUDE_GIT_ALLOWLIST_CONFIG=${self}/.claude/git-allowlist.toml claude-format) \
              2> "$fmt/stderr"
        }
        fmtRepo() {
          mkdir -p "$1" && ${pkgs.git}/bin/git -C "$1" init -q
        }
        # fmtIs <what> <file> <the content it must have>
        fmtIs() {
          if [ "$(cat "$2")" = "$3" ]; then
            ok "claude-format: $1"
          else
            fail "claude-format: $1: got $(cat "$2"), stderr $(cat "$fmt/stderr")"
          fi
        }
        fmtEditOk() {
          fmtEdit "$@" || fail "claude-format: editing $2 failed: $(cat "$fmt/stderr")"
        }
        go='package x\nfunc  f(){}\n'
        gofmted='package x\n\nfunc f() {}'

        # The config lefthookHooks render, with every formatter from claude's PATH.
        repo="$fmt/repo"
        fmtRepo "$repo"
        cp ${repoLefthookConfig} "$repo/lefthook.yml"
        printf 'package a\n\nfunc f() {\n\n\tprintln()\n}\n' > "$repo/a.go"
        printf 'a:   1\n' > "$repo/b.yml"
        printf 'if true; then\necho x\nfi\n' > "$repo/c.bash"
        mkdir -p "$repo/sub" && printf '{a=1;}\n' > "$repo/sub/d.nix"
        printf 'a  =  1\n' > "$repo/e.toml"
        printf '#  title\n' > "$repo/f.md"
        for f in a.go b.yml c.bash sub/d.nix e.toml f.md; do
          fmtEditOk "$repo" "$repo/$f"
        done
        fmtIs "formats Go with gofumpt, as the lefthookHooks config does" "$repo/a.go" "$(printf 'package a\n\nfunc f() {\n\tprintln()\n}')"
        fmtIs "formats YAML with yamlfmt" "$repo/b.yml" "a: 1"
        fmtIs "formats .bash with shfmt" "$repo/c.bash" "$(printf 'if true; then\n  echo x\nfi')"
        fmtIs "formats Nix in a subdirectory with nixfmt" "$repo/sub/d.nix" "{ a = 1; }"
        fmtIs "formats TOML with taplo" "$repo/e.toml" "a = 1"
        fmtIs "leaves a file no formatter takes alone" "$repo/f.md" "#  title"

        # Only the formatters: no other job runs, nothing is staged, a partially
        # staged file keeps its unstaged changes while they run, and a file type
        # the config doesn't format doesn't get the built-in formatter either.
        repo="$fmt/only"
        fmtRepo "$repo"
        cat > "$repo/lefthook.yml" << 'EOF'
        pre-commit:
          jobs:
            - name: guard
              run: touch ran-guard
            - group:
                piped: true
                jobs:
                  - name: upper
                    glob: "*.txt"
                    run: cat other.txt > seen && tr a-z A-Z < {staged_files} > .up && mv .up {staged_files}
                    stage_fixed: true
                  - name: lint
                    glob: "*.txt"
                    run: touch ran-lint
            - name: finalize
              run: touch ran-finalize
        EOF
        printf 'hello\n' > "$repo/note.txt"
        printf 'one\n' > "$repo/other.txt"
        ${pkgs.git}/bin/git -C "$repo" add other.txt
        printf 'two\n' >> "$repo/other.txt"
        printf '%b' "$go" > "$repo/x.go"
        fmtEditOk "$repo" "$repo/note.txt"
        fmtEditOk "$repo" "$repo/x.go"
        fmtIs "runs the repository's formatter" "$repo/note.txt" HELLO
        fmtIs "leaves a partially staged file's unstaged changes in place" "$repo/seen" "$(printf 'one\ntwo')"
        fmtIs "leaves a file type the repository doesn't format alone" "$repo/x.go" "$(printf '%b' "$go")"
        ran=
        for job in guard lint finalize; do
          if [ -e "$repo/ran-$job" ]; then
            ran="$ran $job"
          fi
        done
        if [ -n "$ran" ]; then
          fail "claude-format: ran a job that isn't a formatter:$ran"
        else
          ok "claude-format: runs no job but the formatters"
        fi
        staged=$(${pkgs.git}/bin/git -C "$repo" diff --cached --name-only)
        if [ "$staged" = other.txt ]; then
          ok "claude-format: stages nothing"
        else
          fail "claude-format: staged $staged"
        fi

        # Formatters listed under the older commands key run too.
        repo="$fmt/commands"
        fmtRepo "$repo"
        printf 'pre-commit:\n  commands:\n    upper:\n      glob: "*.txt"\n      run: tr a-z A-Z < {staged_files} > .up && mv .up {staged_files}\n      stage_fixed: true\n' > "$repo/lefthook.yml"
        printf 'hello\n' > "$repo/note.txt"
        fmtEditOk "$repo" "$repo/note.txt"
        fmtIs "runs a formatter listed under commands" "$repo/note.txt" HELLO

        # A formatter that fails says why.
        repo="$fmt/fails"
        fmtRepo "$repo"
        printf 'pre-commit:\n  jobs:\n    - name: boom\n      glob: "*.bad"\n      run: echo "boom on {staged_files}" >&2; exit 3\n      stage_fixed: true\n' > "$repo/lefthook.yml"
        : > "$repo/c.bad"
        if fmtEdit "$repo" "$repo/c.bad"; then
          fail "claude-format: a failing formatter went unreported"
        elif grep -q 'boom on c.bad' "$fmt/stderr"; then
          ok "claude-format: reports a failing formatter's output"
        else
          fail "claude-format: a failing formatter's output is lost: $(cat "$fmt/stderr")"
        fi

        # A formatter lefthook can't pick out, having no name, leaves the file as
        # it is.
        repo="$fmt/unnamed"
        fmtRepo "$repo"
        printf 'pre-commit:\n  jobs:\n    - glob: "*.go"\n      run: touch ran-fmt\n      stage_fixed: true\n' > "$repo/lefthook.yml"
        printf '%b' "$go" > "$repo/x.go"
        fmtEditOk "$repo" "$repo/x.go"
        fmtIs "leaves a file only an unnamed formatter takes alone" "$repo/x.go" "$(printf '%b' "$go")"

        # The built-in formatters: in a repository whose config has no formatter
        # (and its linter doesn't run), outside any repository, and in a
        # repository other than the session's, whose config could be one the
        # session wrote.
        repo="$fmt/lint"
        fmtRepo "$repo"
        printf 'pre-commit:\n  jobs:\n    - name: lint\n      glob: "*.go"\n      run: touch ran-lint\n' > "$repo/lefthook.yml"
        printf '%b' "$go" > "$repo/x.go"
        fmtEditOk "$repo" "$repo/x.go"
        fmtIs "formats Go with gofmt where the config has no formatter" "$repo/x.go" "$(printf '%b' "$gofmted")"
        if [ -e "$repo/ran-lint" ]; then
          fail "claude-format: ran a linter"
        else
          ok "claude-format: runs no linter"
        fi
        mkdir -p "$fmt/plain"
        printf '%b' "$go" > "$fmt/plain/x.go"
        fmtEditOk "$fmt/plain" "$fmt/plain/x.go"
        fmtIs "formats Go with gofmt outside a repository" "$fmt/plain/x.go" "$(printf '%b' "$gofmted")"
        printf 'hello\n' > "$fmt/commands/other.txt"
        printf '%b' "$go" > "$fmt/commands/y.go"
        fmtEditOk "$fmt/only" "$fmt/commands/other.txt"
        fmtEditOk "$fmt/only" "$fmt/commands/y.go"
        fmtIs "doesn't run the config of a repository other than the session's" "$fmt/commands/other.txt" hello
        fmtIs "formats Go with gofmt in a repository other than the session's" "$fmt/commands/y.go" "$(printf '%b' "$gofmted")"

        # The lookup nix-run.md relies on: comma on claude's PATH finds the
        # package that ships a command in its bundled index, with no network.
        if PATH="$claudePath" , -p rg | grep -qx -- '- ripgrep.out'; then
          ok "comma looks up rg's package offline"
        else
          fail "comma lookup failed: $(PATH="$claudePath" , -p rg 2>&1)"
        fi

        # Plugin language servers run inside the sandbox, where ~/.cache is
        # read-only: gopls quits when it cannot make its cache there, so go-lsp
        # keeps it under the claude profile, as the MCP plugins keep theirs.
        if ${pkgs.jq}/bin/jq -e '.go.env.GOPLSCACHE | startswith("''${CLAUDE_CONFIG_DIR")' ${self}/.claude/plugins/go-lsp/.lsp.json > /dev/null; then
          ok "go-lsp keeps gopls's cache under the claude profile"
        else
          fail "go-lsp leaves gopls's cache in ~/.cache, where gopls quits in the sandbox"
        fi

        # lua-language-server quits the same way over its log and meta files,
        # which its nixpkgs launcher keeps under XDG_CACHE_HOME (~/.cache when
        # unset), so lua-lsp points that at the claude profile too.
        if ${pkgs.jq}/bin/jq -e '.lua.env.XDG_CACHE_HOME | startswith("''${CLAUDE_CONFIG_DIR")' ${self}/.claude/plugins/lua-lsp/.lsp.json > /dev/null; then
          ok "lua-lsp keeps lua-language-server's cache under the claude profile"
        else
          fail "lua-lsp leaves lua-language-server's cache in ~/.cache, where it quits in the sandbox"
        fi
      '';
    };
    meta.mainProgram = "claude";
  };
in
self
