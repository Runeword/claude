# shellcheck shell=bash
# shellcheck disable=SC2154 # claude, bundled and the rest come from launcher/default.nix
#
# claude-launch: claude as the terminal starts it, for `nix run` and for the
# terminal's chords alike. Every argument is claude's. How it starts comes from
# the environment, which is also how the terminal's tmux new-window carries it:
#   CLAUDE_CONFIG_DIR       the profile: ~/.claude-1 unless set. claude-profile
#                           prepares only one of its own (see its marker), never
#                           a ~/.claude it didn't make.
#   CLAUDE_PLUGINS          the plugins to load, space- or comma-separated;
#                           unset, the default ones (claude-plugins --default).
#   CLAUDE_LAUNCH_VM=1      in the microVM: claude-vm (github:Runeword/claude-
#                           microvm, from PATH) instead of claude-sandbox.
#   CLAUDE_SANDBOX=0        no sandbox, the explicit escape hatch.
#   CLAUDE_SANDBOX_ALLOW_GH, _JIRA, _FIREBASE and CLAUDE_SANDBOX_NET_ALLOW
#                           a credential for this session, and its network
#                           filter's extra hosts, which the launchers read.
#   CLAUDE_SOURCES_ROOT     a live copy of the config tree (see wrapper.nix).
#
# All of it happens in this one process, so nothing it checked can change
# before claude starts:
#   1. the sandbox's gate, which refuses a cwd it can't bind safely;
#   2. the profile (claude-profile prepare) and the project (claude-profile
#      project);
#   3. the plugins' secrets, from pass into the environment, never argv;
#   4. the open-session lock claude-sessions reads (Linux);
#   5. exec: claude under claude-sandbox (Linux), under claude-macos (macOS, a
#      session holding a credential), in the microVM, or as it is.
# A refusal goes to stderr, with a non-zero status; in a tmux pane, the
# terminal keeps the failed pane open until a key is pressed.
#
# --allow-dangerously-skip-permissions only where claude-sandbox or the microVM
# confines the whole process: Claude Code's docs keep bypass mode for an
# isolated environment, which Seatbelt alone (macOS) and CLAUDE_SANDBOX=0 are
# not. --effort max comes last before claude's own arguments, so a later
# --effort wins, and it takes exactly one value, so a prompt after it stays one.

tree=$(claude_tree)
if [ ! -d "$tree/.claude" ]; then
  echo "claude: $tree/.claude is missing, so there is no claude config to launch with" >&2
  exit 1
fi
export CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude-1}"

list=${CLAUDE_PLUGINS-$default_plugins}
read -r -a plugins <<<"${list//,/ }"
plugin_args=()
for p in "${plugins[@]}"; do
  case $p in
    .* | *[!A-Za-z0-9._-]*)
      echo "claude: '$p' in CLAUDE_PLUGINS is not a plugin name; refusing to launch" >&2
      exit 1
      ;;
  esac
  if [ ! -d "$tree/.claude/plugins/$p" ]; then
    echo "claude: claude's config has no plugin $p; refusing to launch without it" >&2
    exit 1
  fi
  plugin_args+=(--plugin-dir "$tree/.claude/plugins/$p")
done
loads() {
  local p
  for p in "${plugins[@]}"; do
    [ "$p" = "$1" ] && return 0
  done
  return 1
}

# Who confines claude. claude-sandbox and its helpers are this build's, by
# store path; claude-vm is found on PATH, and refused when it isn't there.
run=("$claude")
confined=0
if [ "${CLAUDE_LAUNCH_VM:-0}" = 1 ]; then
  # figma-mcp's key would sit in the VM, and google-workspace-mcp's token store
  # isn't shared with it.
  if loads figma-mcp || loads google-workspace-mcp; then
    echo "claude: the microVM does not carry figma-mcp or google-workspace-mcp yet; start them outside it. Refusing to launch." >&2
    exit 1
  fi
  if ! vm=$(command -v claude-vm); then
    echo "claude: claude-vm not found on PATH; refusing to launch." >&2
    exit 1
  fi
  "$vm" --check-cwd || exit 1
  # The VM runs the claude it finds itself.
  run=("$vm" claude)
  confined=1
