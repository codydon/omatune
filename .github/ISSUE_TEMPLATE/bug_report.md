---
name: Bug report
about: Something doesn't work the way it should
labels: bug
---

**What happened**
<!-- What you did, what you expected, what you got instead. -->

**Versions**
- Omarchy (`omarchy version`):
- mpv (`mpv --version | head -1`):
- yt-dlp (`yt-dlp --version`):
- OmaTune (`jq -r .version ~/.config/omarchy/plugins/codydon.omatune/manifest.json`):

**Did updating yt-dlp fix it?**
<!-- Playback breaking suddenly is almost always fixed by a newer yt-dlp. -->

**Logs**
<!-- Remove anything personal before pasting. -->
<details><summary>Shell log</summary>

```
log=$(ls -t $XDG_RUNTIME_DIR/quickshell/by-id/*/log.log | head -1); grep -i omatune "$log" | tail -40
```

</details>
<details><summary>mpv log (playback problems)</summary>

```
tail -40 $XDG_RUNTIME_DIR/codydon-omatune/mpv.log
```

</details>

<!-- Security problem? Don't file it here; see SECURITY.md. -->
