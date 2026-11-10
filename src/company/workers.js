'use strict';

// The workers: Claude Code, Codex and Antigravity (agy), run headless in your
// project folder. Their hooks (if installed) also report live status to the
// Agents section, like when you run them yourself.

const crossSpawn = require('cross-spawn');
const tools = require('../tools');

// The agents' installers put them in ~/.local/bin; make sure we can start them from there.
tools.ensurePath();

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
        // "-" = read the prompt from stdin. workspace-write: edit files and run commands inside
        // the project folder (what --full-auto did; newer Codex versions removed that flag).
        args: ['exec', '--skip-git-repo-check', ...m, '--sandbox', mode === 'plan' ? 'read-only' : 'workspace-write', '-'],
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

/** Is the worker installed, and did you choose it on the Agents screen? (Cached for 10 seconds.) */
const installedCache = new Map();
function isInstalled(worker) {
  const hit = installedCache.get(worker);
  if (hit && Date.now() - hit.at < 10_000) return hit.ok;
  const ok = !!tools.find(worker) && tools.isChosen(worker);
  installedCache.set(worker, { ok, at: Date.now() });
  return ok;
}
isInstalled.clearCache = () => installedCache.clear();

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
        // Own process group, so Cancel also stops the commands the agent started.
        detached: process.platform !== 'win32',
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

/** Stops the agent and everything it started (its whole process group). */
function kill(child) {
  if (!child?.pid) return;
  if (process.platform === 'win32') {
    try { require('child_process').execFileSync('taskkill', ['/pid', String(child.pid), '/T', '/F'], { stdio: 'ignore' }); } catch { /* gone */ }
    return;
  }
  const signal = (sig) => { try { process.kill(-child.pid, sig); } catch { try { child.kill(sig); } catch { /* gone */ } } };
  signal('SIGTERM');
  setTimeout(() => signal('SIGKILL'), 5000).unref();
}

function tail(s) {
  s = String(s);
  return s.length > OUTPUT_LIMIT ? `…${s.slice(-OUTPUT_LIMIT)}` : s;
}

module.exports = { WORKERS, MODELS, modelsFor, modelArgs, command, run, isInstalled };
