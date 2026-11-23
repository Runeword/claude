# The lefthook hooks this repository enables. The dev shell installs them as
# its git hooks (flake.nix); claude's PATH carries the format hooks' tools, for
# claude-format, which runs a repository's formatters after each edit
# (wrapper.nix).
{
  format-go.enable = true;
  lint-go.enable = true;
  format-nix.enable = true;
  lint-nix.enable = true;
  format-shell.enable = true;
  lint-shell.enable = true;
  format-toml.enable = true;
  format-yaml.enable = true;
  security-gitleaks.enable = true;
  auto-commit.enable = true;
}
