## What this changes

<!-- One or two sentences. Link the issue: "Fixes #12". -->

## How I tested it

<!-- Omarchy version, and what you did in the real shell. For UI changes,
     attach a screenshot cropped to the panel. -->

## Checklist

- [ ] `bin/check` passes
- [ ] New logic in `Model.js` has tests in `tests/`
- [ ] Every new `Text` has `textFormat: Text.PlainText`
- [ ] New backend calls use absolute tool paths, `--`, and byte and time limits
- [ ] README and `CHANGELOG.md` (Unreleased) are updated if behaviour changed
- [ ] No agent-instruction files (`AGENTS.md`, `CLAUDE.md`, `.claude/`, …) added
