'use strict';

const test = require('node:test');
const assert = require('node:assert');
const notify = require('../src/agents/notify');

const phone = (n) => ({ notify: { bark: { server: 'https://api.day.app/', key: 'AbCdEf123456' }, ...n } });

test('normalize: needs a valid Bark key and https server; fills default sounds', () => {
  assert.strictEqual(notify.normalize(null), null);
  assert.strictEqual(notify.normalize({ notify: { bark: { key: 'bad key!' } } }), null);
  assert.strictEqual(notify.normalize({ notify: { bark: { key: 'AbCdEf123456', server: 'http://x' } } }), null);
  const s = notify.normalize(phone({ sounds: { attention: 'nope', done: 'bell' } }));
  assert.strictEqual(s.server, 'https://api.day.app');
  assert.deepStrictEqual(s.sounds, { attention: 'alarm', done: 'bell' });
  assert.strictEqual(s.finished, true);
});

test('payload: different sound and level for "needs you" and "done"', () => {
  const s = notify.normalize(phone({ sounds: { attention: 'alarm', done: 'glass' } }));
  const a = notify.payload(s, 'attention', { title: 'Claude Code needs you', body: 'Bash: npm test' });
  assert.deepStrictEqual([a.sound, a.level, a.device_key, a.url], ['alarm', 'timeSensitive', 'AbCdEf123456', 'limitty://agents']);
  const d = notify.payload(s, 'finished', { title: 'Codex finished' });
  assert.deepStrictEqual([d.sound, d.level], ['glass', 'active']);
  assert.strictEqual(notify.payload(s, 'task-failed', { title: 'x' }).sound, 'alarm');
  assert.strictEqual(notify.payload(s, 'task-done', { title: 'x', url: 'limitty://tasks' }).url, 'limitty://tasks');
});

test('wants: respects the phone switches', () => {
  const s = notify.normalize(phone({ finished: false, tasks: false }));
  assert.strictEqual(notify.wants(s, 'attention'), true);
  assert.strictEqual(notify.wants(s, 'finished'), false);
  assert.strictEqual(notify.wants(s, 'task-done'), false);
  assert.strictEqual(notify.wants(notify.normalize(phone({ enabled: false })), 'attention'), false);
});

test('sendBark posts JSON to /push', async () => {
  const calls = [];
  const s = notify.normalize(phone({}));
  await notify.sendBark(s, 'attention', { title: 't', body: 'b' }, async (url, init) => { calls.push([url, JSON.parse(init.body)]); return { ok: true }; });
  assert.strictEqual(calls[0][0], 'https://api.day.app/push');
  assert.strictEqual(calls[0][1].sound, 'alarm');
  await assert.rejects(notify.sendBark(s, 'finished', { title: 't' }, async () => ({ ok: false, status: 400 })), /HTTP 400/);
});
