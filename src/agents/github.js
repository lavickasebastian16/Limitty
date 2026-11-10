'use strict';

// "Sign in with GitHub" linking: the PC and the iPhone both sign in to your
// GitHub account (OAuth device flow: you type a short code on github.com) and
// meet in a private Gist named "Limitty agent status".
//
// The OAuth app's Client ID is public (device flow needs no secret). Register
// your own once (see ios/README.md → "Sign in with GitHub") and save it with
// `node scripts/set-github-client-id.js <id>` (limitty.json), or set LIMITTY_GITHUB_CLIENT_ID.

const CLIENT_ID = process.env.LIMITTY_GITHUB_CLIENT_ID || (() => {
  try { return require('../../limitty.json').githubClientId || ''; } catch { return ''; }
})();
const STATUS_FILE = 'limitty-status.json';
const GIST_DESCRIPTION = 'Limitty agent status (private; written by your PC, read by your iPhone)';
const API = 'https://api.github.com';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

class GitHubError extends Error {}

function requireClientId(clientId = CLIENT_ID) {
  if (!clientId) {
    throw new GitHubError('GitHub sign-in isn\'t configured yet: set the Limitty OAuth app\'s Client ID '
      + '(see ios/README.md → "Sign in with GitHub") with: node scripts/set-github-client-id.js <id>');
  }
  return clientId;
}

/**
 * Device flow. Calls onCode({ userCode, verificationUri }) so the caller can show the
 * code; resolves with the access token once you've approved it on github.com.
 */
async function deviceLogin({ onCode, fetchImpl = fetch, clientId = CLIENT_ID, wait = sleep }) {
  const id = requireClientId(clientId);
  const form = (o) => ({ method: 'POST', headers: { Accept: 'application/json', 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams(o).toString() });

  const codeRes = await fetchImpl('https://github.com/login/device/code', form({ client_id: id, scope: 'gist' }));
  const code = await codeRes.json();
  if (!codeRes.ok || !code.device_code) {
    throw new GitHubError(code.error === 'device_flow_disabled'
      ? 'Device Flow is off for the Limitty OAuth app: tick "Enable Device Flow" in its GitHub settings.'
      : `GitHub sign-in failed: ${code.error_description || code.error || codeRes.status}`);
  }
  await onCode({ userCode: code.user_code, verificationUri: code.verification_uri });

  let interval = (code.interval || 5) * 1000;
  const deadline = Date.now() + (code.expires_in || 900) * 1000;
  while (Date.now() < deadline) {
    await wait(interval);
    const res = await fetchImpl('https://github.com/login/oauth/access_token', form({
      client_id: id, device_code: code.device_code, grant_type: 'urn:ietf:params:oauth:grant-type:device_code',
    }));
    const body = await res.json();
    if (body.access_token) return body.access_token;
    if (body.error === 'authorization_pending') continue;
    if (body.error === 'slow_down') { interval += 5000; continue; }
    if (body.error === 'access_denied') throw new GitHubError('Sign-in was cancelled on GitHub.');
    if (body.error === 'expired_token') break;
    throw new GitHubError(`GitHub sign-in failed: ${body.error_description || body.error}`);
  }
  throw new GitHubError('The sign-in code expired. Try again.');
}

function api(token, fetchImpl = fetch) {
  return async (method, path, body) => {
    const res = await fetchImpl(`${API}${path}`, {
      method,
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'Limitty',
        ...(body ? { 'Content-Type': 'application/json' } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });
    if (res.status === 401) throw new GitHubError('GitHub sign-in expired or was revoked. Connect again.');
    if (!res.ok) throw new GitHubError(`GitHub returned HTTP ${res.status}`);
    return res.status === 204 ? null : res.json();
  };
}

async function whoami(token, fetchImpl) {
  return (await api(token, fetchImpl)('GET', '/user')).login;
}

/** Finds the status Gist (by its file name), creating it if needed. */
async function findOrCreateGist(token, fetchImpl) {
  const call = api(token, fetchImpl);
  for (let page = 1; page <= 10; page++) {
    const gists = await call('GET', `/gists?per_page=100&page=${page}`);
    const found = gists.find((g) => g.files && g.files[STATUS_FILE]);
    if (found) return found.id;
    if (gists.length < 100) break;
  }
  const created = await call('POST', '/gists', {
    description: GIST_DESCRIPTION,
    public: false,
    files: { [STATUS_FILE]: { content: JSON.stringify({ v: 1, sessions: [] }) } },
  });
  return created.id;
}

async function writeStatus(token, gistId, status, fetchImpl) {
  await api(token, fetchImpl)('PATCH', `/gists/${gistId}`, {
    files: { [STATUS_FILE]: { content: JSON.stringify(status) } },
  });
}

module.exports = { CLIENT_ID, STATUS_FILE, deviceLogin, whoami, findOrCreateGist, writeStatus, GitHubError };
