'use strict';
// Sets the Limitty version everywhere:   node scripts/set-version.js X.XX.XXX
//   X   = main version
//   XX  = big upgrade
//   XXX = minor update
// npm and Electron need plain semver, so 1.02.007 is stored there as 1.2.7. The
// iPhone build number is X*100000 + XX*1000 + XXX (always increasing).
const fs = require('fs');
const path = require('path');

const v = (process.argv[2] || '').trim();
const m = /^(\d)\.(\d{2})\.(\d{3})$/.exec(v);
if (!m) {
  console.error('Usage: node scripts/set-version.js X.XX.XXX   (e.g. 1.00.000, 1.01.000, 1.01.004)');
  process.exit(1);
}
const [major, big, minor] = m.slice(1).map(Number);
const semver = `${major}.${big}.${minor}`;
const build = String(major * 100000 + big * 1000 + minor);
const root = path.join(__dirname, '..');
const rel = (p) => path.join(root, p);

const meta = JSON.parse(fs.readFileSync(rel('limitty.json'), 'utf8'));
meta.version = v;
fs.writeFileSync(rel('limitty.json'), `${JSON.stringify(meta, null, 2)}\n`);

for (const f of ['package.json']) {
  const pkg = JSON.parse(fs.readFileSync(rel(f), 'utf8'));
  pkg.version = semver;
  fs.writeFileSync(rel(f), `${JSON.stringify(pkg, null, 2)}\n`);
}
const lock = rel('package-lock.json');
if (fs.existsSync(lock)) {
  const l = JSON.parse(fs.readFileSync(lock, 'utf8'));
  l.version = semver;
  if (l.packages?.['']) l.packages[''].version = semver;
  fs.writeFileSync(lock, `${JSON.stringify(l, null, 2)}\n`);
}

fs.writeFileSync(rel('ios/Sources/LimittyCore/Version.swift'),
  `// Set with: node scripts/set-version.js X.XX.XXX\npublic let limittyVersion = "${v}"\n`);

for (const plist of ['ios/Limitty-Info.plist', 'ios/LimittyWidget-Info.plist']) {
  let s = fs.readFileSync(rel(plist), 'utf8');
  for (const [key, val] of [['CFBundleShortVersionString', v], ['CFBundleVersion', build]]) {
    const re = new RegExp(`(<key>${key}</key>\\s*<string>)[^<]*(</string>)`);
    s = re.test(s) ? s.replace(re, `$1${val}$2`) : s.replace('<dict>', `<dict>\n\t<key>${key}</key>\n\t<string>${val}</string>`);
  }
  fs.writeFileSync(rel(plist), s);
}
console.log(`Limitty ${v} (npm ${semver}, iOS build ${build})`);