elif [ "${CLAUDE_SANDBOX:-1}" = 0 ]; then
  :
elif [ "$host_os" = Linux ]; then
  "$sandbox" --check-cwd || exit 1
  run=("$sandbox" "$claude")
  confined=1
elif [ "${CLAUDE_SANDBOX_ALLOW_FIREBASE:-0}" = 1 ] || [ "${CLAUDE_SANDBOX_ALLOW_JIRA:-0}" = 1 ]; then
  # macOS: Claude Code's own Seatbelt sandbox (settings.darwin.json), and
  # claude-macos to hand a session the credential it opted into.
  run=("$macos" "$claude")
fi

overlay=()
case $host_os in
  Linux) overlay=(--os linux) ;;
  Darwin) overlay=(--os darwin) ;;
esac
"$profile_helper" prepare --config "$tree/.claude" --profile "$CLAUDE_CONFIG_DIR" "${overlay[@]}" || exit 1
"$profile_helper" project --dir "$PWD" || exit 1

# A plugin that needs a secret gets it from the pass entry its interactive
# counterpart reads, and only when it loads, so an ordinary launch fires no gpg
# prompt. Its .mcp.json takes it from the environment (${VAR:-}), which the
# sandbox and the microVM hand on.
if loads figma-mcp; then
  FIGMA_API_KEY=$("$pass" show "${FIGMA_TOKEN_PASS:-FIGMA_TOKEN}" 2>/dev/null) || FIGMA_API_KEY=
  export FIGMA_API_KEY
fi
if loads google-workspace-mcp; then
  GOOGLE_OAUTH_CLIENT_ID=$("$pass" show "${GOOGLE_OAUTH_CLIENT_ID_PASS:-GOOGLE_OAUTH_CLIENT_ID}" 2>/dev/null) || GOOGLE_OAUTH_CLIENT_ID=
  GOOGLE_OAUTH_CLIENT_SECRET=$("$pass" show "${GOOGLE_OAUTH_CLIENT_SECRET_PASS:-GOOGLE_OAUTH_CLIENT_SECRET}" 2>/dev/null) || GOOGLE_OAUTH_CLIENT_SECRET=
  # Its OAuth token store, ~/.google_workspace_mcp, stays masked in a session
  # that doesn't set this.
  export GOOGLE_OAUTH_CLIENT_ID GOOGLE_OAUTH_CLIENT_SECRET CLAUDE_SANDBOX_ALLOW_GOOGLE_WORKSPACE=1
fi

# Which session claude has open, for claude-sessions' backup and restore
# (packages/sessions/open.go): flock holds a lock on a file of this launch's
# own in the profile's open-sessions/ for as long as claude runs, and names it
# in CLAUDE_SESSIONS_OPEN, where claude's SessionStart hook (claude-sessions
# mark) writes the id of each session claude starts, resumes or clears into. A
# held lock that names a session says for sure it is open. -F execs flock into
# what comes next, so tmux names the window after claude, not flock; the lock
# passes on to claude and what it starts. Linux only (on macOS the backup reads
# Claude Code's own registry), and not in the microVM, whose sessions the
# restore doesn't start.
lock=()
if [ -n "$flock" ] && [ "${CLAUDE_LAUNCH_VM:-0}" != 1 ]; then
  if file=$(mktemp "$CLAUDE_CONFIG_DIR/open-sessions/XXXXXXXX"); then
    export CLAUDE_SESSIONS_OPEN="$file"
    lock=("$flock" -F "$file")
  fi
fi

flags=()
if [ "$confined" = 1 ]; then
  flags+=(--allow-dangerously-skip-permissions)
fi
exec "${lock[@]}" "${run[@]}" "${plugin_args[@]}" "${flags[@]}" --effort max "$@"
