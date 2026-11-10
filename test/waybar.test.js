'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { build } = require('../src/waybar');

test('waybar: limits, agents needing you, and tasks', () => {
  const out = build(
    [
      { id: 'claude', name: 'Claude', ok: true, plan: 'Max', windows: [{ label: 'Session', usedPercent: 42 }, { label: 'Weekly', usedPercent: 67 }] },
      { id: 'codex', name: 'Codex', ok: true, windows: [{ label: '5h window', usedPercent: 91 }] },
      { id: 'antigravity', name: 'Antigravity', ok: false, error: 'Antigravity not running' },
    ],
    { sessions: { a: { agent: 'claude', project: 'site', state: 'attention', detail: 'Needs permission' }, b: { agent: 'codex', project: 'api', state: 'working', detail: 'Working' } } },
    { tasks: [{ status: 'running' }, { status: 'done' }] },
  );
  assert.strictEqual(out.text, '! 1  ● 1  ▸ 1  C 67% · X 91%');
  assert.strictEqual(out.class, 'attention');
  assert.strictEqual(out.percentage, 91);
  assert.match(out.tooltip, /Antigravity: Antigravity not running/);
  assert.match(out.tooltip, /1 Company task in progress/);
});

test('waybar: quiet state is "normal"/"warning" by the fullest limit', () => {
  assert.strictEqual(build([{ id: 'claude', name: 'Claude', ok: true, windows: [{ label: 'S', usedPercent: 10 }] }], null, null).class, 'normal');
  assert.strictEqual(build([{ id: 'claude', name: 'Claude', ok: true, windows: [{ label: 'S', usedPercent: 70 }] }], null, null).class, 'warning');
  assert.strictEqual(build([], null, null).text, 'Limitty');
});
