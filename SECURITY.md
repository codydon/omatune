# Security policy

OmaTune runs inside `omarchy-shell`, the process that draws your whole
desktop, and handles data from YouTube that it can't trust. Security reports
are very welcome.

## Reporting a vulnerability

**Please don't open a public issue.** Use GitHub's private reporting
instead: open the repository's **Security** tab and choose **Report a
vulnerability**.

Include what an attacker controls (a song title, a crafted InnerTube reply,
a file in `$XDG_RUNTIME_DIR`, …), what they can make happen, and the steps or
payload to reproduce it. You should hear back within a week.

## In scope

- Text from YouTube or mpv being rendered as rich text, or loading remote or
  local resources
- Command or option injection through `ytm-backend`, mpv or yt-dlp
- Unbounded memory, CPU or process use in the shell caused by remote data
- Problems with the runtime directory, socket or pid file (symlinks, races,
  killing a process that isn't ours)
- Anything that sends credentials, cookies or personal data anywhere

## Out of scope

- Vulnerabilities in yt-dlp, mpv, Quickshell or Omarchy itself. Report those
  upstream (we're happy to help).
- YouTube blocking playback or changing its API. That's a normal bug.

## Supported versions

Only the latest release gets security fixes.
