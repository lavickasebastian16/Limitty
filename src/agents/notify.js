'use strict';

// Push alerts through Bark (a free iPhone app), with a different sound for
// "needs you" and "done". You set it up in the iPhone app; it saves the Bark key
// and your sounds to limitty-phone.json in your private Gist, and the PC reads
// them from there. Without Bark, alerts go through ntfy like before.
//
// Bark API: POST {server}/push with JSON { device_key, title, body, sound, level, group, url }.

const PHONE_FILE = 'limitty-phone.json'; // written by the phone

// Bark's built-in sounds (github.com/Finb/Bark/tree/master/Sounds).
const SOUNDS = ['alarm', 'anticipate', 'bell', 'birdsong', 'bloom', 'calypso', 'chime', 'choo', 'descent',
  'electronic', 'fanfare', 'glass', 'gotosleep', 'healthnotification', 'horn', 'ladder', 'mailsent', 'minuet',
  'multiwayinvitation', 'newmail', 'newsflash', 'noir', 'paymentsuccess', 'shake', 'sherwoodforest', 'spell',
  'suspense', 'telegraph', 'tiptoes', 'typewriters', 'update'];
const DEFAULT_SOUNDS = { attention: 'alarm', done: 'glass' };

/** Cleans up the phone's settings; returns null if Bark isn't set up. */
function normalize(phone) {
  const n = phone?.notify;
  const bark = n?.bark;
  if (!bark || typeof bark.key !== 'string' || !/^[A-Za-z0-9_-]{8,64}$/.test(bark.key)) return null;
  const server = String(bark.server || 'https://api.day.app').replace(/\/+$/, '');
  if (!/^https:\/\/[^\s/]+(\/[^\s]*)?$/.test(server)) return null;
  const sound = (s, d) => (SOUNDS.includes(s) ? s : d);
  return {
    server,
    key: bark.key,
    sounds: { attention: sound(n.sounds?.attention, DEFAULT_SOUNDS.attention), done: sound(n.sounds?.done, DEFAULT_SOUNDS.done) },
    finished: n.finished !== false,
    tasks: n.tasks !== false,
    enabled: n.enabled !== false,
  };
}

/**
 * kind: 'attention' (needs permission or an answer), 'finished' (an agent is done),
 * 'task-done', 'task-failed'.
 */
function payload(settings, kind, { title, body, url }) {
  const urgent = kind === 'attention' || kind === 'task-failed';
  return {
    device_key: settings.key,
    title,
    body: body || ' ',
    sound: urgent ? settings.sounds.attention : settings.sounds.done,
    // Time-sensitive alerts get through Focus modes; "done" ones don't need to.
    level: urgent ? 'timeSensitive' : 'active',
    group: urgent ? 'Limitty · needs you' : 'Limitty · done',
    url: url || 'limitty://agents',
  };
}

/** Whether this kind of alert should go out with these settings. */
function wants(settings, kind) {
  if (!settings?.enabled) return false;
  if (kind === 'finished') return settings.finished;
  if (kind === 'task-done' || kind === 'task-failed') return settings.tasks;
  return true;
}

async function sendBark(settings, kind, msg, fetchImpl = globalThis.fetch) {
  const res = await fetchImpl(`${settings.server}/push`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json; charset=utf-8' },
    body: JSON.stringify(payload(settings, kind, msg)),
  });
  if (!res.ok) throw new Error(`Bark returned HTTP ${res.status}`);
  return true;
}

module.exports = { PHONE_FILE, SOUNDS, DEFAULT_SOUNDS, normalize, payload, wants, sendBark };
