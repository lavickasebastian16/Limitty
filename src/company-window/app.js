'use strict';

const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const NAMES = { claude: 'Claude Code', codex: 'Codex', agy: 'Antigravity', you: 'you', rules: 'rules' };
const MODEL_LABELS = { opus: 'Opus', sonnet: 'Sonnet', haiku: 'Haiku', high: 'high effort', medium: 'medium effort', low: 'low effort', pro: 'Gemini Pro', flash: 'Gemini Flash' };
const STATUS = { queued: 'Waiting', planning: 'CEO is planning', running: 'Working', done: 'Done', failed: 'Failed', cancelled: 'Cancelled' };
let state = null;
let openOutputs = new Set();

function ago(ms) {
  const s = Math.max(0, Math.round((Date.now() - ms) / 1000));
  if (s < 60) return 'just now';
  if (s < 3600) return `${Math.floor(s / 60)} min ago`;
  if (s < 86400) return `${Math.floor(s / 3600)} h ago`;
  return `${Math.floor(s / 86400)} d ago`;
}

function duration(a, b) {
  const s = Math.round(((b || Date.now()) - a) / 1000);
  return s < 60 ? `${s}s` : `${Math.floor(s / 60)}m ${s % 60}s`;
}

let teamCfg = null; // { ceo, strengths, defaultStrengths, agents }

/** The team: who's the CEO, and each agent's role (what the CEO gives them). */
function renderTeam() {
  if (!teamCfg) return;
  if (document.activeElement?.closest('#roles, #ceo')) return; // don't redraw while you type
  $('ceo').value = teamCfg.ceo;
  $('roles').innerHTML = ['claude', 'codex', 'agy'].map((id) => {
    const a = teamCfg.agents.find((x) => x.id === id) || {};
    const t = state.team?.[id] || {};
    const status = !a.chosen ? ['off', 'not used'] : !a.installed ? ['off', 'not installed'] : a.signedIn === false ? ['off', 'not signed in']
      : t.busy ? ['', 'working'] : ['', t.remaining == null ? 'ready' : `ready · ${Math.round(t.remaining)}% left`];
    return `<div class="role">
      <div class="who"><span><span class="dot ${id}"></span>${NAMES[id]}${teamCfg.ceo === id ? ' <b class="ceo">CEO</b>' : ''}</span><small class="${status[0]}">${status[1]}</small></div>
      <input data-role="${id}" list="roleIdeas" value="${esc(teamCfg.strengths[id])}" placeholder="${esc(teamCfg.defaultStrengths[id])}" aria-label="${NAMES[id]}'s role">
    </div>`;
  }).join('');
}

async function loadTeam() {
  teamCfg = await window.company.team();
  renderTeam();
}

$('ceo').addEventListener('change', async (e) => { teamCfg = await window.company.setTeam({ ceo: e.target.value }); $('ceo').blur(); renderTeam(); });
$('roles').addEventListener('change', async (e) => {
  const id = e.target.dataset.role;
  if (!id) return;
  teamCfg = await window.company.setTeam({ strengths: { [id]: e.target.value } });
});
$('roles').addEventListener('focusout', () => setTimeout(renderTeam, 100));

$('testTeam').addEventListener('click', async () => {
  const box = $('testResults');
  $('testTeam').disabled = true;
  box.hidden = false;
  box.innerHTML = '<div><span class="spin"></span>Asking each agent to reply… (up to 2 minutes)</div>';
  const results = await window.company.testTeam();
  $('testTeam').disabled = false;
  box.innerHTML = results.map((r) => `<div class="${r.ok ? 'ok' : 'bad'}">${r.ok ? '✓' : '✗'} ${NAMES[r.id]}: ${r.ok ? 'works' : 'problem'}</div>${r.ok ? '' : `<pre>${esc(r.text)}</pre>`}`).join('')
    || '<div class="bad">No agents chosen. Open Agents… to install and sign in.</div>';
  loadTeam();
});

function renderProjects() {
  const sel = $('project');
  const keep = sel.value;
  sel.innerHTML = state.projects.length
    ? state.projects.map((p) => `<option value="${esc(p.name)}" title="${esc(p.path)}">${esc(p.name)}${p.saved === false ? ' (recent)' : ''}</option>`).join('')
    : '<option value="">Add a project folder →</option>';
  if (state.projects.some((p) => p.name === keep)) sel.value = keep;
}

/** The answer you asked for: the last step's output once the task is done (or how far it got). */
function result(t) {
  const steps = t.plan?.steps || [];
  if (t.status === 'done') {
    const last = [...steps].reverse().find((x) => x.status === 'done' && x.output);
    return last ? `<div class="result"><b>Result</b><pre>${esc(last.output)}</pre></div>` : '';
  }
  if (t.status === 'failed') {
    const last = [...steps].reverse().find((x) => x.output && x.status === 'failed');
    return last ? `<div class="result failed"><b>What went wrong</b><pre>${esc(last.output)}</pre></div>` : '';
  }
  return '';
}

