'use strict';

// The workers: Claude Code, Codex and Antigravity (agy), run headless in your
// project folder. Their hooks (if installed) also report live status to the
// Agents section, like when you run them yourself.

const fs = require('fs');
const os = require('os');
const path = require('path');
const crossSpawn = require('cross-spawn');

const WORKERS = {
  claude: { name: 'Claude Code', bin: 'claude', strengths: 'complex reasoning, debugging, refactors across many files' },
  codex: { name: 'Codex', bin: 'codex', strengths: 'well-scoped implementation, tests, scripts' },
  agy: { name: 'Antigravity (Gemini)', bin: 'agy', strengths: 'frontend/UI work, quick edits, research' },
};

const OUTPUT_LIMIT = 6000;

/**
 * Models the CEO can choose per step. `tier` guides the choice; `limit` names the
 * per-model usage limit to check (see company.js → defaultLimits).
 *  - Claude Code: model aliases (`--model opus|sonnet|haiku`).
 *  - Codex: reasoning effort for its default model (`-c model_reasoning_effort=…`).
 *  - agy: Gemini Pro / Flash, only if you list your `agy models` slugs in
 *    ~/.limitty/agent.json → "workers": { "agyModels": { "pro": "…", "flash": "…" } }
 *    (agy's --model flag differs between versions).
 */
const MODELS = {
  claude: [
    { id: 'opus', label: 'Opus', tier: 'strongest', limit: 'opus' },
    { id: 'sonnet', label: 'Sonnet', tier: 'balanced', limit: 'sonnet' },
    { id: 'haiku', label: 'Haiku', tier: 'fast' },
  ],
  codex: [
    { id: 'high', label: 'high effort', tier: 'strongest' },
    { id: 'medium', label: 'medium effort', tier: 'balanced' },
    { id: 'low', label: 'low effort', tier: 'fast' },
  ],
  agy: [
    { id: 'pro', label: 'Gemini Pro', tier: 'strongest', limit: 'pro' },
    { id: 'flash', label: 'Gemini Flash', tier: 'fast', limit: 'flash' },
  ],
};

/** The models a worker offers with your settings. */
function modelsFor(worker, opts = {}) {
  if (worker === 'agy') {
    const slugs = opts.agyModels || {};
    const list = MODELS.agy.filter((m) => slugs[m.id]);
    return list.length ? list : [{ id: 'default', label: 'default model', tier: 'balanced' }];
  }
  return MODELS[worker] || [];
}

function modelArgs(worker, model, opts = {}) {
  if (!model || model === 'default') return [];
  if (worker === 'claude') return ['--model', model];
  if (worker === 'codex') return ['-c', `model_reasoning_effort="${model}"`];
  if (worker === 'agy' && opts.agyModels?.[model]) return ['--model', opts.agyModels[model]];
  return [];
}

/**
 * Command line for a worker. `mode`: 'work' (may edit files and run commands in the
 * project) or 'plan' (read-only, used by the CEO).
 */
function command(worker, prompt, mode = 'work', opts = {}, model = null) {
  const m = modelArgs(worker, model, opts);
  switch (worker) {
    case 'claude':
      return {
        bin: 'claude',
        // Prompt on stdin: no quoting problems on Windows, no length limits.
        args: ['-p', '--output-format', 'json', ...m,
          ...(mode === 'plan'
            ? ['--allowedTools', 'Read Glob Grep', '--disallowedTools', 'Edit Write Bash NotebookEdit']
            : ['--permission-mode', 'acceptEdits', ...(opts.allowCommands === false ? [] : ['--allowedTools', 'Bash'])])],
        stdin: prompt,
        parse: (out) => {
          try {
            const j = JSON.parse(out.trim().split('\n').pop());
            return { text: j.result ?? '', failed: j.is_error === true };
          } catch { return { text: out, failed: false }; }
        },
      };
    case 'codex':
      return {
        bin: 'codex',
        // "-" = read the prompt from stdin. --full-auto: edit + run commands inside the project sandbox.
        args: ['exec', '--skip-git-repo-check', ...m, ...(mode === 'plan' ? ['--sandbox', 'read-only'] : ['--full-auto']), '-'],
        stdin: prompt,
        parse: (out) => ({ text: out, failed: false }),
      };
    case 'agy':
      return {
        bin: process.env.ANTIGRAVITY_CLI_PATH || 'agy',
        args: ['-p', prompt, ...m, ...(opts.agyArgs || [])],
        stdin: null,
        env: { AGY_CLI_DISABLE_AUTO_UPDATE: 'true' },
        parse: (out) => ({ text: out, failed: false }),
      };
    default:
      throw new Error(`Unknown worker ${worker}`);
  }
}

