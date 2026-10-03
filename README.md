# cc-mods

Mods for [Claude Code](https://claude.com/claude-code): plugins of function hooks that run inside the CLI and hot-reload as you edit them.

## Loading a mod

Each mod is its own folder with a `.claude-plugin/plugin.json`. Load one for a session:

```sh
claude --plugin-dir ~/Documents/dev/Projects/cc-mods/where-were-we
```

Repeat `--plugin-dir` for several mods. To load them in every session, list them in the `env` block of `~/.claude/settings.json`, separated by `:`:

```json
"env": {
  "CLAUDE_CODE_PLUGIN_DIRS": "~/Documents/dev/Projects/cc-mods/where-were-we"
}
```

An interactive session watches these folders: saving a file reloads the mod. Your installed plugins load as usual alongside them. Don't load the same mod from two folders at once.

## Developing

Inside a mod folder:

```sh
claude plugin validate .   # what the engine sees and would refuse
claude plugin test .       # runs tests/*.test.ts(x)
npx tsc -p .               # type-check
```

The engine writes the API's type declarations into `.claude-plugin/types/` (git-ignored) each time it loads a mod, so type-checking works once the mod has loaded at least once.

## Mods

### where-were-we

Timestamps your prompts in the transcript and lets you jump back through them.

- **Prompt rows** show when you sent them: `12:21:00 ❯ my prompt` for today, `2026-10-02 18:04:11 ❯ …` for older prompts. Wrapped lines stay aligned under the prompt text.
- **Footer**: `↑ ↓ last 12:21:00` at the end of the hint line under the prompt. ↑ and ↓ step through your prompts; while navigating the label shows the position (`2/7 12:19:44`). Sending a prompt resets it.
- **`/where-were-we`** lists your 6 most recent prompts, newest at the bottom; click a line to jump to that prompt.
- **`/where-were-we count [n]`** shows or sets how many prompts the list shows (1–50).
- **`/where-were-we order [chron|reverse]`** shows or sets the list order: `chron` puts the newest last (the default), `reverse` puts it first.
- **`/where-were-we up | down | last`** steps like the arrows, from the keyboard (works mid-turn).
- **`/where-were-we status`** prints the mod's state and recent log lines for troubleshooting.

The count and order are kept in the mod's own store (a JSON file of its own under `~/.claude/`), not in `settings.json`, and last across sessions.

Prompts sent while the mod is loaded are stamped as they're stored. Prompts from before (a `--resume`, or the mod enabled mid-session) and prompts queued mid-turn are read from the session's transcript file.

Limitations:

- Jumping scrolls the transcript only in the fullscreen layout. On the main screen the history is the terminal's own scrollback, which a mod can't move.
- A row drawn as time-only today keeps that form past midnight until it redraws.
- The prompt list matches listing lines to prompts by second and text, since a command's output row carries no ids. A line that can't be matched draws dim and isn't clickable.
