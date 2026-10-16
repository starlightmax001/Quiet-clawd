# STFU!Clawd — Windows watcher.
#  1) Minimizes (without activating) new windows opened by Claude Code and gives focus back
#     to whatever you were using (fullscreen app / game).
#  2) While Claude is working, disables the close button / Alt+F4 of the PowerShell window
#     hosting Claude Code, so it can't be closed by accident. Restored when Claude is idle.
param(
  [int]$HookPid,
  [string]$StateDir,
  [string]$PausePath,
  [string]$ConfigPath
)
$ErrorActionPreference = 'SilentlyContinue'

Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class WinInfo {
  public IntPtr H; public uint Pid; public bool Owned; public bool Tool; public bool Titled; public bool Iconic;
}
public static class StfuWin {
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
  [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] static extern IntPtr GetSystemMenu(IntPtr h, bool revert);
  [DllImport("user32.dll")] static extern int EnableMenuItem(IntPtr m, uint id, uint flags);
  [DllImport("user32.dll")] static extern bool DrawMenuBar(IntPtr h);
  [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vk);
  [DllImport("kernel32.dll")] static extern bool AttachConsole(uint pid);
  [DllImport("kernel32.dll")] static extern bool FreeConsole();
  [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
  [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int val, int size);
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);

  public static bool Exists(IntPtr h) { return IsWindow(h); }
  public static uint PidOf(IntPtr h) { uint p; GetWindowThreadProcessId(h, out p); return p; }

  // Window of the classic console that process `pid` is attached to (0 under ConPTY / Windows Terminal).
  public static IntPtr ConsoleWindowOf(uint pid) {
    FreeConsole();
    IntPtr h = IntPtr.Zero;
    if (AttachConsole(pid)) { h = GetConsoleWindow(); FreeConsole(); }
    return h;
  }

  // Grays out / restores SC_CLOSE (close button, system-menu Close and Alt+F4).
  public static void SetCloseEnabled(IntPtr h, bool on, bool redraw) {
    IntPtr m = GetSystemMenu(h, false);
    if (m == IntPtr.Zero) return;
    EnableMenuItem(m, 0xF060, on ? 0u : 3u);   // MF_BYCOMMAND | (MF_GRAYED|MF_DISABLED)
    if (redraw) DrawMenuBar(h);
  }

  // Every visible top-level window, INCLUDING owned pop-ups, tool windows and untitled
  // splash / loading screens (skips cloaked UWP ghost windows).
  public static List<WinInfo> Snapshot() {
    var l = new List<WinInfo>();
    EnumWindows(delegate(IntPtr h, IntPtr x) {
      if (!IsWindowVisible(h)) return true;
      int cloaked;
      if (DwmGetWindowAttribute(h, 14, out cloaked, 4) == 0 && cloaked != 0) return true;
      var w = new WinInfo();
      w.H = h;
      w.Pid = PidOf(h);
      w.Owned = GetWindow(h, 4) != IntPtr.Zero;
      w.Tool = (GetWindowLong(h, -20) & 0x80) != 0;      // WS_EX_TOOLWINDOW
      w.Titled = GetWindowTextLength(h) > 0;
      w.Iconic = IsIconic(h);
      l.Add(w);
      return true;
    }, IntPtr.Zero);
    return l;
  }

  // Fallback for windows that refuse to minimize (splash screens): push to the very bottom, no activation.
  public static void SendToBottom(IntPtr h) { SetWindowPos(h, new IntPtr(1), 0, 0, 0, 0, 0x13); }
}
"@

$cfg = @{ graceSeconds = 8; minimizeDescendants = $true; minimizePopups = $true; restoreFocus = $true
          lockCloseWhileWorking = $true; lockIdleSeconds = 900; escUnlocks = $true
          watchProcessNames = @('chrome','msedge','firefox','brave','opera','vivaldi') }
