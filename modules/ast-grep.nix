{ pkgs, ast-grep-skill }:
pkgs.mkShell {
  buildInputs = [ pkgs.ast-grep ];
  shellHook = ''
    project_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
    mkdir -p "$project_root/.claude/skills"
    ln -sfn ${ast-grep-skill}/ast-grep/skills/ast-grep "$project_root/.claude/skills/ast-grep"
  '';
}
