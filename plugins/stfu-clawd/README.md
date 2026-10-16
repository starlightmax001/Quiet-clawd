# STFU!Clawd

Keeps windows opened by Claude Code **quietly minimized by default**. If you're working fullscreen, watching a video or playing a game, a browser, preview window or loading screen no longer yanks you back to the desktop.

## How it works

1. When a session starts (`SessionStart` hook), a very lightweight window watcher is launched in the background.
2. The watcher takes a baseline of the windows that already exist and only handles windows that appear **afterwards**:
   - New windows belonging to Claude Code's process tree are minimized.
   - Browser windows (chrome / msedge / firefox / brave ...) that appear while Claude Code is running a tool (`PreToolUse` / `PostToolUse` record a timestamp; default grace period 8 seconds) are minimized. This covers things like `start chrome url`, which reuses an already-running browser process.
3. **Pop-ups of a minimized app are minimized too.** Loading pages, splash screens (even untitled ones), dialogs and pop-up windows that appear later are minimized as well, as long as the app was started by Claude Code or was already minimized by this plugin. If you have restored the app and are using it (it has a normal, non-minimized window), its pop-ups are left alone so your own work isn't interrupted. A splash screen that refuses to minimize is pushed to the very bottom of the window stack without taking focus.
4. On Windows it uses `SW_SHOWMINNOACTIVE` (minimize without activating) and then hands focus back to the window you were using (fullscreen app / game).
5. When the session ends (`SessionEnd`) the watcher is cleaned up automatically.

## Close protection while Claude is working (Windows only)

While Claude is working, the close button, the system-menu "Close" item and Alt+F4 of the PowerShell window running Claude Code are **disabled (grayed out)**. They come back as soon as Claude is idle.

- Locks: when you submit a prompt (`UserPromptSubmit`); refreshed on every tool call.
- Unlocks: when Claude finishes answering (`Stop`), when it needs your approval or is waiting for input (`Notification`), when you press **Esc / Ctrl+C** to interrupt, when the session ends, or after 15 minutes with no activity (`lockIdleSeconds`, so it can never lock you out for good).
- Emergency unlock: from **another** terminal run `node <plugin dir>/scripts/hook.js ctl unlock`. `/stfu-clawd:stfu pause` also releases every lock immediately.
- The watcher always re-enables the close button before it exits, including at session end.
- Works best with classic PowerShell / conhost windows. **Windows Terminal is best-effort**: the plugin tries to lock the whole terminal window, but it cannot block the "x" on a single tab, which closes just that tab. Tabs in the same Windows Terminal window share one window, so any one of them working locks the window.
- Set `"lockCloseWhileWorking": false` in the config to turn this feature off.

## Install

Easiest: use the package's `install.cmd` (see the README at the top of the zip).

For local testing without installing:

```bash
claude --plugin-dir ./stfu-clawd
```

Requires Node.js (already present wherever Claude Code runs).

## Usage

- Works automatically after installation, no setup needed.
- `/stfu-clawd:stfu pause` pauses, `resume` resumes, `status` shows the current state.

## Optional config: `~/.claude/stfu-clawd.json`

```json
{
  "graceSeconds": 8,
  "minimizeDescendants": true,
  "minimizePopups": true,
  "restoreFocus": true,
  "lockCloseWhileWorking": true,
  "lockIdleSeconds": 900,
  "escUnlocks": true,
  "watchProcessNames": ["chrome", "msedge", "firefox", "brave"]
}
```

## Platform support and limitations (please read)

| Platform | Support |
| --- | --- |
| Windows 10/11 | Full support (PowerShell 5.1+, built in) |
| Linux (X11) | Needs `wmctrl`, `xdotool` recommended as well; Wayland is not supported; no close-lock |
| macOS | Only windows opened by Claude Code's child processes; first run needs Accessibility permission for your terminal (System Settings > Privacy & Security > Accessibility); no close-lock |

- This is a **best-effort** "minimize as soon as it appears" approach: the watcher polls every 200-400 ms, so a window may flash briefly between creation and minimization.
- Some **exclusive-fullscreen** games can get pushed out the instant another window is created. The plugin cannot intercept a window before it exists; it can only minimize it as fast as possible and give focus back. **Borderless windowed** mode works best.
- The plugin never touches windows that existed before it started, and never minimizes windows you open yourself (browser windows are only handled during the grace period while a Claude Code tool is running).
