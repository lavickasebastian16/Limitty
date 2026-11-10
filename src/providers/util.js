'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFile } = require('child_process');

const HOME = os.homedir();

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return null;
  }
}

function run(cmd, args, opts = {}) {
  return new Promise((resolve) => {
    execFile(
      cmd,
      args,
      { timeout: opts.timeout ?? 10000, maxBuffer: 16 * 1024 * 1024, env: opts.env ?? process.env, windowsHide: true },
      (err, stdout, stderr) => resolve({ ok: !err, code: err?.code, stdout: String(stdout || ''), stderr: String(stderr || '') })
    );
  });
}

async function fetchJson(url, { headers = {}, method = 'GET', body, timeout = 15000 } = {}) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), timeout);
  try {
    const res = await fetch(url, { method, headers, body, signal: ctrl.signal });
    const text = await res.text();
    let json = null;
    try { json = JSON.parse(text); } catch { /* not JSON */ }
    return { status: res.status, ok: res.ok, json, text };
  } finally {
    clearTimeout(t);
  }
}

/** Normalise any timestamp-ish value (ISO string, epoch s, epoch ms) to epoch ms. */
function toMs(v) {
  if (v == null || v === '') return null;
  if (typeof v === 'number') return v < 1e12 ? v * 1000 : v;
  if (/^\d+(\.\d+)?$/.test(String(v))) return toMs(Number(v));
  const t = Date.parse(v);
  return Number.isNaN(t) ? null : t;
}

function clampPct(n) {
  if (n == null || Number.isNaN(Number(n))) return null;
  return Math.max(0, Math.min(100, Number(n)));
}

/** Human label for a rolling window length given in seconds. */
function windowLabel(seconds) {
  if (!seconds) return 'Limit';
  const h = seconds / 3600;
  if (h <= 24 && Math.abs(h - Math.round(h)) < 0.01) return `${Math.round(h)}h window`;
  const d = seconds / 86400;
  if (Math.abs(d - 7) < 0.1) return 'Weekly';
  if (Math.abs(d - 1) < 0.1) return 'Daily';
  if (Math.abs(d - Math.round(d)) < 0.01) return `${Math.round(d)}d window`;
  return `${Math.round(h)}h window`;
}

class ProviderError extends Error {
  constructor(message, hint) {
    super(message);
    this.hint = hint;
  }
}

module.exports = { HOME, readJson, run, fetchJson, toMs, clampPct, windowLabel, ProviderError, path, fs, os };
