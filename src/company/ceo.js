'use strict';

// The CEO: reads a task, splits it into steps if useful, and hands each step to
// the best worker, preferring whoever has the most usage limit left.

const fs = require('fs');
const path = require('path');
const { WORKERS, run } = require('./workers');

const MAX_STEPS = 4;

/**
 * Team info for planning: { claude: { available, busy, remaining }, ... }.
 * `remaining` is the % left on the worker's tightest limit (null if unknown).
 */
function describeTeam(team) {
  return Object.entries(WORKERS).map(([id, w]) => {
    const t = team[id] || {};
    if (!t.available) return `- ${id} (${w.name}): NOT AVAILABLE`;
    const left = t.remaining == null ? 'limit unknown' : `${Math.round(t.remaining)}% of its usage limit left`;
    return `- ${id} (${w.name}): ${left}${t.busy ? ', currently busy' : ''}. Good at ${w.strengths}.`;
  }).join('\n');
}

function projectOverview(dir) {
  try {
    return fs.readdirSync(dir, { withFileTypes: true })
      .filter((e) => !e.name.startsWith('.') && e.name !== 'node_modules')
      .slice(0, 60)
      .map((e) => (e.isDirectory() ? `${e.name}/` : e.name))
      .join(', ');
  } catch {
    return '(could not list files)';
  }
}

function prompt(task, team) {
  return `You are the CEO of a small software team working on this PC. Plan this task and assign it to your workers.

Task: ${task.title}
Project: ${task.project.name} (${task.project.path})
Top-level files: ${projectOverview(task.project.path)}

Workers:
${describeTeam(team)}

Rules:
- Use ONE step unless the task clearly has separate parts; never more than ${MAX_STEPS} steps.
- Steps run in order, in the project folder; each worker sees the results of earlier steps.
- Only assign available workers. Among suitable workers, prefer the one with the most limit left.
- Each instruction must be complete and self-contained: the worker sees only that instruction and earlier results.
- You may look at files to plan, but do not change anything.

Reply with ONLY this JSON, nothing else:
{"summary": "one sentence plan", "steps": [{"worker": "claude|codex|agy", "title": "short step name", "instruction": "full instruction"}]}`;
}

/** Pulls the plan JSON out of the CEO's reply. */
function parsePlan(text, available) {
  const s = String(text || '');
  const start = s.indexOf('{');
  const end = s.lastIndexOf('}');
  if (start === -1 || end <= start) return null;
  let j;
  try { j = JSON.parse(s.slice(start, end + 1)); } catch { return null; }
  const steps = (Array.isArray(j.steps) ? j.steps : [])
    .filter((st) => st && typeof st.instruction === 'string' && st.instruction.trim())
    .slice(0, MAX_STEPS)
    .map((st) => ({
      worker: available.includes(st.worker) ? st.worker : available[0],
      title: String(st.title || st.instruction).slice(0, 80),
      instruction: st.instruction.trim(),
    }));
  if (!steps.length) return null;
  return { summary: String(j.summary || '').slice(0, 300), steps };
}

/** Without AI: one step for the free, available worker with the most limit left. */
function rulePlan(task, team) {
  const worker = pickWorker(team);
  if (!worker) return null;
  return { summary: `Assigned to ${WORKERS[worker].name} (most limit left).`, by: 'rules', steps: [{ worker, title: task.title.slice(0, 80), instruction: task.title }] };
}

function pickWorker(team, exclude = []) {
  const ranked = Object.keys(WORKERS)
    .filter((id) => team[id]?.available && !exclude.includes(id))
    .sort((a, b) => (team[a].busy - team[b].busy) || ((team[b].remaining ?? 50) - (team[a].remaining ?? 50)));
  return ranked[0] || null;
}

/**
 * Makes the plan. `ceo` is 'claude' | 'codex' | 'agy' | 'rules'. If the AI CEO isn't
 * available or its answer can't be used, falls back to the rules.
 * Returns { plan, cancel }.
 */
function makePlan(task, team, { ceo = 'claude', runImpl = run } = {}) {
  const available = Object.keys(WORKERS).filter((id) => team[id]?.available);
  if (task.worker && task.worker !== 'auto') {
    // You picked the worker: no planning needed.
    const plan = { summary: `Assigned to ${WORKERS[task.worker].name} (your choice).`, by: 'you', steps: [{ worker: task.worker, title: task.title.slice(0, 80), instruction: task.title }] };
    return { plan: Promise.resolve(plan), cancel: () => {} };
  }
  const planner = ceo !== 'rules' && team[ceo]?.available ? ceo : null;
  if (!planner) return { plan: Promise.resolve(rulePlan(task, team)), cancel: () => {} };

  const job = runImpl(planner, prompt(task, team), { cwd: task.project.path, mode: 'plan', timeoutMs: 5 * 60_000 });
  const plan = job.promise.then((r) => {
    const p = r.ok ? parsePlan(r.text, available) : null;
    if (p) return { ...p, by: planner };
    const fallback = rulePlan(task, team);
    if (fallback) fallback.summary += ` (The ${WORKERS[planner].name} CEO couldn't plan: ${r.ok ? 'unclear answer' : r.text.slice(0, 120)})`;
    return fallback;
  });
  return { plan, cancel: job.cancel };
}

module.exports = { makePlan, parsePlan, rulePlan, pickWorker, prompt, MAX_STEPS };
