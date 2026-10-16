#!/usr/bin/env node
// STFU!Clawd — hook entry point.
// Subcommands: start | busy | stop | ctl <pause|resume|status>
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

const cmd = process.argv[2] || '';
const HOME_CLAUDE = path.join(os.homedir(), '.claude');
const PAUSE_FILE = path.join(HOME_CLAUDE, 'stfu-clawd.paused');
const CONFIG_FILE = path.join(HOME_CLAUDE, 'stfu-clawd.json');
const ROOT_STATE = path.join(os.tmpdir(), 'stfu-clawd');

function alive(pid) {
  try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; }
}

function readStdin() {
  return new Promise((resolve) => {
    if (process.stdin.isTTY) return resolve('');
    let data = '';
    const t = setTimeout(() => resolve(data), 800);
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (c) => (data += c));
    process.stdin.on('end', () => { clearTimeout(t); resolve(data); });
    process.stdin.on('error', () => { clearTimeout(t); resolve(data); });
  });
}

function stateDirFor(sessionId) {
  const safe = String(sessionId || 'default').replace(/[^a-zA-Z0-9_-]/g, '_');
  return path.join(ROOT_STATE, safe);
}

function startWatcher(dir) {
  fs.mkdirSync(dir, { recursive: true });
  const pidFile = path.join(dir, 'watcher.pid');
  try {
    const old = parseInt(fs.readFileSync(pidFile, 'utf8'), 10);
    if (old && alive(old)) return; // already running for this session
  } catch (_) {}
  try { fs.unlinkSync(path.join(dir, 'stop')); } catch (_) {}

  const here = __dirname;
  const hookPid = String(process.ppid);
  let child;
  if (process.platform === 'win32') {
    child = spawn('powershell.exe', [
      '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
      '-File', path.join(here, 'STFU.ps1'),
      '-HookPid', hookPid, '-StateDir', dir, '-PausePath', PAUSE_FILE, '-ConfigPath', CONFIG_FILE,
    ], { detached: true, stdio: 'ignore', windowsHide: true });
  } else {
    child = spawn(process.execPath, [
      path.join(here, 'watcher.js'), hookPid, dir, PAUSE_FILE, CONFIG_FILE,
    ], { detached: true, stdio: 'ignore' });
  }
  child.unref();
  fs.writeFileSync(pidFile, String(child.pid));
}

function sleepSync(ms) {
  try { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms); } catch (_) {}
}

function stopWatcher(dir) {
  // Ask the watcher to exit on its own first: on Windows it must re-enable the
  // window's close button before it goes away. Kill it only if it doesn't comply.
  try { fs.writeFileSync(path.join(dir, 'stop'), '1'); } catch (_) {}
  try {
    const pid = parseInt(fs.readFileSync(path.join(dir, 'watcher.pid'), 'utf8'), 10);
    if (pid) {
      for (let i = 0; i < 20 && alive(pid); i++) sleepSync(100);
      if (alive(pid)) process.kill(pid);
    }
  } catch (_) {}
  try { fs.rmSync(dir, { recursive: true, force: true }); } catch (_) {}
}

(async () => {
  try {
    if (cmd === 'ctl') {
      const sub = (process.argv[3] || 'status').toLowerCase();
      fs.mkdirSync(HOME_CLAUDE, { recursive: true });
      if (sub === 'pause') { fs.writeFileSync(PAUSE_FILE, '1'); console.log('STFU!Clawd paused: windows will no longer be minimized automatically.'); }
      else if (sub === 'resume') { try { fs.unlinkSync(PAUSE_FILE); } catch (_) {} console.log('STFU!Clawd resumed: windows opened by Claude Code will be quietly minimized.'); }
      else if (sub === 'unlock') { // emergency exit: release every close-lock now (run from ANOTHER terminal)
        let n = 0;
        try { for (const d of fs.readdirSync(ROOT_STATE)) { try { fs.unlinkSync(path.join(ROOT_STATE, d, 'working')); n++; } catch (_) {} } } catch (_) {}
        console.log('Close-lock released (' + n + ' session(s)); the window close button comes back within 0.2 seconds.');
      }
      else console.log('STFU!Clawd status: ' + (fs.existsSync(PAUSE_FILE) ? 'paused' : 'running'));
      return;
    }
    let sessionId = 'default';
    try { sessionId = JSON.parse(await readStdin()).session_id || 'default'; } catch (_) {}
    const dir = stateDirFor(sessionId);
    if (cmd === 'start') startWatcher(dir);
    else if (cmd === 'work') { // UserPromptSubmit: Claude starts working
      fs.mkdirSync(dir, { recursive: true });
      fs.writeFileSync(path.join(dir, 'working'), String(Date.now()));
    } else if (cmd === 'busy') { // a tool is running / just ran: Claude is working
      fs.mkdirSync(dir, { recursive: true });
      const now = String(Date.now());
      fs.writeFileSync(path.join(dir, 'busy'), now);
      fs.writeFileSync(path.join(dir, 'working'), now);
    } else if (cmd === 'idle') { // Stop / Notification: Claude is done or waiting for you
      try { fs.unlinkSync(path.join(dir, 'working')); } catch (_) {}
    }
    else if (cmd === 'stop') stopWatcher(dir);
  } catch (_) { /* never break Claude Code */ }
  process.exit(0);
})();
