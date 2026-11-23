# shellcheck shell=bash
# A template: Nix fills in each @…@ from launcher/tests.nix before the check
# runs this file.
#
# claude-launch: the profile it prepares, the plugins it loads, what it drops,
# the secret it hands on, the lock it holds, and what confines claude. The
# direct and darwin launchers run a stand-in claude that saves what it was
# handed to $OUT; the sandboxed one runs claude-sandbox for real, through a
# stand-in bwrap that prints the argv it was handed.

project=$TMPDIR/project
mkdir -p "$project"
cd "$project" || exit 1
# This system's overlay: linux or darwin.
os=@os@
# claude-profile writes the settings it merges with their keys sorted, so the
# JSON compared below is compared with its keys sorted (jq -S): only on macOS
# does the overlay's sandbox block have more than one key, in an order of its own.
bundled_sandbox=$(@jq@/bin/jq -S -c .sandbox "@wrapper@/.claude/settings.$os.json")
read -r -a defaults <<<"@defaults@"

# has DIR LINE...: each LINE is a line of DIR/argv.
has() {
  local dir=$1 line
  shift
  for line; do
    grep -qxF -- "$line" "$dir/argv" || return 1
  done
}

# A plain launch, with no profile named: ~/.claude-1, made and marked, with
# this OS's overlay and the commands linked. With CLAUDE_SANDBOX=0 there is no
# sandbox, so no bypass flag, but on Linux the open-session lock still holds.
OUT=$TMPDIR/plain
if CLAUDE_SANDBOX=0 OUT=$OUT @direct@/bin/claude-launch --resume abc 2>"$TMPDIR/plain.err" &&
  [ -f "$HOME/.claude-1/.claude-launch" ] &&
  [ "$(@jq@/bin/jq -S -c .sandbox "$HOME/.claude-1/settings.json")" = "$bundled_sandbox" ] &&
  [ -f "$HOME/.claude-1/commands/x.md" ] && [ -f "$HOME/.claude-1/commands/r.md" ]; then
  ok "a launch with no profile named prepares ~/.claude-1, marked, with the $os overlay and the /x and /r commands"
else
  fail "a launch with no profile named does not prepare ~/.claude-1: $(cat "$TMPDIR/plain.err")"
fi
dirs=()
for p in "${defaults[@]}"; do
  dirs+=("@wrapper@/.claude/plugins/$p")
done
if has "$OUT" "${dirs[@]}" && [ "$(grep -c -x -- --plugin-dir "$OUT/argv")" = "${#defaults[@]}" ] &&
  [ "$(tail -n 4 "$OUT/argv" | tr '\n' ' ')" = "--effort max --resume abc " ] &&
  ! has "$OUT" --allow-dangerously-skip-permissions; then
  ok "it loads the ${#defaults[@]} default plugins, puts --effort max just before claude's own arguments, and with CLAUDE_SANDBOX=0 passes no bypass flag"
else
  fail "a plain launch hands claude: $(tr '\n' ' ' <"$OUT/argv")"
fi
if [ "$os" = darwin ]; then
  if [ ! -e "$OUT/lock" ] && grep -qx "CLAUDE_CONFIG_DIR=$HOME/.claude-1" "$OUT/env"; then
    ok "on macOS claude runs without an open-session lock: claude-sessions reads Claude Code's own registry there"
  else
    fail "on macOS claude runs under an open-session lock"
  fi
elif [ "$(cat "$OUT/lock" 2>/dev/null)" = held ] &&
  grep -q "^CLAUDE_SESSIONS_OPEN=$HOME/.claude-1/open-sessions/." "$OUT/env" &&
  grep -qx "CLAUDE_CONFIG_DIR=$HOME/.claude-1" "$OUT/env"; then
  ok "claude runs in flock's place, under a lock on a file of its own in the profile's open-sessions/, which it names to claude"
else
  fail "claude does not run under the open-session lock it is named"
fi

