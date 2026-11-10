'use strict';

// The CEO: reads a task, splits it into steps if useful, and hands each step to
// the best worker and model, weighing how hard the step is against how much usage
// limit each model has left. The CEO is on the team too and can take steps itself.

const fs = require('fs');
const { WORKERS, run } = require('./workers');

const MAX_STEPS = 6;
const LOW_LIMIT = 15; // % left below which a model is avoided if possible
const TIER_ORDER = { strongest: 0, balanced: 1, fast: 2 };

/**
 * team: { claude: { available, busy, remaining, models: [{ id, label, tier, remaining }] }, … }
 * `remaining` = % left on the tightest limit (null if unknown).
 */
function describeTeam(team, ceo) {
  return Object.entries(WORKERS).map(([id, w]) => {
    const t = team[id] || {};
    const me = id === ceo ? ' ← this is you, the CEO; you may take steps yourself' : '';
    if (!t.available) return `- ${id} (${w.name}): NOT AVAILABLE${me}`;
    const models = (t.models || []).map((m) => `${m.id} [${m.tier}${m.remaining == null ? '' : `, ${Math.round(m.remaining)}% left`}]`).join(', ');
    const left = t.remaining == null ? 'limit unknown' : `${Math.round(t.remaining)}% of its usage limit left`;
    return `- ${id} (${w.name})${me}: ${left}${t.busy ? ', currently busy' : ''}. Good at: ${t.strengths || w.strengths}. Models: ${models}.`;
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

function prompt(task, team, ceo = 'claude') {
  return `You are the CEO of a small software team working on this PC. You are ${WORKERS[ceo]?.name || ceo}. Plan this task, and assign each step to a worker and a model. You are also a worker: assign steps to yourself when you're the best fit.

Task: ${task.title}
Project: ${task.project.name} (${task.project.path})
Top-level files: ${projectOverview(task.project.path)}

Team (usage limits are live):
${describeTeam(team, ceo)}

Rules:
- Split the task into parts by what each worker is best at (their "Good at" above), and give every part to the worker whose strengths fit it best. The split does NOT have to be even: one worker may get most of the work and another none. Never add steps just to keep someone busy.
- A small or single-topic task is ONE step. Use more steps only when the parts really need different strengths (for example UI work, backend logic, tests, review). Never more than ${MAX_STEPS} steps.
- For bigger changes, end with a short review or test step by a different worker than the one that wrote most of the code.
- Steps run in order, in the project folder; each worker sees the results of earlier steps.
- Only assign available workers and models from their list.
- Match the model to the work: "strongest" for hard design, tricky bugs or large refactors; "balanced" for normal coding; "fast" for small edits, docs, formatting or simple questions. Don't use a stronger model than the step needs.
- Usage limits: if two workers fit a part about equally well, pick the one with more limit left. Avoid any model under ${LOW_LIMIT}% left unless nothing else can do it.
- Each instruction must be complete and self-contained: the worker sees only that instruction and earlier results.
- You may look at files to plan, but do not change anything now.

Reply with ONLY this JSON, nothing else:
{"summary": "one sentence plan", "steps": [{"worker": "claude|codex|agy", "model": "model id from the list", "title": "short step name", "why": "which strength of this worker fits this part (a few words)", "instruction": "full instruction"}]}`;
}

/** The model to use when none (or an invalid one) was chosen: balanced if it has room, else the roomiest. */
function pickModel(info, preferTier = 'balanced') {
  const models = info?.models || [];
  if (!models.length) return null;
  const roomy = (m) => m.remaining == null || m.remaining >= LOW_LIMIT;
  const byTier = [...models].sort((a, b) => Math.abs(TIER_ORDER[a.tier] - TIER_ORDER[preferTier]) - Math.abs(TIER_ORDER[b.tier] - TIER_ORDER[preferTier]));
  return (byTier.find(roomy) || [...models].sort((a, b) => (b.remaining ?? 50) - (a.remaining ?? 50))[0]).id;
}

/** Pulls the plan JSON out of the CEO's reply and checks workers and models. */
function parsePlan(text, team) {
  const available = Object.keys(WORKERS).filter((id) => team[id]?.available);
  const s = String(text || '');
  const start = s.indexOf('{');
  const end = s.lastIndexOf('}');
  if (start === -1 || end <= start || !available.length) return null;
  let j;
  try { j = JSON.parse(s.slice(start, end + 1)); } catch { return null; }
  const steps = (Array.isArray(j.steps) ? j.steps : [])
    .filter((st) => st && typeof st.instruction === 'string' && st.instruction.trim())
    .slice(0, MAX_STEPS)
    .map((st) => {
      const worker = available.includes(st.worker) ? st.worker : pickWorker(team);
      const models = team[worker]?.models || [];
      const model = models.some((m) => m.id === st.model) ? st.model : pickModel(team[worker]);
      const why = worker === st.worker && typeof st.why === 'string' ? st.why.trim().slice(0, 120) : '';
      return { worker, model, title: String(st.title || st.instruction).slice(0, 80), why, instruction: st.instruction.trim() };
    });
  if (!steps.length) return null;
  return { summary: String(j.summary || '').slice(0, 400), steps };
}

/** Without AI: one step for the free, available worker with the most limit left. */
function rulePlan(task, team) {
  const worker = pickWorker(team);
  if (!worker) return null;
  const model = pickModel(team[worker]);
  const label = team[worker].models?.find((m) => m.id === model)?.label;
  return {
    summary: `Assigned to ${WORKERS[worker].name}${label ? ` (${label})` : ''}: most usage limit left.`,
    by: 'rules',
    steps: [{ worker, model, title: task.title.slice(0, 80), instruction: task.title }],
  };
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
function makePlan(task, team, { ceo = 'claude', runImpl = run, opts = {} } = {}) {
  if (task.worker && task.worker !== 'auto') {
    // You picked the worker: no planning needed; the model still follows the limits.
    const model = pickModel(team[task.worker]);
    const label = team[task.worker]?.models?.find((m) => m.id === model)?.label;
    const plan = {
      summary: `Assigned to ${WORKERS[task.worker].name}${label ? ` (${label})` : ''}: your choice.`,
      by: 'you',
      steps: [{ worker: task.worker, model, title: task.title.slice(0, 80), instruction: task.title }],
    };
    return { plan: Promise.resolve(plan), cancel: () => {} };
  }
  const planner = ceo !== 'rules' && team[ceo]?.available ? ceo : null;
  if (!planner) return { plan: Promise.resolve(rulePlan(task, team)), cancel: () => {} };

  // Planning is light work: use the CEO's fast-ish model to save its limit.
  const planModel = pickModel(team[planner], 'balanced');
  const job = runImpl(planner, prompt(task, team, planner), { cwd: task.project.path, mode: 'plan', timeoutMs: 5 * 60_000, model: planModel, opts });
  const plan = job.promise.then((r) => {
    const p = r.ok ? parsePlan(r.text, team) : null;
    if (p) return { ...p, by: planner };
    const fallback = rulePlan(task, team);
    if (fallback) fallback.summary += ` (The ${WORKERS[planner].name} CEO couldn't plan: ${r.ok ? 'unclear answer' : r.text.slice(0, 120)})`;
    return fallback;
  });
  return { plan, cancel: job.cancel };
}

module.exports = { makePlan, parsePlan, rulePlan, pickWorker, pickModel, prompt, MAX_STEPS, LOW_LIMIT };