function renderTasks() {
  if (!state.tasks.length) {
    $('tasks').innerHTML = '<div class="empty">No tasks yet. Describe one above, or send one from Limitty on your iPhone.</div>';
    return;
  }
  $('tasks').innerHTML = state.tasks.map((t) => {
    const active = ['queued', 'planning', 'running'].includes(t.status);
    const steps = (t.plan?.steps || []).map((s) => {
      const key = `${t.id}:${s.id}`;
      const st = s.status === 'running' ? `<span class="spin"></span>working · ${duration(s.startedAt)}`
        : s.finishedAt ? `${s.status} · ${duration(s.startedAt, s.finishedAt)}` : s.status;
      return `<li class="step">
        <div class="step-head"><span class="badge"><span class="dot ${s.worker}"></span>${NAMES[s.worker]}${MODEL_LABELS[s.model] ? ` · ${MODEL_LABELS[s.model]}` : ''}${t.plan.by === s.worker ? ' <b class="ceo">CEO</b>' : ''}</span>
          <span>${esc(s.title)}</span><span class="step-status ${s.status}">${st}</span></div>
        ${s.why ? `<div class="why">Why ${NAMES[s.worker]}: ${esc(s.why)}</div>` : ''}
        ${s.output ? `<details data-key="${key}" ${openOutputs.has(key) ? 'open' : ''}><summary>Output</summary><pre>${esc(s.output)}</pre></details>` : ''}
      </li>`;
    }).join('');
    return `<article class="task">
      <header>
        <div><h2>${esc(t.title)}</h2>
          <div class="meta">${esc(t.project.name)} · ${t.source === 'phone' ? 'from your iPhone · ' : ''}${ago(t.createdAt)}</div></div>
        <span class="status ${t.status}">${t.status === 'planning' ? '<span class="spin"></span>' : ''}${STATUS[t.status]}</span>
      </header>
      ${t.plan ? `<p class="plan">CEO (${NAMES[t.plan.by] || t.plan.by}): ${esc(t.plan.summary)}</p>` : ''}
      ${result(t)}
      ${t.error ? `<p class="error">${esc(t.error)}</p>` : ''}
      ${steps ? (active ? `<ul class="steps">${steps}</ul>`
        : `<details class="how" data-key="${t.id}:how" ${openOutputs.has(`${t.id}:how`) ? 'open' : ''}><summary>How the team did it (${t.plan.steps.length} step${t.plan.steps.length > 1 ? 's' : ''})</summary><ul class="steps">${steps}</ul></details>`) : ''}
      <div class="actions">
        ${active ? `<button class="small ghost" data-act="cancel" data-id="${t.id}">Cancel</button>` : ''}
        ${['failed', 'cancelled', 'done'].includes(t.status) ? `<button class="small ghost" data-act="retry" data-id="${t.id}">Run again</button>` : ''}
        ${!active ? `<button class="small ghost" data-act="remove" data-id="${t.id}">Remove</button>` : ''}
      </div>
    </article>`;
  }).join('');
}

function render(s) {
  state = { ...state, ...s };
  s = state;
  if (s.version) $('version').textContent = `Limitty ${s.version}`;
  $('remote').hidden = s.owner !== false;
  renderTeam();
  renderProjects();
  renderTasks();
}

document.addEventListener('toggle', (e) => {
  const key = e.target.dataset?.key;
  if (key) (e.target.open ? openOutputs.add(key) : openOutputs.delete(key));
}, true);

$('tasks').addEventListener('click', async (e) => {
  const b = e.target.closest('button[data-act]');
  if (!b) return;
  b.disabled = true;
  await window.company[b.dataset.act](b.dataset.id);
});

$('addProject').addEventListener('click', async () => {
  const name = await window.company.addProject();
  if (name) setTimeout(async () => { render(await window.company.state()); $('project').value = name; }, 600);
});

$('new').addEventListener('submit', async (e) => {
  e.preventDefault();
  const title = $('title').value.trim();
  const project = $('project').value;
  $('formError').hidden = true;
  if (!project) {
    // No project yet: pick the folder now, then send.
    const name = await window.company.addProject();
    if (!name) { $('formError').textContent = 'Pick the project folder the team should work in.'; $('formError').hidden = false; return; }
    await new Promise((r) => setTimeout(r, 600));
    render(await window.company.state());
    $('project').value = name;
    return $('new').requestSubmit();
  }
  $('submit').disabled = true;
  await window.company.create({ title, project, worker: $('worker').value });
  $('title').value = '';
  $('submit').disabled = false;
});

window.company.onUpdate(render);
window.company.state().then(render);
loadTeam();
setInterval(loadTeam, 15000);
setInterval(async () => render(await window.company.state()), 5000); // keep times fresh
$('chooseAgents').addEventListener('click', () => window.company.chooseAgents());
