'use strict';

// "Company" mode: you give tasks (on the PC or the iPhone), the CEO plans them,
// and the workers (Claude Code, Codex, agy) carry them out in your project folders.

const fs = require('fs');
const path = require('path');
const { EventEmitter } = require('events');
const { TaskStore } = require('./store');
const { WORKERS, run, isInstalled, modelsFor } = require('./workers');
const { makePlan } = require('./ceo');

const { FILES } = require('../agents/config');

const LIMITS_TTL_MS = 5 * 60_000;
const LOCAL_INBOX = path.join(FILES.dir, 'inbox.jsonl');
const PROVIDER_FOR = { claude: 'claude', codex: 'codex', agy: 'antigravity' };

class Company extends EventEmitter {
  constructor({
    store = new TaskStore(),
    ceo = 'claude',
    runImpl = run,
    installed = isInstalled,
    limits = defaultLimits,
    recentFolders = () => [],
    workerOptions = {},
  } = {}) {
    super();
    this.store = store;
    this.ceo = ceo;
    this.runImpl = runImpl;
    this.installed = installed;
    this.limits = limits;
    this.recentFolders = recentFolders;
    this.workerOptions = workerOptions;
    this.jobs = new Map(); // taskId → { cancel }
    this.busyWorkers = new Set();
    this.busyProjects = new Set();
    this.limitCache = { at: 0, value: {} };
    this.timer = null;
  }

  start() {
    this.timer = setInterval(() => this.tick(), 2000);
    this.refreshLimits();
    this.tick();
  }

  stop() {
    clearInterval(this.timer);
    for (const job of this.jobs.values()) job.cancel();
  }

  changed() {
    // Saved for the desktop window / CLI when they aren't the process running the Company.
    this.store.data.team = this.team();
    this.store.data.allProjects = this.projects();
    this.store.save();
    this.emit('change');
  }

  /** Requests dropped in ~/.limitty/inbox.jsonl by the desktop window or `limitty task`. */
  pollLocalInbox() {
    let text;
    try {
      text = fs.readFileSync(LOCAL_INBOX, 'utf8');
      fs.truncateSync(LOCAL_INBOX, 0);
    } catch { return; }
    const reqs = text.split('\n').map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
    if (reqs.length) this.handleInbox(reqs);
  }

  // ───── what you can do ─────

  /** project: a known project name, or a folder path. */
  create({ title, project, worker = 'auto', source = 'pc' }) {
    if (!title || !String(title).trim()) throw new Error('Describe the task first.');
    const p = this.resolveProject(project);
    if (!p) throw new Error(`Unknown project “${project}”. Add its folder in the Company window first.`);
    if (worker !== 'auto' && !WORKERS[worker]) throw new Error(`Unknown worker ${worker}`);
    const task = this.store.create({ title, project: p, worker, source });
    this.changed();
    setImmediate(() => this.tick());
    return task;
  }

  cancel(id) {
    this.jobs.get(id)?.cancel();
    this.store.update(id, (t) => {
      if (['done', 'failed', 'cancelled'].includes(t.status)) return;
      t.status = 'cancelled';
      for (const s of t.plan?.steps || []) if (s.status === 'pending' || s.status === 'running') s.status = 'cancelled';
    });
    this.changed();
  }

  retry(id) {
    // A task that's still going keeps going (the phone can ask at any moment).
    if (['queued', 'planning', 'running'].includes(this.store.get(id)?.status)) return;
    this.store.update(id, (t) => {
      t.status = 'queued';
      t.error = null;
      t.plan = null;
    });
    this.changed();
    setImmediate(() => this.tick());
  }

  remove(id) {
    this.cancel(id);
    this.store.remove(id);
    this.changed();
  }

  addProject(dir) {
    if (!fs.existsSync(dir) || !fs.statSync(dir).isDirectory()) throw new Error(`${dir} isn't a folder`);
    const p = this.store.addProject(path.resolve(dir));
    this.changed();
    return p;
  }

