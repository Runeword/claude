{
  description = "Claude Code, wrapped with its configuration";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  inputs.lefthook.url = "github:Runeword/lefthook";
  inputs.lefthook.inputs.nixpkgs.follows = "nixpkgs";

  # The two private inputs are fetched over ssh, so nix logs in through the
  # ssh agent, from a claude-sandbox session too. The ref is spelled out because
  # the session's git shim refuses the ls-remote nix would use to find the
  # default branch, and shallow=1 skips the history, which a github: input never
  # had. A flake that takes this one as an input (github:Runeword/terminal) has
  # them follow its own.
  inputs.permeance.url = "git+ssh://git@github.com/Runeword/permeance?ref=main&shallow=1";
  inputs.permeance.inputs.nixpkgs.follows = "nixpkgs";

  inputs.claude-sandbox.url = "git+ssh://git@github.com/Runeword/claude-sandbox?ref=main&shallow=1";
  inputs.claude-sandbox.inputs.nixpkgs.follows = "nixpkgs";

  inputs.nix-index-database.url = "github:nix-community/nix-index-database";
  inputs.nix-index-database.inputs.nixpkgs.follows = "nixpkgs";

  inputs.ast-grep-skill = {
    url = "github:ast-grep/agent-skill";
    flake = false;
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      lefthook,
      ast-grep-skill,
      ...
    }:
    let
      # The systems claude-sandbox builds for: nixpkgs-unstable (26.11) no
      # longer evaluates for x86_64-darwin.
      forAllSystems =
        f:
        nixpkgs.lib.genAttrs [
          "x86_64-linux"
          "aarch64-linux"
          "aarch64-darwin"
        ] (system: f system (mkPkgs system));

      # claude-code is unfree.
      mkPkgs =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfree = true;
          overlays = [ ];
        };

      mkClaudeWith =
        pkgs:
        {
          configPath ? ./sources,
          git ? pkgs.git,
          lefthookHooks ? import ./devshells/lefthook-hooks.nix,
        }:
        import ./wrapper.nix {
          inherit pkgs git lefthookHooks;
          files = import ./lib/files.nix {
            inherit pkgs;
            rootPath = configPath;
          };
          permeance = inputs.permeance.lib pkgs;
          inherit (inputs) nixpkgs nix-index-database lefthook;
          claudeSandbox = inputs.claude-sandbox.packages.${pkgs.stdenv.hostPlatform.system};
        };

      # This repository's lefthook hooks, as the dev shell installs them.
      mkLefthookShell =
        system:
        lefthook.lib.${system}.mkShell {
          hooks = import ./devshells/lefthook-hooks.nix;
        };
    in
    {
      # The wrapper, for a flake that takes this one as an input. It takes the
      # system, not a package set, and builds from this flake's nixpkgs (which
      # that flake can have follow its own), so the tools on claude's PATH are
      # the ones its smoke test ran.
      # - configPath: the config tree bundled into the store, a path literal.
      # - git: the git the git shim runs once the allowlist lets a command
      #   through, nixpkgs' when null.
      # - lefthookHooks: the lefthook hooks (a lefthook-hooks.nix) of the
      #   repository claude-format must serve outside its dev shell, whose
      #   format hooks' tools go on claude's PATH; this repository's when null.
      #   The smoke test formats Go, Nix, shell, TOML and YAML through them.
      lib.mkClaude =
        {
          system,
          configPath ? ./sources,
          git ? null,
          lefthookHooks ? null,
        }:
        let
          pkgs = mkPkgs system;
        in
        mkClaudeWith pkgs (
          {
            inherit configPath;
          }
          // pkgs.lib.optionalAttrs (git != null) { inherit git; }
          // pkgs.lib.optionalAttrs (lefthookHooks != null) { inherit lefthookHooks; }
        );

      packages = forAllSystems (
        _: pkgs: {
          default = mkClaudeWith pkgs { };
          # Also on claude's PATH, for its SessionStart hook; a package of its
          # own for the shell functions that list, back up and restore sessions
          # (the terminal's claude.bash), which run it outside claude.
          claude-sessions = import ./packages/sessions { inherit pkgs; };
          playwright-mcp = import ./packages/playwright-mcp.nix { inherit pkgs; };
        }
      );

      apps = forAllSystems (
        system: _: {
          default = {
            type = "app";
            program = "${self.packages.${system}.default}/bin/claude";
            meta.description = "Claude Code with its bundled config (set $CLAUDE_SOURCES_ROOT to a sources tree for live config)";
          };
        }
      );

      checks = forAllSystems (
        system: _: {
          claude = self.packages.${system}.default.passthru.tests.smoke;
          # The committed lefthook-generated.yml is what the dev shell renders.
          lefthook-config = (mkLefthookShell system).mkConfigCheck self;
        }
      );

      devShells = forAllSystems (
        system: pkgs: {
          # Entering it (direnv does) renders lefthook-generated.yml and installs
          # the git hooks. go for lint-go, which loads packages through the
          # project's own toolchain.
          default = pkgs.mkShell {
            packages = [ pkgs.go ];
            inputsFrom = [ (mkLefthookShell system) ];
          };
          ast-grep = import ./modules/ast-grep.nix { inherit pkgs ast-grep-skill; };
        }
      );
    };
}
