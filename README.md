# agents-plugins

Shawn Carrillo's plugins for [Claude Code](https://claude.com/claude-code), published as the `scarrillo` plugin marketplace.

## Install

Add the marketplace once, then install the plugins you want:

```
/plugin marketplace add scarrillo/agents-plugins
/plugin install where-were-we@scarrillo
/plugin install release@scarrillo
```

## Plugins

| Plugin | What it does | Source |
| --- | --- | --- |
| [where-were-we](where-were-we/) | Timestamps your prompts in the transcript, adds up/down prompt navigation to the footer, and recaps where your last session in a project left off. A mod built on Claude Code's function-hooks API. | this repo |
| [release](https://github.com/scarrillo/release) | Release automation: semantic versioning, changelogs, decisions tracking and TestFlight integration. | [scarrillo/release](https://github.com/scarrillo/release) |

## Developing a mod

Each mod is its own folder with a `.claude-plugin/plugin.json`. Load one from disk for a session:

```sh
claude --plugin-dir ~/path/to/agents-plugins/where-were-we
```

Repeat `--plugin-dir` for several mods. To load them in every session, list them in the `env` block of `~/.claude/settings.json`, separated by `:`:

```json
"env": {
  "CLAUDE_CODE_PLUGIN_DIRS": "~/path/to/agents-plugins/where-were-we"
}
```

An interactive session watches these folders: saving a file reloads the mod. Don't load the same mod from two places at once, for example from disk and installed from the marketplace.

Inside a mod folder:

```sh
claude plugin validate .   # what the engine sees and would refuse
claude plugin test .       # runs tests/*.test.ts(x)
npx tsc -p .               # type-check
```

The engine writes the API's type declarations into `.claude-plugin/types/` (git-ignored) each time it loads a mod, so type-checking works once the mod has loaded at least once.

## License

[MIT](LICENSE)