try {
  if (Test-Path $ConfigPath) {
    $u = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    foreach ($p in $u.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
  }
} catch {}

function Get-ProcTable {
  $t = @{}
  Get-CimInstance Win32_Process | ForEach-Object { $t[[int]$_.ProcessId] = $_ }
  return $t
}

# Find the Claude Code process (nearest claude/node/bun ancestor of the hook).
$procs = Get-ProcTable
$root = 0
$cur = $HookPid
for ($i = 0; $i -lt 8 -and $cur -and $procs.ContainsKey($cur); $i++) {
  if ($procs[$cur].Name -match '^(claude|node|bun)(\.exe)?$') { $root = $cur; break }
  $cur = [int]$procs[$cur].ParentProcessId
}
if (-not $root -and $procs.ContainsKey($HookPid)) { $root = [int]$procs[$HookPid].ParentProcessId }

function Get-Descendants([hashtable]$table, [int]$rootPid) {
  $set = New-Object 'System.Collections.Generic.HashSet[int]'
  if (-not $rootPid) { return $set }
  $kids = @{}
  foreach ($p in $table.Values) {
    $pp = [int]$p.ParentProcessId
    if (-not $kids.ContainsKey($pp)) { $kids[$pp] = New-Object System.Collections.ArrayList }
    [void]$kids[$pp].Add([int]$p.ProcessId)
  }
  $stack = New-Object System.Collections.Stack
  $stack.Push($rootPid)
  while ($stack.Count -gt 0) {
    $n = $stack.Pop()
    if ($kids.ContainsKey($n)) { foreach ($c in $kids[$n]) { if ($set.Add($c)) { $stack.Push($c) } } }
  }
  return $set
}

function Test-Fresh([string]$name, [int]$seconds) {
  try {
    $t = [int64](Get-Content (Join-Path $StateDir $name) -Raw)
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    return (($now - $t) -lt ($seconds * 1000))
  } catch { return $false }
}

# The window that hosts Claude Code's terminal: classic console window, else the nearest
# ancestor process that owns a main window (e.g. Windows Terminal).
function Resolve-LockTarget {
  if (-not $root) { return [IntPtr]::Zero }
  $h = [StfuWin]::ConsoleWindowOf([uint32]$root)
  if ($h -ne [IntPtr]::Zero -and [StfuWin]::IsWindowVisible($h)) { return $h }
  $c = $root
  for ($i = 0; $i -lt 10 -and $c -and $procs.ContainsKey($c); $i++) {
    $p = Get-Process -Id $c -ErrorAction SilentlyContinue
    if ($p -and $p.MainWindowHandle -ne [IntPtr]::Zero) { return $p.MainWindowHandle }
    $c = [int]$procs[$c].ParentProcessId
  }
  return [IntPtr]::Zero
}

# Esc or Ctrl+C = the user is interrupting Claude (no Stop hook fires for that).
function Test-InterruptKey {
  $esc = [StfuWin]::GetAsyncKeyState(0x1B)
  if (($esc -band 0x8001) -ne 0) { return $true }
  $ctl = [StfuWin]::GetAsyncKeyState(0x11)
  $c = [StfuWin]::GetAsyncKeyState(0x43)
  return ((($ctl -band 0x8000) -ne 0) -and (($c -band 0x8001) -ne 0))
}

# Processes that must never be touched: this watcher and Claude Code's own ancestors (the terminal).
$protect = New-Object 'System.Collections.Generic.HashSet[int]'
[void]$protect.Add($PID)
$c = $root
for ($i = 0; $i -lt 12 -and $c -and $procs.ContainsKey($c); $i++) { [void]$protect.Add($c); $c = [int]$procs[$c].ParentProcessId }

$seen = New-Object 'System.Collections.Generic.HashSet[int64]'
foreach ($w in [StfuWin]::Snapshot()) { [void]$seen.Add($w.H.ToInt64()) }   # baseline: leave existing windows alone
$managed = New-Object 'System.Collections.Generic.HashSet[int]'   # apps we have minimized: their later pop-ups get minimized too
$pending = @{}                                                    # hwnd -> tick, to verify the minimize worked
$desc = Get-Descendants $procs $root
$prevFg = [StfuWin]::GetForegroundWindow()
$lockTarget = [IntPtr]::Zero
$locked = $false
$tick = 0

try {
  while ($true) {
    if (Test-Path (Join-Path $StateDir 'stop')) { break }
    if ($root -and -not (Get-Process -Id $root -ErrorAction SilentlyContinue)) { break }
    Start-Sleep -Milliseconds 200
    $tick++

    $fg = [StfuWin]::GetForegroundWindow()
    if ($tick % 5 -eq 0) {
      $procs = Get-ProcTable; $desc = Get-Descendants $procs $root
      foreach ($mp in @($managed)) { if (-not $procs.ContainsKey($mp)) { [void]$managed.Remove($mp) } }
    }
    $paused = Test-Path $PausePath
    $busy = Test-Fresh 'busy' ([int]$cfg.graceSeconds)
    $minimizedAny = $false
    $current = [StfuWin]::Snapshot()

    # ---------- close-lock while Claude is working ----------
    if ($cfg.lockCloseWhileWorking) {
      if ($lockTarget -eq [IntPtr]::Zero -and ($tick % 25 -eq 1)) {
        $lockTarget = Resolve-LockTarget
        if ($lockTarget -ne [IntPtr]::Zero) { Set-Content -Path (Join-Path $StateDir 'hwnd') -Value $lockTarget.ToInt64() }
      }
      if ($lockTarget -ne [IntPtr]::Zero) {
        if (-not [StfuWin]::Exists($lockTarget)) { $lockTarget = [IntPtr]::Zero; $locked = $false }
        else {
          $working = (-not $paused) -and (Test-Fresh 'working' ([int]$cfg.lockIdleSeconds))
          if ($working -and $cfg.escUnlocks -and ($fg -eq $lockTarget) -and (Test-InterruptKey)) {
            Remove-Item (Join-Path $StateDir 'working') -Force
            $working = $false
          }
          if ($working) {
            [StfuWin]::SetCloseEnabled($lockTarget, $false, (-not $locked))   # re-asserted every tick
            $locked = $true
          } elseif ($locked) {
            [StfuWin]::SetCloseEnabled($lockTarget, $true, $true)
            $locked = $false
          }
        }
      }
    }

    # ---------- minimize new windows: Claude's apps AND their pop-ups / loading screens ----------
    $newOnes = @()
    foreach ($w in $current) {
      $k = $w.H.ToInt64()
      if ($seen.Contains($k)) { continue }
      [void]$seen.Add($k)
      $newOnes += $w
    }
    if ($newOnes.Count -gt 0 -and -not $paused) {
      $newSet = New-Object 'System.Collections.Generic.HashSet[int64]'
      foreach ($w in $newOnes) { [void]$newSet.Add($w.H.ToInt64()) }
      # Apps that currently have a normal, restored window = you are using them -> leave their pop-ups alone.
      $active = New-Object 'System.Collections.Generic.HashSet[uint32]'
      foreach ($w in $current) {
        if ($newSet.Contains($w.H.ToInt64())) { continue }
        if ((-not $w.Owned) -and (-not $w.Tool) -and $w.Titled -and (-not $w.Iconic)) { [void]$active.Add($w.Pid) }
      }
      foreach ($w in $newOnes) {
        $wp = [int]$w.Pid
        if ($protect.Contains($wp) -or $w.H -eq $lockTarget) { continue }
        $normal = (-not $w.Owned) -and (-not $w.Tool) -and $w.Titled
        $go = $false
        # A) a browser window that appeared while Claude was working (browsers reuse an existing process)
        if ($busy -and $normal -and $procs.ContainsKey($wp)) {
          $n = ($procs[$wp].Name -replace '\.exe$','').ToLower()
          if ($cfg.watchProcessNames -contains $n) { $go = $true }
        }
        # B) Claude's own apps, and any app we already minimized: every new window (dialog, splash,
        #    loading page, pop-up) is minimized too, unless the app has a restored window = you use it now.
        if ((-not $go) -and (-not $active.Contains($w.Pid))) {
          if ($cfg.minimizeDescendants -and $desc.Contains($wp)) { $go = $true }
          elseif ($cfg.minimizePopups -and $managed.Contains($wp)) { $go = $true }
        }
        if ($go) {
          [void][StfuWin]::ShowWindowAsync($w.H, 7)   # SW_SHOWMINNOACTIVE
          [void]$managed.Add($wp)
          $pending[$w.H.ToInt64()] = $tick
          $minimizedAny = $true
        }
      }
    }
    # Some pop-ups (splash screens) ignore minimize: if still on screen a moment later, push them to the bottom.
    foreach ($key in @($pending.Keys)) {
      if ($tick - $pending[$key] -lt 2) { continue }
      $pending.Remove($key)
      $hh = [IntPtr][int64]$key
      if ([StfuWin]::Exists($hh) -and [StfuWin]::IsWindowVisible($hh) -and (-not [StfuWin]::IsIconic($hh))) { [StfuWin]::SendToBottom($hh) }
    }

    # Give focus back to what the user was doing (fullscreen app / game).
    if ($minimizedAny -and $cfg.restoreFocus -and $prevFg -ne [IntPtr]::Zero -and [StfuWin]::Exists($prevFg)) {
      Start-Sleep -Milliseconds 120
      if ([StfuWin]::GetForegroundWindow() -ne $prevFg) { [void][StfuWin]::SetForegroundWindow($prevFg) }
    } elseif (-not $minimizedAny -and $fg -ne [IntPtr]::Zero) {
      $prevFg = $fg
    }

    # Forget handles of windows that no longer exist.
    if ($tick % 25 -eq 0) {
      $alive = New-Object 'System.Collections.Generic.HashSet[int64]'
      foreach ($w in $current) { [void]$alive.Add($w.H.ToInt64()) }
      $seen.IntersectWith($alive)
    }
  }
}
finally {
  # Never leave the user's window with a dead close button.
  if ($lockTarget -ne [IntPtr]::Zero -and [StfuWin]::Exists($lockTarget)) {
    [StfuWin]::SetCloseEnabled($lockTarget, $true, $true)
  }
}
