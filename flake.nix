{
  description = "Claude Code Nix modules";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.ast-grep-skill = {
    url = "github:ast-grep/agent-skill";
    flake = false;
  };

  outputs =
    { nixpkgs, ast-grep-skill, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
    in
    {
      devShells = nixpkgs.lib.genAttrs systems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          ast-grep = import ./modules/ast-grep.nix { inherit pkgs ast-grep-skill; };
        }
      );
    };
}
