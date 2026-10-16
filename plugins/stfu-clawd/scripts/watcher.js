#!/usr/bin/env node
// STFU!Clawd — Linux (X11) / macOS window watcher.
// usage: watcher.js <hookPid> <stateDir> <pausePath> <configPath>
'use strict';
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const [hookPid, stateDir, pausePath, configPath] = [parseInt(process.argv[2], 10), process.argv[3], process.argv[4], process.argv[5]];
const IS_MAC = process.platform === 'darwin';

const cfg = { graceSeconds: 8, minimizeDescendants: true, watchProcessNames: ['chrome', 'chromium', 'firefox', 'brave', 'msedge'] };
try { Object.assign(cfg, JSON.parse(fs.readFileSync(configPath, 'utf8'))); } catch (_) {}

const run = (bin, args) => { try { return execFileSync(bin, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 4000 }); } catch (_) { return null; } };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const alive = (pid) => { try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; } };

function procTable() {
  const t = new Map();
  const out = run('ps', ['-eo', 'pid=,ppid=,comm=']) || '';
  for (const line of out.split('\n')) {
    const m = line.trim().match(/^(\d+)\s+(\d+)\s+(.*)$/);
    if (m) t.set(+m[1], { pid: +m[1], ppid: +m[2], name: path.basename(m[3]).toLowerCase() });
  }
  return t;
}
function findRoot(t) {
  let cur = hookPid;
  for (let i = 0; i < 8 && t.has(cur); i++) {
    if (/^(claude|node|bun)/.test(t.get(cur).name)) return cur;
    cur = t.get(cur).ppid;
  }
  return t.has(hookPid) ? t.get(hookPid).ppid : 0;
}
function descendants(t, root) {
  const set = new Set();
  if (!root) return set;
  const stack = [root];
  while (stack.length) {
    const n = stack.pop();
    for (const p of t.values()) if (p.ppid === n && !set.has(p.pid)) { set.add(p.pid); stack.push(p.pid); }
  }
  return set;
}
function busy() {
  try { return Date.now() - parseInt(fs.readFileSync(path.join(stateDir, 'busy'), 'utf8'), 10) < cfg.graceSeconds * 1000; } catch (_) { return false; }
}

// ---------- Linux / X11 ----------
function linuxWindows() {
  const out = run('wmctrl', ['-lp']);
  if (out === null) return null;
  return out.split('\n').filter(Boolean).map((l) => {
    const m = l.match(/^(0x[0-9a-f]+)\s+(-?\d+)\s+(\d+)\s+/i);
    return m ? { id: m[1], pid: +m[3] } : null;
  }).filter(Boolean);
}
function linuxMinimize(id) {
  if (run('xdotool', ['windowminimize', id]) === null) run('wmctrl', ['-i', '-r', id, '-b', 'add,hidden']);
}

// ---------- macOS ----------
function macWindowCounts() {
  const script = 'tell application "System Events" to get {unix id, count of windows} of (every process whose background only is false)';
  const out = run('osascript', ['-e', script]);
  if (!out) return null;
  const nums = out.replace(/\s/g, '').split(',').map(Number);
  const half = nums.length / 2, m = new Map();
  for (let i = 0; i < half; i++) m.set(nums[i], nums[half + i]);
  return m;
}
function macMinimize(pid) {
  run('osascript', ['-e', `tell application "System Events" to tell (first process whose unix id is ${pid}) to set value of attribute "AXMinimized" of every window to true`]);
}

(async () => {
  let table = procTable();
  const root = findRoot(table);
  let desc = descendants(table, root);

  let seen = new Set(), counts = new Map();
  if (IS_MAC) counts = macWindowCounts() || new Map();
  else { const w = linuxWindows(); if (w === null) process.exit(0); /* no wmctrl / X11 */ w.forEach((x) => seen.add(x.id)); }

  for (let tick = 1; ; tick++) {
    if (fs.existsSync(path.join(stateDir, 'stop'))) break;
    if (root && !alive(root)) break;
    await sleep(400);
    if (tick % 3 === 0) { table = procTable(); desc = descendants(table, root); }
    const paused = fs.existsSync(pausePath);

    if (IS_MAC) {
      const now = macWindowCounts(); if (!now) continue;
      for (const [pid, n] of now) {
        if (!paused && cfg.minimizeDescendants && desc.has(pid) && n > (counts.get(pid) || 0)) macMinimize(pid);
      }
      counts = now;
    } else {
      const wins = linuxWindows(); if (!wins) continue;
      const isBusy = busy();
      for (const w of wins) {
        if (seen.has(w.id)) continue;
        seen.add(w.id);
        if (paused) continue;
        const name = (table.get(w.pid) || {}).name || '';
        const watched = isBusy && cfg.watchProcessNames.some((n) => name.includes(n));
        if ((cfg.minimizeDescendants && desc.has(w.pid)) || watched) linuxMinimize(w.id);
      }
    }
  }
})();
