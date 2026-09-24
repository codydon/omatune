# Changelog

All notable changes are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-09-24

### Added
- Account-free YouTube Music search through the anonymous InnerTube
  `WEB_REMIX` client.
- Song radio: picking a song plays it and queues up to 40 related songs.
- Playback through mpv and yt-dlp that keeps going through shell restarts.
- Bar widget with the current title; click, middle-click, right-click and
  scroll controls.
- Panel with now playing, a seek bar, transport buttons, search, results and
  the queue, all usable from the keyboard.
- IPC commands: `toggle`, `playPause`, `next`, `previous`, `stop`,
  `search`, `playResult`.
- Settings: `showTitle`, `maxTitleChars`, `autoRadio`.
- Media keys and the Omarchy media widget through `mpv-mpris`.
