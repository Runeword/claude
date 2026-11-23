{ pkgs }:

pkgs.buildGoModule {
  pname = "claude-profile";
  version = "0.1.0";
  src = ./.;
  # Stdlib only — no dependency vendoring required.
  vendorHash = null;
}
