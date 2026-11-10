'use strict';

// AES-256-GCM, laid out as nonce(12) | ciphertext | tag(16) and base64-encoded:
// the same layout as CryptoKit's AES.GCM.SealedBox(combined:) on the iPhone.

const crypto = require('crypto');

function keyBytes(key) {
  const b = Buffer.from(key.replace(/-/g, '+').replace(/_/g, '/'), 'base64');
  if (b.length !== 32) throw new Error('Key must be 32 bytes');
  return b;
}

function seal(obj, key, nonce = crypto.randomBytes(12)) {
  const cipher = crypto.createCipheriv('aes-256-gcm', keyBytes(key), nonce);
  const ct = Buffer.concat([cipher.update(JSON.stringify(obj), 'utf8'), cipher.final()]);
  return Buffer.concat([nonce, ct, cipher.getAuthTag()]).toString('base64');
}

function open(b64, key) {
  const buf = Buffer.from(b64, 'base64');
  const decipher = crypto.createDecipheriv('aes-256-gcm', keyBytes(key), buf.subarray(0, 12));
  decipher.setAuthTag(buf.subarray(buf.length - 16));
  const pt = Buffer.concat([decipher.update(buf.subarray(12, buf.length - 16)), decipher.final()]);
  return JSON.parse(pt.toString('utf8'));
}

module.exports = { seal, open };
