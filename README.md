# claude

[Claude Code](https://github.com/anthropics/claude-code), wrapped with its configuration as a Nix flake: its settings, rules, commands and plugins (`sources/.claude`), and on its PATH the tools they call: hooks, a status line, a git allowlist, language servers and formatters.

Two of its inputs, `permeance` and `claude-sandbox`, are private repositories fetched over ssh, so building it needs access to them.

## Run it

```sh
nix run github:Runeword/claude
```

## Use it as an input

```nix
{
  inputs.claude.url = "github:Runeword/claude";
  inputs.claude.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { claude, ... }: {
    # The wrapper as it is …
    packages.x86_64-linux.claude = claude.packages.x86_64-linux.default;
    # … or built with your own git behind its git shim.
    packages.x86_64-linux.claude-with-my-git = claude.lib.mkClaude {
      system = "x86_64-linux";
      git = myGit;
    };
  };
}
```

`lib.mkClaude` also takes `configPath`, a config tree to bundle instead of `./sources`, and `lefthookHooks`, the lefthook hooks whose formatters `claude-format` should find on claude's PATH.

## Edit the config live

Claude reads the config bundled into the store. Point `CLAUDE_SOURCES_ROOT` at a checkout's `sources/` to use that tree instead, with no rebuild:

```sh
CLAUDE_SOURCES_ROOT=$HOME/claude/sources claude
```

A session started inside that checkout can then edit the config it runs with, its git allowlist included: CLAUDE.md says why, and how to avoid it.
