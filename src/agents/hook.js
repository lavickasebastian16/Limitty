'use strict';

// The agent hook: Claude Code, Codex and Antigravity run this on every event,
// and it appends one line to ~/.limitty/events.jsonl for Limitty to read.
//
// It uses only Node's built-in modules, so Limitty copies it to ~/.limitty/hook.js
// and the agents run it from there. That path stays the same across app updates
// (and AppImages, whose files move every time they start).
//
//   <node or Limitty in node mode> ~/.limitty/hook.js <agent> [event] --limitty-hook [codex-json]

const fs = require('fs');
const os = require('os');
const path = require('path');

const DIR = process.env.LIMITTY_HOME || path.join(os.homedir(), '.limitty');
const EVENTS = path.join(DIR, 'events.jsonl');

function normalize(agent, event, p) {
  const t = Date.now();
  if (agent === 'claude') {
    return {
      t, agent, event: p.hook_event_name || event, session: p.session_id, cwd: p.cwd,
      detail: { tool: p.tool_name, type: p.notification_type, message: p.message },
    };
  }
  if (agent === 'agy') {
    return {
      t, agent, event, session: p.conversationId || p.conversation_id || p.sessionId, cwd: p.cwd || p.workspacePath || process.cwd(),
      detail: { tool: p.toolCall?.name || p.tool_name, fullyIdle: p.fullyIdle },
    };
  }
  if (agent === 'codex') {
    return { t, agent, event: p.type || event, session: p['thread-id'] || p.thread_id, cwd: p.cwd, detail: {} };
  }
  return null;
}

function readStdin(timeoutMs) {
  return new Promise((resolve) => {
    if (process.stdin.isTTY) return resolve('');
    let data = '';
    const done = () => resolve(data);
    const timer = setTimeout(done, timeoutMs);
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (c) => { data += c; });
    process.stdin.on('end', () => { clearTimeout(timer); done(); });
    process.stdin.on('error', () => { clearTimeout(timer); done(); });
  });
}

/** args: [agent, event?, '--limitty-hook', codexJson?] */
async function main(args) {
  try {
    const [agent, maybeEvent] = args;
    const event = maybeEvent && !maybeEvent.startsWith('--') ? maybeEvent : undefined;
    let payload = {};
    if (agent === 'codex') {
      // Codex passes one JSON argument (after our marker).
      const json = [...args].reverse().find((a) => a.startsWith('{'));
      payload = json ? JSON.parse(json) : {};
    } else {
      const text = await readStdin(1500);
      payload = text.trim() ? JSON.parse(text) : {};
    }
    const ev = normalize(agent, event, payload);
    if (!ev) return;
    fs.mkdirSync(DIR, { recursive: true });
    fs.appendFileSync(EVENTS, `${JSON.stringify(ev)}\n`);
  } catch {
    // Never break the agent because of Limitty.
  }
}

if (require.main === module) {
  main(process.argv.slice(2)).finally(() => process.exit(0));
}

module.exports = { main, normalize };
