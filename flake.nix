{
  description = "Claude Code Nix modules";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.lefthook = {
    url = "github:Runeword/lefthook";
    inputs.nixpkgs.follows = "nixpkgs";
  };
  inputs.ast-grep-skill = {
    url = "github:ast-grep/agent-skill";
    flake = false;
  };

  outputs =
    {
      nixpkgs,
      lefthook,
      ast-grep-skill,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
    in
    {
      devShells = nixpkgs.lib.genAttrs systems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = lefthook.lib.mkShell pkgs [
            lefthook.devShells.${system}.auto-msg
            lefthook.devShells.${system}.format-nix
            lefthook.devShells.${system}.format-yaml
          ];
          ast-grep = import ./modules/ast-grep.nix { inherit pkgs ast-grep-skill; };
        }
      );
    };
}
