## Problem and resulting behavior

Describe the problem, the change, and why it helps. One topic per PR; target `dev`.

## Area

- Zone(s) touched (see AGENTS.md): <!-- e.g. tools / CI, game/scenes/golf -->
- [ ] Only files in my assigned zone changed, or cross-zone changes are listed and explained here.
- [ ] No change to `game/core`, autoload, `project.godot`, the menu or the protocol, or the maintainer agreed.

## Validation

Paste the commands you ran and their results. Say "not run" for anything you skipped.

- [ ] `python tools/check_conventions.py` passes (any `# allow:` exceptions explained below).
- [ ] Relevant hub / tools tests pass, or explain why they do not apply.
- [ ] `python tools/i18n_check.py`: 0 missing, 0 unused (when text changed).
- [ ] Affected game flow checked (start, pause, restart, results, menu).
- [ ] Relevant 2/4-player layouts and controller disconnect/reconnect checked.
- [ ] UI changes: 1600×900 screenshots in Chinese and English attached.

## Assets and privacy

- [ ] No local paths, credentials, certificates, device addresses, recordings or build artifacts.
- [ ] No new dependency, or it is justified here.
- [ ] New/modified third-party assets have a source, author, license and derivation record.
- [ ] AI original assets have an explicit contributor declaration and available generation records.
- [ ] Required copyright and attribution notices are retained.

## Limitations

List any checks not run (e.g. real-device feel, BLE, HDR) or known limitations.
