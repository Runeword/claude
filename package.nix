# The claude package: the bare wrapper (wrapper.nix), which is bin/claude, and
# the launcher that starts it the way the terminal does (launcher/), which is
# bin/claude-launch and what `nix run` runs, with their tests. flake.nix builds
# it through lib.mkClaude; it takes what wrapper.nix takes.
{
  pkgs,
  permeance,
  claudeSandbox,
  ...
}@args:
let
  inherit (pkgs) lib;
  wrapper = import ./wrapper.nix args;
  claudeProfile = import ./packages/profile { inherit pkgs; };
  # What a launch loads when CLAUDE_PLUGINS is unset. nix-mcp is opt-in: the
  # mcp-nixos server costs ~1.7s to import on every launch (its own server
  # init, not uvx overhead; no faster version exists), so loading it
  # unconditionally taxed every session. memory-gate holds Claude's memory
  # changes until its work is done (packages/memory-gate/main.go).
  defaultPlugins = [
    "nix-lsp"
    "typescript-lsp"
    "go-lsp"
    "shell-lsp"
    "lua-lsp"
    "memory-gate"
  ];
  mkLauncher =
    overrides:
    import ./launcher (
      {
        inherit
          pkgs
          claudeProfile
          claudeSandbox
          defaultPlugins
          ;
        claude = wrapper;
      }
      // overrides
    );
  launcher = mkLauncher { };
  self = pkgs.symlinkJoin {
    name = "claude";
    paths = [
      wrapper
      launcher
    ];
    passthru = {
      inherit wrapper launcher;
      tests = wrapper.passthru.tests // {
        launcher = import ./launcher/tests.nix {
          inherit
            pkgs
            permeance
            wrapper
            mkLauncher
            defaultPlugins
            ;
          main = lib.getExe self;
        };
      };
    };
    meta.mainProgram = "claude";
  };
in
self
