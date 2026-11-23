{ pkgs, rootPath }:

{
  # Build a derivation containing the listed entries as symlinks under their
  # target paths. Each entry is either:
  #   - a string "X" - shorthand for { source = "X"; target = "X"; }. The
  #     source tree under rootPath mirrors the target tree, so a single string
  #     names both (e.g. ".claude/settings.json" lives at
  #     sources/.claude/settings.json and lands at $out/.claude/settings.json).
  #   - an attrset { source, target } for entries where source and target
  #     differ - e.g. an absolute source (a file from a nixpkgs package) or a
  #     renamed target (claude's format hook installed as bin/claude-format).
  #
  # In both forms:
  #   source - path relative to rootPath, OR an absolute path string for
  #            external sources (e.g. "${pkgs.somePackage}/share/...")
  #   target - path under $out (e.g. ".claude/rules")
  #
  # rootPath MUST be a Nix path literal. Sub-paths interpolate as proper store
  # references so the bundled config propagates into downstream closures. The
  # bundled tree is the only thing baked into the derivation; live editing is
  # handled by the `permeance` flake input's launcher pattern at runtime, not
  # by swapping rootPath at evaluation time - so no --impure is required.
  mkConfig =
    name: entries:
    let
      resolvePath =
        source:
        if pkgs.lib.hasPrefix "/" source then
          source
        else if builtins.isPath rootPath then
          rootPath + "/${source}"
        else
          throw "mkConfig: rootPath must be a Nix path literal, got ${builtins.typeOf rootPath}";

      toLinkFarmEntry =
        rawEntry:
        if builtins.isString rawEntry then
          {
            name = rawEntry;
            path = resolvePath rawEntry;
          }
        else if
          rawEntry ? source
          && rawEntry ? target
          && builtins.isString rawEntry.source
          && builtins.isString rawEntry.target
        then
          {
            name = rawEntry.target;
            path = resolvePath rawEntry.source;
          }
        else
          throw "mkConfig: each entry must be a string or { source, target } attrset; got ${builtins.typeOf rawEntry}";
    in
    pkgs.linkFarm name (map toLinkFarmEntry entries);
}
