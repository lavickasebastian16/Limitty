'use strict';
// Sets the Client ID of your "Limitty" GitHub OAuth app for both the PC companion
// and the iPhone app:   node scripts/set-github-client-id.js <client-id>
// Client IDs are public (device flow uses no secret), so committing it is fine.
const fs = require('fs');
const path = require('path');

const id = (process.argv[2] || '').trim();
if (!/^[A-Za-z0-9._-]{10,40}$/.test(id)) {
  console.error('Usage: node scripts/set-github-client-id.js <client-id>  (from github.com/settings/developers)');
  process.exit(1);
}
const root = path.join(__dirname, '..');
const metaFile = path.join(root, 'limitty.json');
const meta = JSON.parse(fs.readFileSync(metaFile, 'utf8'));
meta.githubClientId = id;
fs.writeFileSync(metaFile, `${JSON.stringify(meta, null, 2)}\n`);
const swift = path.join(root, 'ios', 'Sources', 'LimittyCore', 'GitHubClientID.swift');
fs.writeFileSync(swift, `// Set with: node scripts/set-github-client-id.js <client-id>\npublic let limittyGitHubClientID = "${id}"\n`);
console.log(`Saved. Commit limitty.json and ${path.relative(root, swift)}, then rebuild the iPhone app.`);
