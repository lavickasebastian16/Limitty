'use strict';

const providers = [require('./claude'), require('./codex'), require('./antigravity')];

/** Fetch all providers in parallel; never throws. */
async function fetchAll(enabled) {
  const list = enabled ? providers.filter((p) => enabled.includes(p.id)) : providers;
  return Promise.all(list.map(async (p) => {
    const base = { id: p.id, name: p.name, fetchedAt: Date.now() };
    try {
      const data = await p.fetch();
      return { ...base, ok: true, ...data };
    } catch (e) {
      return { ...base, ok: false, error: e.message || String(e), hint: e.hint };
    }
  }));
}

module.exports = { providers, fetchAll };