# CLAUDE_SOURCES_ROOT names a live tree, which the profile and the plugins
# come from; CLAUDE_SOURCES_ROOT_IGNORE sets it aside.
live=$TMPDIR/live
mkdir -p "$live/.claude/rules" "$live/.claude/plugins/only"
echo '{"live":true}' >"$live/.claude/settings.json"
echo '{"sandbox":{"enabled":"live"}}' >"$live/.claude/settings.$os.json"
OUT=$TMPDIR/live-out
if CLAUDE_SANDBOX=0 OUT=$OUT CLAUDE_CONFIG_DIR=$HOME/.claude-2 CLAUDE_SOURCES_ROOT=$live CLAUDE_PLUGINS=only \
  @direct@/bin/claude-launch 2>"$TMPDIR/live.err" &&
  [ "$(@jq@/bin/jq -S -c . "$HOME/.claude-2/settings.json")" = '{"live":true,"sandbox":{"enabled":"live"}}' ] &&
  [ "$(readlink "$HOME/.claude-2/rules")" = "$live/.claude/rules" ] &&
  has "$OUT" "$live/.claude/plugins/only"; then
  ok "CLAUDE_SOURCES_ROOT prepares the profile from the live tree it names, and loads its plugins"
else
  fail "CLAUDE_SOURCES_ROOT does not prepare the profile from the live tree: $(cat "$TMPDIR/live.err")"
fi
if CLAUDE_SANDBOX=0 OUT=$TMPDIR/ignore CLAUDE_CONFIG_DIR=$HOME/.claude-3 CLAUDE_SOURCES_ROOT=$live CLAUDE_SOURCES_ROOT_IGNORE=1 \
  @direct@/bin/claude-launch 2>/dev/null &&
  [ "$(@jq@/bin/jq -S -c .sandbox "$HOME/.claude-3/settings.json")" = "$bundled_sandbox" ]; then
  ok "CLAUDE_SOURCES_ROOT_IGNORE prepares the profile from the bundled tree"
else
  fail "CLAUDE_SOURCES_ROOT_IGNORE does not set the live tree aside"
fi

# What refuses the launch, before claude starts: an overlay that doesn't
# merge, a profile with files and no marker (~/.claude here, left as it was),
# and a plugin the config doesn't have or a name that isn't one.
bad=$TMPDIR/bad
mkdir -p "$bad/.claude"
echo '{}' >"$bad/.claude/settings.json"
echo 'not json' >"$bad/.claude/settings.$os.json"
mkdir -p "$HOME/.claude"
echo mine >"$HOME/.claude/CLAUDE.md"
refuses() {
  local what=$1 want=$2 said
  shift 2
  if said=$(env CLAUDE_SANDBOX=0 OUT="$TMPDIR/refused" "$@" @direct@/bin/claude-launch 2>&1); then
    fail "$what: launched"
  elif [ -e "$TMPDIR/refused" ]; then
    fail "$what: claude ran"
  else
    case $said in
      *"$want"*) ok "$what refuses the launch" ;;
      *) fail "$what: refused for another reason: $said" ;;
    esac
  fi
}
refuses "an overlay that does not merge" "could not merge" CLAUDE_CONFIG_DIR="$HOME/.claude-4" CLAUDE_SOURCES_ROOT="$bad" CLAUDE_PLUGINS=
refuses "a profile with files and no marker" "no .claude-launch marker" CLAUDE_CONFIG_DIR="$HOME/.claude"
refuses "a plugin the config doesn't have" "has no plugin nope" CLAUDE_PLUGINS=nope
refuses "a plugin name that leaves the plugins" "is not a plugin name" CLAUDE_PLUGINS=../memory-gate
if [ "$(cat "$HOME/.claude/CLAUDE.md")" = mine ] && [ ! -e "$HOME/.claude/settings.json" ]; then
  ok "a profile it refused is left as it was"
else
  fail "it changed ~/.claude, which it refused"
fi

# CLAUDE_PLUGINS picks exactly the plugins to load, comma- or space-separated.
OUT=$TMPDIR/picked
if CLAUDE_SANDBOX=0 OUT=$OUT CLAUDE_PLUGINS=nix-mcp,memory-gate @direct@/bin/claude-launch 2>/dev/null &&
  [ "$(grep -c -x -- --plugin-dir "$OUT/argv")" = 2 ] &&
  has "$OUT" "@wrapper@/.claude/plugins/nix-mcp" "@wrapper@/.claude/plugins/memory-gate"; then
  ok "CLAUDE_PLUGINS loads exactly the plugins it names"
else
  fail "CLAUDE_PLUGINS does not load exactly what it names: $(tr '\n' ' ' <"$OUT/argv")"
fi

