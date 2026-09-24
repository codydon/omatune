# Contributing to OmaTune

Thanks for helping. OmaTune is a small Omarchy bar plugin, so contributions
of any size are welcome: a bug report with a log, a fixed parser when YouTube
changes its JSON, a new panel feature, or better docs. Not a coder? You can
also support the project on [Ko-fi](https://ko-fi.com/codydon).

- [Ground rules](#ground-rules)
- [Reporting bugs](#reporting-bugs)
- [Suggesting features](#suggesting-features)
- [Development setup](#development-setup)
- [How the code fits together](#how-the-code-fits-together)
- [Coding rules](#coding-rules)
- [Testing your change](#testing-your-change)
- [Pull requests](#pull-requests)
- [Releases](#releases)

## Ground rules

- Be kind. This project follows the [Code of Conduct](CODE_OF_CONDUCT.md).
- **OmaTune stays account-free.** It talks to YouTube Music as an anonymous
  client. Changes that add sign-in, send cookies or read browser profiles
  won't be merged into the default behaviour. Open an issue first if you want
  to discuss an opt-in design.
- **yt-dlp does the hard part.** Stream resolution, signature decoding and
  bot-check (PoToken) handling belong to yt-dlp. Please don't reimplement
  them here; fix them upstream in yt-dlp instead.
- **Security is a merge requirement, not a nice-to-have.** The plugin runs
  inside the shell process that draws your whole desktop, and everything
  YouTube sends is untrusted. See [Coding rules](#coding-rules).

## Reporting bugs

Search the existing issues first. If yours is new, open a **Bug report** and
include:

1. What you did, what you expected and what happened.
2. Versions: `omarchy version`, `mpv --version | head -1`, `yt-dlp --version`.
3. The plugin log:
   ```bash
   log=$(ls -t $XDG_RUNTIME_DIR/quickshell/by-id/*/log.log | head -1)
   grep -i omatune "$log" | tail -40
   ```
4. For playback problems, the output of
   `mpv --no-video https://music.youtube.com/watch?v=<id>` for a song that fails.
5. For search or radio problems, the backend output:
   `./ytm-backend search "your query" | head -c 2000`.

Check logs for anything personal (usernames, paths, IP addresses) before
pasting them. **Found a security issue?** Don't open a public issue; see
[SECURITY.md](SECURITY.md).

**"Playback stopped working today"** is almost always a YouTube change that a
newer yt-dlp fixes. Update yt-dlp and try again before reporting.

## Suggesting features

Open a **Feature request** describing the problem you want solved, not only
the solution. Features that fit well:

- Things ArchiveTune does that OmaTune doesn't yet: offline downloads, local
  playlists, lyrics, album and artist pages.
- Keyboard-first panel improvements.

Features that probably won't fit: video playback, account sign-in by
default, anything that needs a daemon besides mpv.

## Development setup

You need an Omarchy install (Omarchy 4 or later, with the Quickshell bar)
plus the runtime packages:

```bash
omarchy pkg add mpv yt-dlp mpv-mpris jq deno nodejs shellcheck
```

Fork the repository and clone your fork somewhere outside the plugin folder:

```bash
git clone https://github.com/<you>/omatune ~/src/omatune
```

To run your working copy live, copy it into the plugin folder (Omarchy
doesn't allow symlinks in plugin folders), then restart the shell:

```bash
rsync -a --delete --exclude .git ~/src/omatune/ ~/.config/omarchy/plugins/codydon.omatune/
omarchy restart shell
```

Saving QML files under `~/.config/omarchy/plugins/` hot-reloads them, but
**changes to `manifest.json` or an `IpcHandler` need `omarchy restart shell`**.

## How the code fits together

```
Panel / BarWidget ──► Service.qml ──► ytm-backend ──► music.youtube.com/youtubei/v1
                          │                └────────► starts / stops mpv
                          └── mpv JSON IPC socket ──► mpv ──► yt-dlp
```

| File | What it does |
|---|---|
| `manifest.json` | Plugin id, kinds (`service` + `bar-widget`) and the settings schema |
| `Service.qml` | One instance per shell. Holds search state, owns the mpv socket, mirrors mpv's playlist, runs the backend |
| `BarWidget.qml` | The bar button (one per monitor), IPC target `codydon.omatune`, hosts the panel |
| `Panel.qml` | The popup: now playing, seek, transport, search, results and queue |
| `Model.js` | Pure logic with no Qt or I/O: parsing, cleaning, mpv commands, queue mapping. Unit-tested under node |
| `ytm-backend` | Bash: `search`, `radio <id>` (one JSON line each), and `player`, which execs mpv |
| `tests/` | Node tests for `Model.js` |
| `bin/check` | Every local check in one command |

Two design points that surprise people:

- **mpv's playlist is the queue.** The service doesn't keep its own list; it
  mirrors mpv's `playlist` property. `Service.meta` only maps a video id to
  its title and artist.
- **The backend is the only thing that touches the network.** mpv is a
  child `Process` the service owns (`ytm-backend player` execs it), and the
  QML talks to it over its socket. Never detach it: it must stop with the
  plugin.

## Coding rules

These come from the Omarchy marketplace's security review. Each one has
blocked real plugins, so pull requests are checked against them.

**QML**

- Every `Text` needs `textFormat: Text.PlainText`. In `Panel.qml`, use the
  local `PlainText` component.
- Strings passed to shell components you can't pin to plain text
  (`WidgetButton.text`, `tooltipText`, `PanelSectionHeader.text`) go through
  `Model.plain()` first.
- Don't set `Image.source` from remote URLs, such as thumbnails. That needs a
  bounded download helper, which doesn't exist yet.
- Every backend call is a **new** `Process` (the `backendRun` component)
  run under `timeout -k` (which kills the whole process group), with a
  watchdog, a cleared environment (`childEnvironment`) and a byte-counted
  `SplitParser`. Never use `StdioCollector`. Late replies are dropped with a
  token (`searchToken`, `radioToken`).
- IPC methods that take a value must bound it exactly like the UI does, and
  may only trigger normal, non-destructive actions.
- Every connection attempt to mpv is a **new** `Socket` (`connectSocket()`).
  A Quickshell `Socket` that failed once doesn't reconnect.
- Use `Style.*` and `Color.*` tokens and the first-party `qs.Ui` components;
  don't hard-code colours or sizes.
- Every panel action needs a keyboard shortcut.

**Bash (`ytm-backend`)**

- Keep `set -euo pipefail`, `umask 077` and `LC_ALL=C`.
- Call tools by the `readonly` absolute paths at the top of the file.
- Put `--` before data arguments. Build JSON with `jq --arg`, never by
  pasting strings together.
- Every network read keeps `--max-time`, `--max-filesize` and the
  `head -c MAX+1` length check.
- Check video ids against `^[A-Za-z0-9_-]{11}$` before using them anywhere.
- Never put untrusted values in bash arithmetic (`$(( ))`, `[ -gt ]`).
- Output is always one JSON line: `{"ok":true,…}` or
  `{"ok":false,"error":"…"}`.

**Data from YouTube**

- Clean it twice: in jq (strip control and bidi characters, cap lengths, cap
  list sizes) and again in `Model.parseReply` / `Model.plain`.
- New pure logic goes in `Model.js` with a test, not inline in QML.

**Words**

- Messages the user sees are sentences with a next step: "Couldn't reach
  YouTube Music. Check your connection, then search again." Don't write
  "Error: curl exit 6".

## Testing your change

Run everything:

```bash
bin/check
```

That runs the node tests, `bash -n` and `shellcheck` on the backend, the
manifest validator, the plain-text audit and the agent-file guard. CI runs
the parts that work without Omarchy.

Then check it by hand in the real shell:

```bash
omarchy restart shell
omarchy-shell shell toggle codydon.omatune       # open the panel on the focused monitor
omarchy-shell codydon.omatune search "daft punk"
omarchy-shell codydon.omatune playResult 0
```

To test without sound, mute your output first:
`wpctl set-mute @DEFAULT_AUDIO_SINK@ 1` (and `0` to unmute).

For UI changes, attach a screenshot **cropped to the panel**. A wider grab
also captures whatever window is behind it.

## Pull requests

1. Branch from `main`: `git switch -c fix/radio-dedupe`.
2. Keep each PR focused on one change. Refactors go in their own PR.
3. Run `bin/check`, and add or update tests in `tests/`.
4. Update `README.md` if you changed behaviour, keys, settings or IPC, and
   add a line under **Unreleased** in `CHANGELOG.md`.
5. Write commit messages in the imperative ("Add lyrics panel", not "Added
   lyrics").
6. Open the PR and fill in the template. Say how you tested it and on which
   Omarchy version.

**Don't commit agent-instruction files** (`AGENTS.md`, `CLAUDE.md`,
`.claude/`, `.cursor/` and similar). The Omarchy marketplace rejects plugins
that contain them, and `.gitignore` already excludes the usual ones. Using AI
tools to write code is fine; the committed code has to meet the same rules
either way.

## Releases

Maintainers only:

1. Move the **Unreleased** notes in `CHANGELOG.md` under the new version,
   and bump `version` in `manifest.json`.
2. Push, and wait for CI to pass.
3. Tag the exact commit with an annotated tag:
   `git tag -a vX.Y.Z -m "vX.Y.Z" <full-sha> && git push origin vX.Y.Z`.
4. `gh release create vX.Y.Z --notes-file <notes>`.
5. Submit that SHA to the Omarchy marketplace, and don't push to `main`
   until the review is done; any new commit makes the review stale.

Published tags are never moved. A fix after tagging is a new version.

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE).
