# shellcheck shell=bash
# shellcheck disable=SC2154 # bundled and default_plugins come from launcher/default.nix
#
# claude-plugins [--default | --mcp]: the plugins claude-launch can load, one
# name per line: every plugin of claude's config, the ones it loads when
# CLAUDE_PLUGINS is unset, or those that start an MCP server (a .mcp.json).
# The terminal's pickers list them from here rather than read the config tree.
shopt -s nullglob
case ${1:-} in
  "" | --mcp) ;;
  --default)
    read -r -a defaults <<<"$default_plugins"
    printf '%s\n' "${defaults[@]}"
    exit 0
    ;;
  *)
    echo "usage: claude-plugins [--default | --mcp]" >&2
    exit 2
    ;;
esac
tree=$(claude_tree)
for dir in "$tree"/.claude/plugins/*/; do
  if [ "${1:-}" != --mcp ] || [ -f "$dir.mcp.json" ]; then
    name=${dir%/}
    printf '%s\n' "${name##*/}"
  fi
done
