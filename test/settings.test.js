'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

const HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'limitty-settings-'));
process.env.LIMITTY_HOME = path.join(HOME, '.limitty');
const settings = require('../src/settings');
const config = require('../src/agents/config');

test('settings: defaults, then each change is saved to agent.json', () => {
  const s = settings.read();
  assert.strictEqual(s.ceo, 'claude');
  assert.strictEqual(s.allowCommands, true);
  assert.strictEqual(s.strengths.codex, '');
  assert.match(s.defaultStrengths.codex, /implementation/);

  settings.write({ ceo: 'codex', allowCommands: false, strengths: { agy: '  UI and CSS ' } });
  const c = config.load();
  assert.strictEqual(c.ceo, 'codex');
  assert.strictEqual(c.workers.allowCommands, false);
  assert.deepStrictEqual(c.workers.strengths, { agy: 'UI and CSS' });

  // Empty or default text goes back to the default.
  settings.write({ strengths: { agy: '' } });
  assert.deepStrictEqual(config.load().workers.strengths, {});
  // Bad values are ignored.
  settings.write({ ceo: 'hacker', refreshMinutes: 'x' });
  assert.strictEqual(config.load().ceo, 'codex');
});

test('settings: Antigravity models are cleaned and detected', () => {
  settings.write({ agyModels: { pro: 'gemini-3-pro; rm -rf /', flash: '' } });
  assert.deepStrictEqual(config.load().workers.agyModels, { pro: 'gemini-3-prorm-rf/' });
  settings.write({ agyModels: { pro: '', flash: '' } });
  assert.strictEqual(config.load().workers.agyModels, undefined);
  assert.deepStrictEqual(settings.pickAgyModels('Models:\n* gemini-3-pro (default)\n  gemini-3-flash\n  gemini-3-flash-lite\n  gemini-2.5-pro'),
    { pro: 'gemini-3-pro', flash: 'gemini-3-flash' });
  assert.deepStrictEqual(settings.pickAgyModels('nothing here'), { pro: '', flash: '' });
});
