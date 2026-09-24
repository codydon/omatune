# Changelog

All notable changes are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.1] - 2026-09-24

Hardening for the Omarchy plugin marketplace.

### Changed
- mpv is now a child process owned by the plugin instead of a detached
  player, so it stops when the plugin is disabled or removed, or when the
  shell exits. Music no longer continues across a full shell restart.
- mpv runs with `--no-config`, so a personal `mpv.conf` can't change how the
  plugin plays or loads scripts; `mpv-mpris` is loaded explicitly.
- Helper processes run under `timeout -k`, which kills the whole process
  group at the deadline, with a minimal environment and a byte-counted
  output reader.
- The `search` and `playResult` IPC methods bound their input the same way
  the panel does.

### Removed
- The mpv log and pid files. OmaTune now writes only its control socket.
- The `start` and `stop` backend commands (replaced by `player`).

## [0.1.0] - 2026-09-24

### Added
- Account-free YouTube Music search through the anonymous InnerTube
  `WEB_REMIX` client.
- Song radio: picking a song plays it and queues up to 40 related songs.
- Playback through mpv and yt-dlp.
- Bar widget with the current title; click, middle-click, right-click and
  scroll controls.
- Panel with now playing, a seek bar, transport buttons, search, results and
  the queue, all usable from the keyboard.
- IPC commands: `toggle`, `playPause`, `next`, `previous`, `stop`,
  `search`, `playResult`.
- Settings: `showTitle`, `maxTitleChars`, `autoRadio`.
- Media keys and the Omarchy media widget through `mpv-mpris`.