/** Is the worker's CLI installed? (Cached for a minute.) */
const installedCache = new Map();
function isInstalled(worker) {
  const hit = installedCache.get(worker);
  if (hit && Date.now() - hit.at < 60_000) return hit.ok;
  const bin = worker === 'agy' ? (process.env.ANTIGRAVITY_CLI_PATH || 'agy') : WORKERS[worker].bin;
  const ok = path.isAbsolute(bin) ? fs.existsSync(bin) : onPath(bin);
  installedCache.set(worker, { ok, at: Date.now() });
  return ok;
}

function onPath(bin) {
  const exts = process.platform === 'win32' ? (process.env.PATHEXT || '.EXE;.CMD;.BAT').split(';') : [''];
  for (const dir of (process.env.PATH || '').split(path.delimiter)) {
    for (const ext of exts) {
      if (dir && fs.existsSync(path.join(dir, bin + ext.toLowerCase()))) return true;
      if (dir && ext && fs.existsSync(path.join(dir, bin + ext))) return true;
    }
  }
  const local = path.join(os.homedir(), '.local', 'bin', bin);
  return fs.existsSync(local);
}

/**
 * Runs a worker. Returns { promise, cancel }. The promise resolves to
 * { ok, text, code } and never rejects.
 */
function run(worker, prompt, { cwd, mode = 'work', timeoutMs = 45 * 60_000, opts = {}, model = null, onOutput } = {}) {
  const cmd = command(worker, prompt, mode, opts, model);
  let child;
  let out = '';
  let err = '';
  let finished = false;
  let cancelled = false;

  const promise = new Promise((resolve) => {
    let timer = null;
    const done = (result) => { if (!finished) { finished = true; clearTimeout(timer); resolve(result); } };
    try {
      child = crossSpawn(cmd.bin, cmd.args, {
        cwd,
        env: { ...process.env, ...cmd.env },
        stdio: [cmd.stdin == null ? 'ignore' : 'pipe', 'pipe', 'pipe'],
        windowsHide: true,
      });
    } catch (e) {
      done({ ok: false, text: `Couldn't start ${WORKERS[worker].name}: ${e.message}`, code: null });
      return;
    }
    timer = setTimeout(() => { kill(child); done({ ok: false, text: tail(`${out}\n${err}`) + `\n\nStopped after ${Math.round(timeoutMs / 60_000)} minutes.`, code: null }); }, timeoutMs);
    child.on('error', (e) => done({ ok: false, text: e.code === 'ENOENT' ? `${WORKERS[worker].name} isn't installed (couldn't find \`${cmd.bin}\`).` : e.message, code: null }));
    child.stdout.on('data', (d) => { out = tail(out + d); onOutput?.(out); });
    child.stderr.on('data', (d) => { err = tail(err + d); });
    child.on('close', (code) => {
      if (cancelled) return done({ ok: false, text: 'Cancelled.', code });
      const parsed = cmd.parse(out);
      const ok = code === 0 && !parsed.failed;
      done({ ok, text: tail(parsed.text || (ok ? 'Done.' : err) || `Exited with code ${code}`), code });
    });
    if (cmd.stdin != null) {
      child.stdin.on('error', () => {});
      child.stdin.end(cmd.stdin);
    }
  });

  return {
    promise,
    cancel: () => { cancelled = true; kill(child); },
  };
}

function kill(child) {
  if (!child || child.exitCode !== null) return;
  if (process.platform === 'win32') {
    try { require('child_process').execFileSync('taskkill', ['/pid', String(child.pid), '/T', '/F'], { stdio: 'ignore' }); } catch { /* gone */ }
  } else {
    try { child.kill('SIGTERM'); } catch { /* gone */ }
    setTimeout(() => { try { child.kill('SIGKILL'); } catch { /* gone */ } }, 5000).unref();
  }
}

function tail(s) {
  s = String(s);
  return s.length > OUTPUT_LIMIT ? `…${s.slice(-OUTPUT_LIMIT)}` : s;
}

module.exports = { WORKERS, MODELS, modelsFor, modelArgs, command, run, isInstalled };