  removeProject(name) {
    this.store.removeProject(name);
    this.changed();
  }

  /** Your saved projects plus folders your agents worked in recently. */
  projects() {
    const saved = this.store.projects.map((p) => ({ ...p, saved: true }));
    const seen = new Set(saved.map((p) => p.path.toLowerCase()));
    const recent = [];
    for (const dir of this.recentFolders()) {
      if (!dir || seen.has(dir.toLowerCase()) || !fs.existsSync(dir)) continue;
      seen.add(dir.toLowerCase());
      let name = path.basename(dir);
      for (let i = 2; [...saved, ...recent].some((p) => p.name === name); i++) name = `${path.basename(dir)} ${i}`;
      recent.push({ name, path: dir, saved: false });
    }
    return [...saved, ...recent];
  }

  resolveProject(project) {
    if (!project) return null;
    const byName = this.projects().find((p) => p.name === project);
    if (byName) return { name: byName.name, path: byName.path };
    if (path.isAbsolute(project) && fs.existsSync(project)) {
      const p = this.store.addProject(project);
      return { name: p.name, path: p.path };
    }
    return null;
  }

  /** Requests from the phone (via the GitHub Gist). Each is handled once. */
  handleInbox(requests = []) {
    for (const r of requests) {
      if (!r?.id || this.store.isProcessed(r.id)) continue;
      this.store.markProcessed(r.id);
      try {
        if (r.kind === 'create') this.create({ title: r.title, project: r.project, worker: r.worker || 'auto', source: r.source || 'phone' });
        else if (r.kind === 'cancel') this.cancel(r.task);
        else if (r.kind === 'retry') this.retry(r.task);
        else if (r.kind === 'remove') this.remove(r.task);
        else if (r.kind === 'addProject') this.addProject(r.path);
        else if (r.kind === 'removeProject') this.removeProject(r.name);
      } catch (e) {
        // Show the problem as a failed task so the phone sees it.
        const t = this.store.create({ title: r.title || `(${r.kind})`, project: { name: r.project || r.path || '?', path: '' }, worker: 'auto', source: r.source || 'phone' });
        this.store.update(t.id, (x) => { x.status = 'failed'; x.error = e.message; });
        this.changed();
      }
    }
  }

  // ───── what the phone sees ─────

  snapshot() {
    const team = this.team();
    return {
      v: 1,
      projects: this.projects().map((p) => ({ name: p.name })),
      workers: Object.fromEntries(Object.entries(WORKERS).map(([id, w]) => [id, {
        name: w.name, strengths: team[id].strengths, available: team[id].available, busy: team[id].busy, remaining: team[id].remaining,
        models: team[id].models.map((m) => ({ id: m.id, label: m.label, tier: m.tier, remaining: m.remaining })),
      }])),
      ceo: this.ceo,
      tasks: this.store.tasks.slice(0, 30).map((t) => ({
        id: t.id,
        title: t.title,
        project: t.project.name,
        worker: t.worker,
        source: t.source,
        status: t.status,
        error: t.error,
        createdAt: Math.round(t.createdAt / 1000),
        updatedAt: Math.round(t.updatedAt / 1000),
        plan: t.plan && {
          summary: t.plan.summary,
          by: t.plan.by,
          steps: t.plan.steps.map((s) => ({
            worker: s.worker, model: s.model || null, modelLabel: modelLabel(s.worker, s.model, this.workerOptions),
            title: s.title, why: s.why || null, status: s.status,
            output: (s.output || '').slice(-1500),
            startedAt: s.startedAt && Math.round(s.startedAt / 1000),
            finishedAt: s.finishedAt && Math.round(s.finishedAt / 1000),
          })),
        },
      })),
    };
  }

  fingerprint() {
    return JSON.stringify(this.store.tasks.slice(0, 30).map((t) => [t.id, t.status, t.updatedAt]))
      + JSON.stringify(this.projects().map((p) => p.name));
  }

  // ───── the work ─────

