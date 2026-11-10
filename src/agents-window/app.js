'use strict';

/* global agents */
const $ = (id) => document.getElementById(id);
let state = { agents: [], busy: false };

const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

function pill(a) {
  if (a.job === 'installing') return '<span class="pill busy"><span class="spin"></span>Installing…</span>';
  if (a.job === 'queued') return '<span class="pill busy">Waiting to install</span>';
  if (!a.installed) return '<span class="pill no">Not installed</span>';
  const v = a.version ? ` · ${esc(a.version)}` : '';
  if (a.signedIn === true) return `<span class="pill ok">Signed in${v}</span>`;
  if (a.signedIn === false) return `<span class="pill mid">Installed${v} · not signed in</span>`;
  return `<span class="pill ok">Installed${v}</span>`;
}

function side(a) {
  if (a.job) return '';
  if (!a.installed) {
    return a.canInstall ? `<button class="small" data-install="${a.id}" ${state.busy ? 'disabled' : ''}>Install</button>` : '';
  }
  const label = a.signedIn === true ? 'Sign in again' : 'Sign in';
  return `<button class="small ${a.signedIn === true ? 'ghost' : ''}" data-login="${a.id}" ${state.busy ? 'disabled' : ''}>${label}</button>`;
}

function render() {
  $('list').innerHTML = state.agents.map((a) => `
    <div class="agent ${a.chosen ? '' : 'off'}">
      <input type="checkbox" data-pick="${a.id}" ${a.chosen ? 'checked' : ''} ${state.busy ? 'disabled' : ''} aria-label="Use ${esc(a.name)}">
      <div class="name"><span class="dot ${a.id}"></span>${esc(a.name)} ${pill(a)}</div>
      <div class="side">${side(a)}</div>
      <div class="about">${esc(a.about)}</div>
      ${a.error ? `<div class="err">${esc(a.error)}</div>` : ''}
      ${a.loginCommand ? `<div class="hint">No terminal app found. Open one and run <code>${esc(a.loginCommand)}</code> to sign in.</div>` : ''}
      ${a.loginOpened ? `<div class="hint">A terminal window opened. ${esc(a.loginHint)} Then close it; Limitty notices on its own.</div>` : ''}
    </div>`).join('');

  const missing = state.agents.filter((a) => a.chosen && !a.installed && a.canInstall && !a.job);
  $('install').disabled = state.busy || !missing.length;
  $('install').textContent = missing.length ? `Install ${missing.map((a) => a.name).join(' and ')}` : 'Install selected';
  const picked = state.agents.filter((a) => a.chosen);
  $('summary').textContent = state.busy
    ? 'Installing… this can take a minute.'
    : !picked.length ? 'Pick at least one agent.'
      : missing.length ? '' : `Using ${picked.map((a) => a.name).join(', ')}.`;
  $('version').textContent = state.version ? `Limitty ${state.version}` : '';
}

document.addEventListener('change', async (e) => {
  const id = e.target.dataset?.pick;
  if (!id) return;
  const ids = state.agents.filter((a) => (a.id === id ? e.target.checked : a.chosen)).map((a) => a.id);
  state = await agents.choose(ids);
  render();
});

document.addEventListener('click', async (e) => {
  const t = e.target.closest('button');
  if (!t) return;
  if (t.dataset.install) {
    const ids = [...new Set([...state.agents.filter((a) => a.chosen).map((a) => a.id), t.dataset.install])];
    await agents.choose(ids);
    install([t.dataset.install]);
  } else if (t.dataset.login) {
    state = await agents.login(t.dataset.login);
    render();
  }
});

function install(ids) {
  $('logBox').hidden = false;
  agents.install(ids).then((s) => { state = s; render(); });
}

$('install').addEventListener('click', () => {
  install(state.agents.filter((a) => a.chosen && !a.installed && a.canInstall).map((a) => a.id));
});
$('done').addEventListener('click', () => agents.done());

agents.onUpdate((s) => { state = s; render(); });
agents.onLog((line) => {
  const log = $('log');
  log.textContent = (log.textContent + line + '\n').split('\n').slice(-300).join('\n');
  log.scrollTop = log.scrollHeight;
});

agents.state().then((s) => { state = s; render(); });
// Notice sign-ins finished in the terminal.
setInterval(() => { if (!state.busy) agents.state().then((s) => { state = s; render(); }); }, 4000);
