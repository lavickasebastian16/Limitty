'use strict';

/* global settings */
const $ = (id) => document.getElementById(id);
const NAMES = { claude: 'Claude Code', codex: 'Codex', agy: 'Antigravity' };
let s = null;
let savedTimer = null;

function flashSaved() {
  $('saved').hidden = false;
  clearTimeout(savedTimer);
  savedTimer = setTimeout(() => { $('saved').hidden = true; }, 1200);
}

async function save(patch) {
  s = await settings.set(patch);
  flashSaved();
  render(false);
}

function render(all = true) {
  $('agentsSummary').textContent = s.agents.map((a) => `${a.name}: ${!a.chosen ? 'off' : !a.installed ? 'not installed' : a.signedIn === false ? 'not signed in' : 'ready'}`).join(' · ');
  $('phoneStatus').textContent = s.github ? `Linked as @${s.github.login || 'you'}. Tasks and alerts go to your iPhone.` : 'Not linked. Link it to send tasks from your phone and get alerts there.';
  $('phoneButton').textContent = s.github ? 'Unlink' : 'Link iPhone…';
  $('phoneButton').className = s.github ? 'ghost small' : 'small';
  $('version').textContent = `Limitty ${s.version}`;
  if (!all) return;
  $('ceo').value = s.ceo;
  $('strengths').innerHTML = Object.keys(NAMES).map((id) => `
    <div class="strength">
      <div class="who"><span class="dot ${id}"></span>${NAMES[id]}</div>
      <textarea data-id="${id}" rows="2"></textarea>
    </div>`).join('');
  for (const ta of document.querySelectorAll('.strength textarea')) {
    ta.value = s.strengths[ta.dataset.id];
    ta.placeholder = s.defaultStrengths[ta.dataset.id];
    ta.addEventListener('change', () => save({ strengths: { [ta.dataset.id]: ta.value } }));
  }
  $('allowCommands').checked = s.allowCommands;
  $('agyPro').value = s.agyModels.pro;
  $('agyFlash').value = s.agyModels.flash;
  $('refreshMinutes').value = String(s.refreshMinutes);
  $('alwaysOnTop').checked = s.alwaysOnTop;
  $('startAtLogin').checked = s.startAtLogin;
}

$('ceo').addEventListener('change', (e) => save({ ceo: e.target.value }));
for (const id of ['allowCommands', 'alwaysOnTop', 'startAtLogin']) {
  $(id).addEventListener('change', (e) => save({ [id]: e.target.checked }));
}
$('refreshMinutes').addEventListener('change', (e) => save({ refreshMinutes: Number(e.target.value) }));
for (const id of ['agyPro', 'agyFlash']) {
  $(id).addEventListener('change', () => save({ agyModels: { pro: $('agyPro').value, flash: $('agyFlash').value } }));
}
$('detectAgy').addEventListener('click', async () => {
  $('detectAgy').disabled = true;
  $('agyNote').textContent = 'Asking agy for its models…';
  const r = await settings.detectAgy();
  $('detectAgy').disabled = false;
  if (!r.ok) { $('agyNote').textContent = r.error; return; }
  if (r.pro) $('agyPro').value = r.pro;
  if (r.flash) $('agyFlash').value = r.flash;
  $('agyNote').textContent = r.pro || r.flash ? 'Found them. Check they look right; they are saved.' : 'Couldn’t find Gemini model names in `agy models`. Type them in.';
  if (r.pro || r.flash) save({ agyModels: { pro: $('agyPro').value, flash: $('agyFlash').value } });
});
$('openAgents').addEventListener('click', () => settings.openAgents());
$('phoneButton').addEventListener('click', async () => {
  $('phoneButton').disabled = true;
  s = s.github ? await settings.unlinkPhone() : await settings.linkPhone();
  $('phoneButton').disabled = false;
  render(false);
});

settings.get().then((x) => { s = x; render(); });
