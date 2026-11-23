# claude-launch, claude as the terminal starts it (claude-launch.bash), and
# claude-plugins, the plugins it can load. Each command they run is a store
# path, set in the prelude below; what claude-sandbox and claude-macos look up
# by name (bwrap, pass, the sandbox's helpers) is on a PATH of store paths.
{
  pkgs,
  # The bare wrapper (wrapper.nix): the claude that runs, and the config tree
  # it bundles.
  claude,
  bundled ? claude,
  # packages/profile.
  claudeProfile,
  # github:Runeword/claude-sandbox's packages for this system.
  claudeSandbox,
  # The plugins a launch loads when CLAUDE_PLUGINS is unset.
  defaultPlugins,
  # The tests hand in stand-ins for these.
  bubblewrap ? pkgs.bubblewrap,
  pass ? pkgs.pass,
  hostOS ? if pkgs.stdenv.hostPlatform.isDarwin then "Darwin" else "Linux",
}:
let
  inherit (pkgs) lib;
  linux = hostOS == "Linux";
  # What both scripts read: the config tree and the default plugins.
  tree = ''
    bundled=${bundled}
    default_plugins=${lib.escapeShellArg (lib.concatStringsSep " " defaultPlugins)}
    # The config tree: the live one CLAUDE_SOURCES_ROOT names, which the bare
    # claude's own launcher reads too, or else the bundled one, in the store.
    # A CLAUDE_SOURCES_ROOT_IGNORE of anything but 0 or empty sets the live one
    # aside, for both.
    claude_tree() {
      if [ -n "''${CLAUDE_SOURCES_ROOT:-}" ] && [ "''${CLAUDE_SOURCES_ROOT_IGNORE:-0}" = 0 ]; then
        printf '%s' "$CLAUDE_SOURCES_ROOT"
      else
        printf '%s' "$bundled"
      fi
    }
  '';
  # What claude-launch runs.
  launch = ''
    claude=${lib.getExe' claude "claude"}
    profile_helper=${lib.getExe' claudeProfile "claude-profile"}
    sandbox=${lib.optionalString linux (lib.getExe' claudeSandbox.claude-sandbox "claude-sandbox")}
    macos=${lib.getExe' claudeSandbox.claude-macos "claude-macos"}
    flock=${lib.optionalString linux (lib.getExe' pkgs.util-linux "flock")}
    pass=${lib.getExe' pass "pass"}
    host_os=${hostOS}
  '';
  script =
    name: prelude: runtimeInputs:
    pkgs.writeShellApplication {
      inherit name runtimeInputs;
      text = prelude + builtins.readFile (./. + "/${name}.bash");
    };
in
pkgs.symlinkJoin {
  name = "claude-launch";
  paths = [
    (script "claude-launch" (tree + launch) (
      [
        pkgs.coreutils
        pass
      ]
      # claude-sandbox finds bwrap, pass and its helpers by name.
      ++ lib.optionals linux [
        claudeSandbox.default
        bubblewrap
      ]
    ))
    (script "claude-plugins" tree [ ])
  ];
  meta.mainProgram = "claude-launch";
}
