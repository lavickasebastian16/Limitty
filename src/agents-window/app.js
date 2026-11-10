'use strict';

/* global agents */
const $ = (id) => document.getElementById(id);
let state = { agents: [], busy: false };

const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

function pill(a) {
  if (a.job === 'installing') return '<span class="pill busy"><span class="spin"></span>Installing…</span>';
  if (a.job === 'queued') return '<span class="pill busy">Waiting to install</span>';
  if (a.job === 'signin') return '<span class="pill busy"><span class="spin"></span>Waiting for sign-in</span>';
  if (!a.installed) return '<span class="pill no">Not installed</span>';
  const v = a.version ? ` · ${esc(a.version)}` : '';
  if (a.signedIn === true) return `<span class="pill ok">Signed in${v}</span>`;
  if (a.signedIn === false) return `<span class="pill mid">Installed${v} · not signed in</span>`;
  return `<span class="pill ok">Installed${v}</span>`;
}

function side(a) {
  if (a.job === 'signin') return `<button class="small ghost" data-skip="${a.id}">Skip</button>`;
  if (a.job || !a.chosen) return '';
  if (!a.installed) {
    return a.canInstall ? `<button class="small ghost" data-install="${a.id}" ${state.busy ? 'disabled' : ''}>Install</button>` : '';
  }
  // signedIn null = can't tell (Antigravity): offer it quietly.
  const label = a.signedIn === false ? 'Sign in' : 'Sign in again';
  return `<button class="small ${a.signedIn === false ? '' : 'ghost'}" data-login="${a.id}" ${state.busy ? 'disabled' : ''}>${label}</button>`;
}

const ICONS = { todo: '○', running: '<span class="spin"></span>', done: '✓', failed: '✕', skipped: '!' };

function renderSteps() {
  const s = state.setup;
  $('steps').hidden = !s;
  $('code').hidden = !s?.code;
  if (s?.code) $('userCode').textContent = s.code.userCode;
  if (!s) return;
  $('steps').innerHTML = s.steps.map((st) => `
    <li class="${st.state}">
      <span class="ico">${ICONS[st.state] || ''}</span>
      <span class="lbl">${esc(st.label)}</span>
      ${st.note ? `<span class="nt">${esc(st.note)}</span>` : ''}
    </li>`).join('');
}

function render() {
  $('list').innerHTML = state.agents.map((a) => `
    <div class="agent ${a.chosen ? '' : 'off'}">
      <input type="checkbox" data-pick="${a.id}" ${a.chosen ? 'checked' : ''} ${state.busy ? 'disabled' : ''} aria-label="Use ${esc(a.name)}">
      <div class="name"><span class="dot ${a.id}"></span>${esc(a.name)} ${pill(a)}</div>
      <div class="side">${side(a)}</div>
      <div class="about">${esc(a.about)}</div>
      ${a.error ? `<div class="err">${esc(a.error)}</div>` : ''}
      ${a.note ? `<div class="hint">${esc(a.note)}${a.url ? ' <a href="#" data-reopen="' + a.id + '">Open the page again</a>' : ''}</div>` : ''}
      ${a.job === 'signin' && a.codeBox ? `<form class="code-row" data-code="${a.id}"><input placeholder="Paste the code from the page (if it shows one)" autocomplete="off"><button class="small">Continue</button></form>` : ''}
    </div>`).join('');

  const picked = state.agents.filter((a) => a.chosen);
  const ready = picked.length && picked.every((a) => a.installed && a.signedIn !== false) && state.phoneLinked;
  const btn = $('install');
  btn.disabled = state.busy || !picked.length;
  btn.innerHTML = state.busy ? '<span class="spin"></span>Setting up…' : ready ? 'Run setup again' : 'Install agents';
  btn.classList.toggle('ghost', !!ready && !state.busy);
  $('summary').innerHTML = state.busy ? 'Follow along below. You only need to sign in when asked.'
    : !picked.length ? 'Pick at least one agent.'
      : ready ? `<span class="allset">✓ All set</span>${state.githubLogin ? ` · iPhone linked as @${esc(state.githubLogin)}` : ''}`
        : '';
  renderSteps();
  $('version').textContent = state.version ? `Limitty ${state.version}` : '';
}

document.addEventListener('change', async (e) => {
  const id = e.target.dataset?.pick;
  if (!id) return;
  const ids = state.agents.filter((a) => (a.id === id ? e.target.checked : a.chosen)).map((a) => a.id);
  state = await agents.choose(ids);
  render();
});

document.addEventListener('submit', async (e) => {
  const f = e.target.closest('form[data-code]');
  if (!f) return;
  e.preventDefault();
  const input = f.querySelector('input');
  if (!input.value.trim()) return;
  f.querySelector('button').disabled = true;
  state = await agents.code(f.dataset.code, input.value);
  render();
});

document.addEventListener('click', async (e) => {
  const t = e.target.closest('button:not(.code-row button), a');
  if (!t) return;
  if (t.id === 'openGitHub') {
    e.preventDefault();
    if (state.setup?.code) agents.openExternal(state.setup.code.verificationUri);
  } else if (t.dataset.install) {
    $('logBox').hidden = false;
    agents.install(t.dataset.install).then((s) => { state = s; render(); });
  } else if (t.dataset.login) {
    state = await agents.login(t.dataset.login);
    render();
  } else if (t.dataset.reopen) {
    e.preventDefault();
    agents.reopen(t.dataset.reopen);
  } else if (t.dataset.skip) {
    state = await agents.skip(t.dataset.skip);
    render();
  }
});

$('install').addEventListener('click', () => {
  $('logBox').hidden = false;
  agents.setup().then((s) => { state = s; render(); });
});
$('done').addEventListener('click', () => agents.done());

agents.onUpdate((s) => {
  // Keep a code you're typing.
  const typing = document.activeElement?.closest('.code-row');
  const kept = typing && { id: typing.dataset.code, value: typing.querySelector('input').value };
  state = s;
  render();
  if (kept) {
    const input = document.querySelector(`.code-row[data-code="${kept.id}"] input`);
    if (input) { input.value = kept.value; input.focus(); }
  }
});
agents.onLog((line) => {
  const log = $('log');
  log.textContent = (log.textContent + line + '\n').split('\n').slice(-300).join('\n');
  log.scrollTop = log.scrollHeight;
});

agents.state().then((s) => { state = s; render(); });
// Keep install and sign-in status fresh.
setInterval(() => {
  if (state.busy || document.activeElement?.closest('.code-row')) return;
  agents.state().then((s) => { state = s; render(); });
}, 4000);
