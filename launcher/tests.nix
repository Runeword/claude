# The launcher's test (the claude-launcher check): test.sh, a template whose
# @…@ placeholders are the launchers it runs, each built with the stand-ins
# below, and exactly the store paths it uses.
{
  pkgs,
  permeance,
  wrapper,
  mkLauncher,
  defaultPlugins,
  # The package's main program, as lib.getExe finds it.
  main,
}:
let
  inherit (pkgs) lib;
  flock = lib.getExe' pkgs.util-linux "flock";
  # Whether the open-session lock is held, as a process claude starts sees it.
  lockState = ''
    if [ -n "''${CLAUDE_SESSIONS_OPEN:-}" ]; then
      if ${flock} -n "$CLAUDE_SESSIONS_OPEN" true; then echo free; else echo held; fi >"$OUT/lock"
    fi
  '';
  # Stand-in claude: saves the argv it was handed, one per line, its
  # environment and the lock's state to $OUT.
  fakeClaude = pkgs.writeShellScriptBin "claude" ''
    mkdir -p "$OUT"
    printf '%s\n' "$@" >"$OUT/argv"
    env >"$OUT/env"
    ${lockState}
  '';
  # Stand-in bwrap for the sandbox's dry run: prints the argv claude-sandbox
  # handed it, one per line, and saves its environment and the lock's state.
  fakeBwrap = pkgs.writeShellScriptBin "bwrap" ''
    printf '%s\n' "$@"
    env >"$OUT/env"
    ${lockState}
  '';
  # Stand-in pass: only the entries a launch reads decrypt.
  fakePass = pkgs.writeShellScriptBin "pass" ''
    case "$*" in
      "show FIGMA_TOKEN") echo fake-figma-key ;;
      "show claude/jira-token") echo fake-jira-token ;;
      *) exit 1 ;;
    esac
  '';
  linux = pkgs.stdenv.hostPlatform.isLinux;
  # The launcher for this system, running the stand-in claude.
  direct = mkLauncher {
    claude = fakeClaude;
    bundled = wrapper;
    pass = fakePass;
  };
in
permeance.tests.mkSmoke {
  name = "claude-launcher";
  description = "claude-launch prepares only a profile of its own, from the bundled or the live config tree, refuses an overlay that doesn't merge, loads the default or the picked plugins and refuses an unknown one, drops what a session planted in the profile and the project, hands a plugin's secret over in the environment, runs claude in flock's place under the open-session lock, confines it in claude-sandbox on Linux with the bypass flag and the profile's settings pinned, runs it under Seatbelt alone on macOS without the flag and through claude-macos for a credential, starts the microVM's own claude and refuses what it can't carry, and claude-plugins lists the plugins";
  script = ". ${
    pkgs.replaceVars ./test.sh {
      inherit wrapper main direct;
      inherit (pkgs) jq;
      os = if linux then "linux" else "darwin";
      defaults = lib.concatStringsSep " " defaultPlugins;
      # Linux only: a Linux launcher can't be built where claude-sandbox isn't,
      # and on a Mac the host's own launcher is the Darwin one.
      sandboxed =
        if linux then
          mkLauncher {
            bubblewrap = fakeBwrap;
            pass = fakePass;
          }
        else
          direct;
      darwin =
        if linux then
          mkLauncher {
            claude = fakeClaude;
            bundled = wrapper;
            pass = fakePass;
            hostOS = "Darwin";
          }
        else
          direct;
    }
  }";
}