# A launch drops what a session can leave for the next one: the MCP servers in
# the profile's .claude.json, and what claude doesn't write itself in the
# project's settings.local.json (hooks here), keeping its permission rules.
echo '{"mcpServers":{"a":{}},"projects":{"/p":{"mcpServers":{"b":{}}}}}' >"$HOME/.claude-1/.claude.json"
mkdir -p "$project/.claude"
echo '{"hooks":{},"permissions":{"allow":["Bash(ls)"],"defaultMode":"bypassPermissions"}}' >"$project/.claude/settings.local.json"
said=$(CLAUDE_SANDBOX=0 OUT=$TMPDIR/scrubbed @direct@/bin/claude-launch 2>&1 >/dev/null)
if [ "$(@jq@/bin/jq -c '[.mcpServers, .projects."/p".mcpServers]' "$HOME/.claude-1/.claude.json")" = '[{},{}]' ] &&
  [ "$(@jq@/bin/jq -S -c . "$project/.claude/settings.local.json")" = '{"permissions":{"allow":["Bash(ls)"]}}' ] &&
  case $said in *"removed the MCP servers a, b"*) true ;; *) false ;; esac &&
  case $said in *"dropped hooks, permissions.defaultMode"*) true ;; *) false ;; esac then
  ok "a launch drops the MCP servers and local settings a session planted, saying so, and keeps claude's permission rules"
else
  fail "a launch keeps what a session planted for the next one: $said"
fi

# figma-mcp's key reaches claude in its environment, never its argv.
OUT=$TMPDIR/figma
if CLAUDE_SANDBOX=0 OUT=$OUT CLAUDE_PLUGINS=figma-mcp @direct@/bin/claude-launch 2>/dev/null &&
  grep -qx FIGMA_API_KEY=fake-figma-key "$OUT/env" && ! grep -q fake-figma-key "$OUT/argv"; then
  ok "figma-mcp's key from pass reaches claude in its environment, not its argv"
else
  fail "figma-mcp's key is not handed over in the environment alone"
fi

if [ "$os" = linux ]; then
  # Linux: claude runs in claude-sandbox, the bypass flag on since the sandbox
  # confines the whole process, the profile's settings.json pinned read-only,
  # the lock held, and the key in bwrap's environment only.
  OUT=$TMPDIR/sandboxed
  mkdir -p "$OUT"
  if CLAUDE_CONFIG_DIR=$HOME/.claude-5 CLAUDE_PLUGINS=figma-mcp,memory-gate OUT=$OUT \
    @sandboxed@/bin/claude-launch --resume abc >"$OUT/argv" 2>"$OUT/err"; then
    awk '$0 == "--bind" || $0 == "--ro-bind" { op = $0; getline s; getline d; print op, s, d }' "$OUT/argv" >"$OUT/mounts"
    if has "$OUT" @wrapper@/bin/claude --allow-dangerously-skip-permissions "@wrapper@/.claude/plugins/memory-gate" &&
      [ "$(tail -n 4 "$OUT/argv" | tr '\n' ' ')" = "--effort max --resume abc " ] &&
      grep -qxF -- "--ro-bind $HOME/.claude-5/settings.json $HOME/.claude-5/settings.json" "$OUT/mounts" &&
      [ "$(cat "$OUT/lock" 2>/dev/null)" = held ] &&
      grep -qx FIGMA_API_KEY=fake-figma-key "$OUT/env" && ! grep -q fake-figma-key "$OUT/argv"; then
      ok "on Linux claude runs in claude-sandbox, with the bypass flag, its profile's settings pinned, the lock held and the key in the environment alone"
    else
      fail "claude-sandbox was not handed claude as it should be: $(tr '\n' ' ' <"$OUT/argv" | tail -c 600)"
    fi
  else
    fail "the launch did not reach bwrap: $(cat "$OUT/err")"
  fi
fi

# macOS: Seatbelt alone (the darwin overlay, failing closed), so no bypass
# flag and no open-session lock; a session holding a credential goes through
# claude-macos, which hands claude the token in its environment.
OUT=$TMPDIR/darwin
if OUT=$OUT CLAUDE_CONFIG_DIR=$HOME/.claude-6 @darwin@/bin/claude-launch 2>"$TMPDIR/darwin.err" &&
  ! has "$OUT" --allow-dangerously-skip-permissions && [ ! -e "$OUT/lock" ] &&
  [ "$(@jq@/bin/jq -c '[.sandbox.enabled, .sandbox.failIfUnavailable, .sandbox.allowUnsandboxedCommands]' "$HOME/.claude-6/settings.json")" = '[true,true,false]' ]; then
  ok "on macOS claude runs under Seatbelt alone, which fails closed, with no bypass flag and no open-session lock"
