'use strict';

/* global renderAll */
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
