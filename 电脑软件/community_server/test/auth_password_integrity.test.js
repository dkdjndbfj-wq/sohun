import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import { createCommunityServer } from '../src/server.js';

test('损坏或异常成本的密码摘要返回 401，不使登录接口崩溃', async (t) => {
  const directory = mkdtempSync(join(tmpdir(), 'sohun-auth-integrity-'));
  const databasePath = join(directory, 'test.sqlite');
  const server = createCommunityServer({ databasePath, passwordPepper: 'test-pepper' });
  await server.operationalReady;
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const db = new DatabaseSync(databasePath);
  t.after(async () => {
    db.close();
    await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
    rmSync(directory, { recursive: true, force: true });
  });
  const baseUrl = `http://127.0.0.1:${server.address().port}`;
  const post = (path, body) => fetch(`${baseUrl}${path}`, {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body),
  });
  const email = 'hash-integrity@example.com';
  const password = 'StrongPass123';
  const registered = await post('/v1/auth/register', {
    email, password, handle: 'hash-integrity', displayName: 'Hash Test',
    acceptTerms: true, termsVersion: '2026-07-29', privacyVersion: '2026-07-29',
  });
  assert.equal(registered.status, 201);
  const original = db.prepare('SELECT password_hash FROM users WHERE email = ?').get(email).password_hash;
  const parts = original.split('$');
  for (const encoded of [
    'not-a-password-hash',
    ['scrypt', 'not-a-number', ...parts.slice(2)].join('$'),
    ['scrypt', '16385', ...parts.slice(2)].join('$'),
    ['scrypt', '1073741824', ...parts.slice(2)].join('$'),
    ['scrypt', ...parts.slice(1, 5), 'bad!base64'].join('$'),
  ]) {
    db.prepare('UPDATE users SET password_hash = ? WHERE email = ?').run(encoded, email);
    const login = await post('/v1/auth/login', { email, password });
    assert.equal(login.status, 401);
    assert.equal((await login.json()).error.code, 'invalid_credentials');
  }
  db.prepare('UPDATE users SET password_hash = ? WHERE email = ?').run(original, email);
  assert.equal((await post('/v1/auth/login', { email, password })).status, 200);
});
