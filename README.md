# STFU!Clawd

## Install (one step)

1. Unzip this package (anywhere is fine).
2. **Double-click `install.cmd`**. When you see `[OK] Installed` you're done.
3. Restart Claude Code.

> Prerequisite: Claude Code is installed and typing `claude` in PowerShell works.

## Prefer not to double-click? Install manually in PowerShell

```powershell
claude plugin marketplace add .\STFU-Clawd      # use the real path where you unzipped it
claude plugin install stfu-clawd@stfu-clawd-market
```

## Update / uninstall

- Update: double-click `install.cmd` from the newer zip (it overwrites the old version).
- Uninstall: double-click `uninstall.cmd`.

## Usage

- Works automatically once installed, no setup needed.
- `/stfu-clawd:stfu pause | resume | status` pauses / resumes / shows the state.
- Emergency release of the "close protection while working" lock: from another terminal run
  `node "%USERPROFILE%\.claude\stfu-clawd-market\plugins\stfu-clawd\scripts\hook.js" ctl unlock`

Feature details, config options and limitations are in `plugins/stfu-clawd/README.md`.