  /**
   * Each worker: installed?, busy?, % left on its tightest limit, and its models
   * with their own % left (Claude's per-model weekly limits, Gemini Pro/Flash quotas).
   */
  team() {
    const limits = this.limitCache.value;
    return Object.fromEntries(Object.keys(WORKERS).map((id) => {
      const l = normalizeLimit(limits[id]);
      const models = modelsFor(id, this.workerOptions).map((m) => {
        const own = m.limit && l.models[m.limit] != null ? l.models[m.limit] : null;
        const remaining = own != null && l.overall != null ? Math.min(own, l.overall) : (own ?? l.overall);
        return { ...m, remaining };
      });
      const roomy = models.some((m) => m.remaining == null || m.remaining > 1);
      return [id, {
        name: WORKERS[id].name,
        strengths: this.workerOptions.strengths?.[id]?.trim() || WORKERS[id].strengths,
        available: this.installed(id) && (l.overall == null || l.overall > 1) && roomy,
        busy: this.busyWorkers.has(id),
        remaining: l.overall,
        models,
      }];
    }));
  }

  async refreshLimits() {
    if (Date.now() - this.limitCache.at < LIMITS_TTL_MS) return;
    this.limitCache.at = Date.now();
    try { this.limitCache.value = await this.limits(); } catch { /* keep the old values */ }
  }

  tick() {
    this.pollLocalInbox();
    this.refreshLimits();
    const tasks = [...this.store.tasks].reverse(); // oldest first

    // Plan one task at a time (planning uses the CEO's quota).
    if (!tasks.some((t) => t.status === 'planning')) {
      const next = tasks.find((t) => t.status === 'queued');
      if (next) this.plan(next);
    }

    for (const t of tasks) {
      if (t.status !== 'running' || this.jobs.has(t.id)) continue;
      const steps = t.plan.steps;
      const i = steps.findIndex((s) => s.status === 'pending');
      if (i === -1) continue;
      const step = steps[i];
      if (this.busyWorkers.has(step.worker) || this.busyProjects.has(t.project.path)) continue;
      this.runStep(t, i);
    }
  }

  plan(task) {
    if (!task.project?.path || !fs.existsSync(task.project.path)) {
      this.store.update(task.id, (t) => { t.status = 'failed'; t.error = `The project folder for “${task.project?.name}” isn't there. Pick a project and send the task again.`; });
      this.changed();
      return;
    }
    this.store.update(task.id, (t) => { t.status = 'planning'; });
    this.changed();
    const job = makePlan(task, this.team(), { ceo: this.ceo, runImpl: this.runImpl, opts: this.workerOptions });
    this.jobs.set(task.id, job);
    job.plan.then((plan) => {
      this.jobs.delete(task.id);
      const t = this.store.get(task.id);
      if (!t || t.status !== 'planning') return; // cancelled meanwhile
      if (!plan) {
        this.store.update(t.id, (x) => { x.status = 'failed'; x.error = 'No agent is ready. Open Agents (menu ⋯ → Agents) to install and sign in, or wait for a usage limit to reset.'; });
        this.emit('alert', { kind: 'failed', task: t });
      } else {
        this.store.update(t.id, (x) => {
          x.status = 'running';
          x.plan = { ...plan, steps: plan.steps.map((s, n) => ({ id: n + 1, ...s, status: 'pending', output: '', startedAt: null, finishedAt: null })) };
        });
      }
      this.changed();
      this.tick();
    });
  }

