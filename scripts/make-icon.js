'use strict';
// Generates the icons with no dependencies:
//   assets/tray.png           32x32 desktop tray icon (transparent)
//   ios/Resources/AppIcon.png 1024x1024 iPhone app icon (opaque, iOS rounds the corners)
const zlib = require('zlib');
const fs = require('fs');
const path = require('path');

const BARS = [ // [x, top, width] on a 32-unit grid, coloured Claude / Codex / Antigravity
  [6, 10, 5, [217, 119, 87]],
  [14, 18, 5, [154, 154, 166]],
  [22, 6, 5, [79, 140, 255]],
];

function png(size, background) {
  const px = Buffer.alloc(size * size * 4);
  const s = size / 32;
  for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) {
    const i = (y * size + x) * 4;
    let c = background;
    for (const [bx, top, w, rgb] of BARS) {
      if (x >= bx * s && x < (bx + w) * s && y >= top * s && y < 28 * s) c = [...rgb, 255];
    }
    if (c) { px[i] = c[0]; px[i + 1] = c[1]; px[i + 2] = c[2]; px[i + 3] = c[3] ?? 255; }
  }
  const raw = Buffer.alloc(size * (size * 4 + 1));
  for (let y = 0; y < size; y++) px.copy(raw, y * (size * 4 + 1) + 1, y * size * 4, (y + 1) * size * 4);

  const table = Array.from({ length: 256 }, (_, n) => {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    return c >>> 0;
  });
  const crc = (b) => { let c = 0xffffffff; for (const v of b) c = table[(c ^ v) & 0xff] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
  const chunk = (type, data) => {
    const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
    const td = Buffer.concat([Buffer.from(type), data]);
    const c = Buffer.alloc(4); c.writeUInt32BE(crc(td));
    return Buffer.concat([len, td, c]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0); ihdr.writeUInt32BE(size, 4); ihdr[8] = 8; ihdr[9] = 6;
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0)),
  ]);
}

const root = path.join(__dirname, '..');
fs.writeFileSync(path.join(root, 'assets', 'tray.png'), png(32, null));
fs.mkdirSync(path.join(root, 'ios', 'Resources'), { recursive: true });
fs.writeFileSync(path.join(root, 'ios', 'Resources', 'AppIcon.png'), png(1024, [22, 22, 25, 255]));
console.log('wrote assets/tray.png and ios/Resources/AppIcon.png');