else
  fail "on macOS claude does not run under Seatbelt alone: $(cat "$TMPDIR/darwin.err")"
fi
mkdir -p "$HOME/.config/.jira" "$TMPDIR/macos"
: >"$HOME/.config/.jira/claude.yml"
OUT=$TMPDIR/darwin-jira
# Output goes to files: claude-macos leaves a watcher behind, which must not
# hold the build log open.
OUT=$OUT CLAUDE_CONFIG_DIR=$HOME/.claude-6 CLAUDE_SANDBOX_ALLOW_JIRA=1 TMPDIR=$TMPDIR/macos \
  @darwin@/bin/claude-launch >"$TMPDIR/darwin-jira.out" 2>"$TMPDIR/darwin-jira.err" || true
if grep -qx JIRA_API_TOKEN=fake-jira-token "$OUT/env" 2>/dev/null && ! grep -q fake-jira-token "$OUT/argv" &&
  ! has "$OUT" --allow-dangerously-skip-permissions; then
  ok "on macOS a jira session goes through claude-macos, which hands claude the token in its environment"
else
  fail "on macOS a jira session does not get its token through claude-macos: $(cat "$TMPDIR/darwin-jira.err")"
fi

# The microVM runs its own claude, after its --check-cwd gate, with the bypass
# flag and no open-session lock; it refuses figma-mcp, whose key it would
# hold, and without claude-vm on PATH nothing starts. A stand-in claude-vm
# passes the gate.
mkdir -p "$HOME/vm/bin"
cat >"$HOME/vm/bin/claude-vm" <<'EOF'
#!/bin/sh
[ "$1" = --check-cwd ] && exit 0
mkdir -p "$OUT"
printf '%s\n' "$@" >"$OUT/argv"
env >"$OUT/env"
EOF
chmod +x "$HOME/vm/bin/claude-vm"
OUT=$TMPDIR/vm
if PATH=$HOME/vm/bin:$PATH OUT=$OUT CLAUDE_CONFIG_DIR=$HOME/.claude-vm-1 CLAUDE_LAUNCH_VM=1 \
  @direct@/bin/claude-launch 2>"$TMPDIR/vm.err" &&
  [ "$(head -n 1 "$OUT/argv")" = claude ] && has "$OUT" --allow-dangerously-skip-permissions &&
  ! grep -q '^CLAUDE_SESSIONS_OPEN=' "$OUT/env"; then
  ok "the microVM runs its own claude, with the bypass flag and no open-session lock"
else
  fail "the microVM does not run its own claude as it should: $(cat "$TMPDIR/vm.err")"
fi
PATH=$HOME/vm/bin:$PATH refuses "figma-mcp in the microVM" "does not carry figma-mcp" CLAUDE_LAUNCH_VM=1 CLAUDE_PLUGINS=figma-mcp
refuses "the microVM without claude-vm" "claude-vm not found on PATH" CLAUDE_LAUNCH_VM=1

# claude-plugins lists every plugin, the default ones, and those that start an
# MCP server, for the terminal's pickers.
all=" $(@direct@/bin/claude-plugins | tr '\n' ' ')"
mcp=" $(@direct@/bin/claude-plugins --mcp | tr '\n' ' ')"
# lists LIST NAME: NAME is a word of LIST.
lists() {
  case $1 in
    *" $2 "*) true ;;
    *) false ;;
  esac
}
if [ "$(@direct@/bin/claude-plugins --default | tr '\n' ' ')" = "@defaults@ " ] &&
  lists "$all" nix-mcp && lists "$all" nix-lsp && lists "$all" playwright-mcp &&
  lists "$mcp" figma-mcp && lists "$mcp" playwright-mcp && ! lists "$mcp" nix-lsp; then
  ok "claude-plugins lists the plugins, the default ones and those that start an MCP server"
else
  fail "claude-plugins lists '$all', '$mcp'"
fi

# lib.getExe finds the bare claude, which runs.
main=@main@
if [ "${main##*/}" = claude ] && "$main" --version >/dev/null 2>&1; then
  ok "the package's main program is claude"
else
  fail "the package's main program is $main"
fi