  runStep(task, i) {
    const step = task.plan.steps[i];
    const earlier = task.plan.steps.slice(0, i)
      .map((s) => `- Step ${s.id} (${WORKERS[s.worker].name}${s.model ? `, ${s.model}` : ''}): ${s.title}\n  Result: ${(s.output || '').slice(-800)}`)
      .join('\n');
    const instruction = `${step.instruction}\n\n(This is step ${i + 1} of ${task.plan.steps.length} for the task: "${task.title}".`
      + `${earlier ? `\nEarlier steps:\n${earlier}` : ''})`;

    this.busyWorkers.add(step.worker);
    this.busyProjects.add(task.project.path);
    this.store.update(task.id, (t) => { t.plan.steps[i].status = 'running'; t.plan.steps[i].startedAt = Date.now(); });
    this.changed();

    let lastSaved = 0;
    const job = this.runImpl(step.worker, instruction, {
      cwd: task.project.path,
      mode: 'work',
      model: step.model,
      opts: this.workerOptions,
      onOutput: (out) => {
        // Live output, saved at most every 10 s.
        if (Date.now() - lastSaved < 10_000) return;
        lastSaved = Date.now();
        this.store.update(task.id, (t) => { if (t.plan.steps[i].status === 'running') t.plan.steps[i].output = out; });
        this.changed();
      },
    });
    this.jobs.set(task.id, job);

    job.promise.then((r) => {
      this.jobs.delete(task.id);
      this.busyWorkers.delete(step.worker);
      this.busyProjects.delete(task.project.path);
      const t = this.store.update(task.id, (x) => {
        const s = x.plan.steps[i];
        if (x.status === 'cancelled') { s.status = 'cancelled'; return; }
        s.output = r.text;
        s.finishedAt = Date.now();
        s.status = r.ok ? 'done' : 'failed';
        if (!r.ok) {
          x.status = 'failed';
          x.error = `Step ${i + 1} (${WORKERS[step.worker].name}) failed.`;
          for (const later of x.plan.steps.slice(i + 1)) later.status = 'skipped';
        } else if (i === x.plan.steps.length - 1) {
          x.status = 'done';
        }
      });
      if (t && (t.status === 'done' || t.status === 'failed')) this.emit('alert', { kind: t.status, task: t });
      this.changed();
      this.tick();
    });
  }
}

/** Accepts a number (old format) or { overall, models }. */
function normalizeLimit(v) {
  if (v == null) return { overall: null, models: {} };
  if (typeof v === 'number') return { overall: v, models: {} };
  return { overall: v.overall ?? null, models: v.models || {} };
}

function modelLabel(worker, model, opts) {
  if (!model) return null;
  return modelsFor(worker, opts).find((m) => m.id === model)?.label || model;
}

/**
 * % left per worker, from Limitty's own limit readers:
 * { claude: { overall, models: { opus, sonnet } }, codex: { overall }, agy: { overall, models: { pro, flash } } }
 */
async function defaultLimits() {
  const { fetchAll } = require('../providers');
  const results = await fetchAll(Object.values(PROVIDER_FOR));
  return limitsFromResults(results);
}

function limitsFromResults(results) {
  const left = (windows) => (windows.length ? 100 - Math.max(...windows.map((w) => w.usedPercent ?? 0)) : null);
  const out = {};
  const claude = results.find((r) => r.id === 'claude');
  if (claude?.ok) {
    const general = claude.windows.filter((w) => w.id === 'five_hour' || w.id === 'seven_day');
    out.claude = {
      overall: left(general.length ? general : claude.windows),
      models: {
        opus: left(claude.windows.filter((w) => w.id === 'seven_day_opus')),
        sonnet: left(claude.windows.filter((w) => w.id === 'seven_day_sonnet')),
      },
    };
  }
  const codex = results.find((r) => r.id === 'codex');
  if (codex?.ok) out.codex = { overall: left(codex.windows), models: {} };
  const ag = results.find((r) => r.id === 'antigravity');
  if (ag?.ok) {
    const name = (w) => String(w.label).toLowerCase();
    const pro = left(ag.windows.filter((w) => name(w).includes('gemini') && !name(w).includes('flash')));
    const flash = left(ag.windows.filter((w) => name(w).includes('gemini') && name(w).includes('flash')));
    const best = [pro, flash].filter((x) => x != null);
    out.agy = { overall: best.length ? Math.max(...best) : left(ag.windows), models: { pro, flash } };
  }
  return out;
}

module.exports = { Company, defaultLimits, limitsFromResults, LOCAL_INBOX };
