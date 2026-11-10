'use strict';

/* global renderAll, renderAgents */
const $ = (id) => document.getElementById(id);
let results = [];
let fetchedAt = null;

function paint() {
  // Bar widths are set inline; CSP blocks inline style attributes, so apply them via JS.
  $('providers').innerHTML = renderAll(results).replace(/style="width:(\d+)%"/g, 'data-w="$1"');
  for (const el of document.querySelectorAll('.fill[data-w]')) el.style.width = `${el.dataset.w}%`;
  $('updated').textContent = fetchedAt ? `updated ${new Date(fetchedAt).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}` : '';
  window.limitty.resize(document.getElementById('card').getBoundingClientRect().height + 12);
}

window.limitty.onLoading(() => $('refresh').classList.add('spinning'));
window.limitty.onUpdate((r) => {
  results = r;
  fetchedAt = Date.now();
  $('refresh').classList.remove('spinning');
  paint();
});

$('refresh').addEventListener('click', () => window.limitty.refresh());
$('hide').addEventListener('click', () => window.limitty.hide());
$('menu').addEventListener('click', () => window.limitty.menu());
$('company').addEventListener('click', () => window.limitty.company());

// Keep the "resets in" countdowns fresh between fetches.
setInterval(() => { if (results.length) paint(); }, 30000);

window.limitty.get().then((r) => { if (r && r.length) { results = r; fetchedAt = Date.now(); paint(); } });

// ───── Prompt box: one task for your agents; the CEO plans it and splits it ─────

const ask = $('ask');
const askText = $('askText');
let askInfo = { projects: [], lastProject: null, active: 0, agents: 0 };

function fitAsk() {
  askText.style.height = 'auto';
  askText.style.height = `${Math.min(120, askText.scrollHeight)}px`;
  window.limitty.resize(document.getElementById('card').getBoundingClientRect().height + 12);
}

function paintAsk(info) {
  askInfo = info || askInfo;
  const sel = $('askProject');
  const cur = sel.value || askInfo.lastProject;
  sel.innerHTML = askInfo.projects.map((p) => `<option>${p.replace(/[&<>"]/g, (c) => `&#${c.charCodeAt(0)};`)}</option>`).join('')
    + '<option value="__add">Add folder…</option>';
  if (askInfo.projects.includes(cur)) sel.value = cur;
  let line = document.querySelector('.tasks-line');
  const text = askInfo.active ? `▸ ${askInfo.active} task${askInfo.active > 1 ? 's' : ''} in progress · open`
    : askInfo.last ? `${askInfo.last.status === 'done' ? '✓ Done' : '✗ Failed'}: ${askInfo.last.title} · see result`
      : '';
  if (text) {
    if (!line) {
      line = document.createElement('div');
      line.className = 'tasks-line';
      line.addEventListener('click', () => window.limitty.company());
      ask.after(line);
    }
    line.textContent = text;
    line.className = `tasks-line ${askInfo.active ? '' : askInfo.last.status}`;
  } else if (line) line.remove();
}

function setStatus(text, kind = '') {
  const el = $('askStatus');
  el.textContent = text;
  el.className = `ask-status ${kind}`;
}

askText.addEventListener('focus', () => { ask.classList.add('open'); fitAsk(); });
askText.addEventListener('input', fitAsk);
askText.addEventListener('blur', () => setTimeout(() => {
  if (!askText.value.trim() && document.activeElement?.closest('#ask') == null) { ask.classList.remove('open'); fitAsk(); }
}, 150));
askText.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); ask.requestSubmit(); }
  if (e.key === 'Escape') { askText.value = ''; askText.blur(); }
});
$('askProject').addEventListener('change', async (e) => {
  if (e.target.value !== '__add') return;
  const r = await window.limitty.ask({ addProject: true });
  paintAsk(r.info);
  if (r.added) e.target.value = r.added;
});

ask.addEventListener('submit', async (e) => {
  e.preventDefault();
  const title = askText.value.trim();
  if (!title) return;
  const project = $('askProject').value;
  if (!project || project === '__add') { setStatus('Pick a project folder first.', 'err'); return; }
  $('askSend').disabled = true;
  const r = await window.limitty.ask({ title, project });
  $('askSend').disabled = false;
  if (r.ok) {
    askText.value = '';
    setStatus('Sent to the CEO ✓', 'ok');
    setTimeout(() => setStatus(''), 4000);
  } else {
    setStatus(r.error || 'Couldn\'t send', 'err');
  }
  paintAsk(r.info);
  fitAsk();
});

window.limitty.onAskInfo(paintAsk);
window.limitty.onFocusAsk(() => { askText.focus(); });
window.limitty.askInfo().then((i) => { paintAsk(i); fitAsk(); });

// ───── Live agent status ─────

let agentsHtml = '';
async function paintAgents() {
  const html = renderAgents(await window.limitty.agentSessions());
  if (html === agentsHtml) return;
  agentsHtml = html;
  $('agents').innerHTML = html;
  $('agents').hidden = !html;
  fitAsk();
}
paintAgents();
setInterval(paintAgents, 3000);
