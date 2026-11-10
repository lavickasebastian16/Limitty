'use strict';

// Tasks, projects and the phone's processed requests, saved in ~/.limitty/company.json.

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { FILES } = require('../agents/config');

const FILE = path.join(FILES.dir, 'company.json');
const MAX_TASKS = 50;

/**
 * Task: { id, title, project: {name, path}, worker: 'auto'|'claude'|'codex'|'agy', source: 'pc'|'phone',
 *         status: 'queued'|'planning'|'running'|'done'|'failed'|'cancelled',
 *         plan: { summary, by, steps: [Step] } | null, error, createdAt, updatedAt }
 * Step: { id, worker, title, instruction, status: 'pending'|'running'|'done'|'failed'|'cancelled'|'skipped',
 *         output, startedAt, finishedAt }
 */
class TaskStore {
  constructor(file = FILE) {
    this.file = file;
    this.data = { projects: [], tasks: [], processed: [] };
    this.load();
  }

  load() {
    try { this.data = { ...this.data, ...JSON.parse(fs.readFileSync(this.file, 'utf8')) }; } catch { /* new */ }
    // Anything that was running when the PC stopped can't be resumed.
    for (const t of this.data.tasks) {
      if (t.status === 'planning' || t.status === 'running') {
        t.status = 'failed';
        t.error = 'Interrupted (Limitty or the PC was restarted). Retry to run it again.';
        for (const s of t.plan?.steps || []) if (s.status === 'running') s.status = 'failed';
      }
    }
  }

  save() {
    fs.mkdirSync(path.dirname(this.file), { recursive: true });
    fs.writeFileSync(this.file, JSON.stringify(this.data, null, 2));
  }

  get tasks() { return this.data.tasks; }
  get projects() { return this.data.projects; }

  get(id) { return this.data.tasks.find((t) => t.id === id); }

  create({ title, project, worker = 'auto', source = 'pc' }) {
    const now = Date.now();
    const task = {
      id: crypto.randomBytes(6).toString('hex'),
      title: String(title).trim().slice(0, 2000),
      project,
      worker,
      source,
      status: 'queued',
      plan: null,
      error: null,
      createdAt: now,
      updatedAt: now,
    };
    this.data.tasks.unshift(task);
    this.trim();
    this.save();
    return task;
  }

  update(id, change) {
    const t = this.get(id);
    if (!t) return null;
    change(t);
    t.updatedAt = Date.now();
    this.save();
    return t;
  }

  remove(id) {
    this.data.tasks = this.data.tasks.filter((t) => t.id !== id);
    this.save();
  }

  addProject(dir, name = path.basename(dir)) {
    const p = { name: uniqueName(this.data.projects, name, dir), path: dir };
    if (!this.data.projects.some((x) => samePath(x.path, dir))) {
      this.data.projects.push(p);
      this.save();
    }
    return this.data.projects.find((x) => samePath(x.path, dir));
  }

  removeProject(name) {
    this.data.projects = this.data.projects.filter((p) => p.name !== name);
    this.save();
  }

  /** Phone requests are processed once; remember their IDs. */
  markProcessed(id) {
    this.data.processed = [...this.data.processed.filter((x) => x !== id), id].slice(-300);
    this.save();
  }

  isProcessed(id) { return this.data.processed.includes(id); }

  trim() {
    // Keep active tasks; drop the oldest finished ones.
    const active = this.data.tasks.filter((t) => ['queued', 'planning', 'running'].includes(t.status));
    const finished = this.data.tasks.filter((t) => !active.includes(t)).slice(0, Math.max(0, MAX_TASKS - active.length));
    const keep = new Set([...active, ...finished]);
    this.data.tasks = this.data.tasks.filter((t) => keep.has(t));
  }
}

function samePath(a, b) {
  const norm = (p) => path.resolve(p).replace(/[\\/]+$/, '').toLowerCase();
  return norm(a) === norm(b);
}

function uniqueName(projects, name, dir) {
  const existing = projects.find((p) => samePath(p.path, dir));
  if (existing) return existing.name;
  let n = name;
  for (let i = 2; projects.some((p) => p.name === n); i++) n = `${name} ${i}`;
  return n;
}

module.exports = { TaskStore, FILE };
