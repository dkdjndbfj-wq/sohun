import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import { createCommunityServer } from '../src/server.js';

const receipt = '8bccb30f-5da8-48d0-988f-ab01e23b0b01';
const secondReceipt = '8bccb30f-5da8-48d0-988f-ab01e23b0b02';
const path = '/v1/me/inventory/snapshot';
function stock(overrides = {}) {
  return { uid: 'received-spool-one', manufacturer: 'eSUN', model: 'PLA', materialType: 'PLA',
    colorHex: '#112233', totalGrams: 1000, remainingGrams: 1000,
    createdAt: '2026-09-08T00:00:00.000Z', updatedAt: '2026-09-08T00:00:00.000Z',
    sourceRfidTagUid: 'D021B75E', sourceRfidTagType: 'CUID', stockReceiptUid: receipt,
    stockReceiptIndex: 0, stockReceiptQuantity: 2, ...overrides };
}
async function request(app, route, { method = 'GET', body, token = app.token } = {}) {
  const response = await fetch(`${app.baseUrl}${route}`, { method,
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(body ? { 'Content-Type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined });
  return { status: response.status, json: await response.json() };
}
async function register(app, email = 'stock@example.com') {
  const response = await request(app, '/v1/auth/register', { method: 'POST', token: null,
    body: { email, handle: email.split('@')[0], displayName: 'Stock test', password: 'StockTest!123',
      acceptTerms: true, termsVersion: '2026-07-29', privacyVersion: '2026-07-29' } });
  assert.equal(response.status, 201, JSON.stringify(response.json));
  return { ...app, token: response.json.accessToken, userId: response.json.user.id };
}
async function start(t) {
  const directory = mkdtempSync(join(tmpdir(), 'sohun-stock-receipts-'));
  const databasePath = join(directory, 'community.sqlite');
  const server = createCommunityServer({ databasePath, passwordPepper: 'stock-receipt-test' });
  await server.operationalReady;
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => {
    await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
    rmSync(directory, { recursive: true, force: true });
  });
  return register({ baseUrl: `http://127.0.0.1:${server.address().port}`, databasePath });
}
const put = (app, records, revision = 0, extra = {}) =>
  request(app, path, { method: 'PUT', body: { revision, records, ...extra } });
function receiptCount(app) {
  const db = new DatabaseSync(app.databasePath);
  try { return db.prepare('SELECT COUNT(*) n FROM personal_stock_receipt_items WHERE user_id = ?').get(app.userId).n; }
  finally { db.close(); }
}

test('one CUID card receives multiple independent spools and repeated batches', async (t) => {
  const app = await start(t);
  const first = await put(app, [stock(), stock({ uid: 'received-spool-two', stockReceiptIndex: 1 })]);
  assert.equal(first.status, 200, JSON.stringify(first.json));
  assert.equal(first.json.records.length, 2);
  assert.ok(first.json.records.every((r) => r.rfidTagUid == null && r.sourceRfidTagUid === 'D021B75E'));
  const updated = first.json.records.map((r, index) => ({ ...r, remainingGrams: index ? 1000 : 750 }));
  const second = await put(app, [...updated, stock({ uid: 'next-batch', totalGrams: 1000, remainingGrams: 500,
    stockReceiptUid: secondReceipt, stockReceiptQuantity: 1 })], 1);
  assert.equal(second.status, 200, JSON.stringify(second.json));
  assert.equal(second.json.records.find((r) => r.uid === 'received-spool-one').remainingGrams, 750);
  assert.equal(receiptCount(app), 3);
});

test('duplicate receipt slot cannot manufacture a different spool and rolls back transaction', async (t) => {
  const app = await start(t);
  const response = await put(app, [stock(), stock({ uid: 'duplicate' })]);
  assert.equal(response.status, 409, JSON.stringify(response.json));
  assert.equal(receiptCount(app), 0);
  assert.equal((await request(app, path)).json.revision, 0);
});

test('same confirmed receipt round-trips without duplicate receipt rows', async (t) => {
  const app = await start(t);
  const first = await put(app, [stock()]);
  const again = await put(app, first.json.records, 1);
  assert.equal(again.status, 200, JSON.stringify(again.json));
  assert.equal(receiptCount(app), 1);
});

for (const changed of [
  { sourceRfidTagUid: '04AABBCC' }, { sourceRfidTagType: 'FUID' },
  { stockReceiptUid: secondReceipt }, { stockReceiptIndex: 1 }, { stockReceiptQuantity: 3 },
]) {
  test(`receipt provenance remains immutable: ${Object.keys(changed)[0]}`, async (t) => {
    const app = await start(t);
    const first = await put(app, [stock()]);
    const response = await put(app, [{ ...first.json.records[0], ...changed, remainingGrams: 123 }], 1);
    assert.equal(response.status, 409, JSON.stringify(response.json));
    assert.deepEqual((await request(app, path)).json.records, first.json.records);
  });
}

test('older clients cannot clear source-card provenance by omitting new fields', async (t) => {
  const app = await start(t);
  const first = await put(app, [stock()]);
  const legacy = { ...first.json.records[0], remainingGrams: 123 };
  for (const key of Object.keys(legacy)) {
    if (key.startsWith('sourceRfid') || key.startsWith('stockReceipt')) delete legacy[key];
  }
  const updated = await put(app, [legacy], 1);
  assert.equal(updated.status, 200, JSON.stringify(updated.json));
  assert.equal(updated.json.records[0].sourceRfidTagUid, 'D021B75E');
  assert.equal(updated.json.records[0].stockReceiptUid, receipt);
  assert.equal(updated.json.records[0].remainingGrams, 123);
});

test('receipt survives deleting all batch stock and rejects old receipt resurrection', async (t) => {
  const app = await start(t);
  const first = await put(app, [stock()]);
  const deleted = await put(app, [], 1, { deletedUids: { 'received-spool-one': '2026-09-08T01:00:00.000Z' } });
  assert.equal(deleted.status, 200, JSON.stringify(deleted.json));
  assert.equal(receiptCount(app), 1);
  for (const candidate of [stock(), stock({ uid: 'another-spool-same-confirmation' })]) {
    const replay = await put(app, [candidate], 2);
    assert.equal(replay.status, 409, JSON.stringify(replay.json));
  }
  assert.deepEqual((await request(app, path)).json.records, []);
  assert.equal((await put(app, [stock({ uid: 'new-confirmation', stockReceiptUid: secondReceipt })], 2)).status, 200);
});

test('source metadata never creates an active-tag uniqueness conflict', async (t) => {
  const app = await start(t);
  const first = await put(app, [stock(), stock({ uid: 'two', stockReceiptIndex: 1 })]);
  const attached = first.json.records.map((r, index) => index ? r : {
    ...r, rfidTagUid: 'D021B75E', rfidTagType: 'CUID', rfidTagCycle: 1, lifecycleStatus: 'active' });
  const selected = await put(app, attached, 1);
  assert.equal(selected.status, 200, JSON.stringify(selected.json));
  const switched = selected.json.records.map((r, index) => index ? {
    ...r, rfidTagUid: 'D021B75E', rfidTagType: 'CUID', rfidTagCycle: 2,
    previousConsumableUid: 'received-spool-one', lifecycleStatus: 'active' } : { ...r, lifecycleStatus: 'replaced' });
  const next = await put(app, switched, 2);
  assert.equal(next.status, 200, JSON.stringify(next.json));
  assert.equal(next.json.records.length, 2);
});

for (const invalid of [
  { sourceRfidTagType: 'NTAG213' }, { sourceRfidTagType: 'NTAG213 CUID' }, { sourceRfidTagType: 'AMS' },
  { sourceRfidTagUid: '04AABBCCDDEEFF' }, { stockReceiptQuantity: 101 },
  { stockReceiptIndex: 2 }, { stockReceiptUid: null }, { remainingGrams: 2001 },
]) {
  test(`invalid source or single-spool data is rejected: ${JSON.stringify(invalid)}`, async (t) => {
    const app = await start(t);
    const response = await put(app, [stock(invalid)]);
    assert.equal(response.status, 400, JSON.stringify(response.json));
    assert.equal(receiptCount(app), 0);
  });
}

test('stock receipts are isolated by account even when operation IDs are identical', async (t) => {
  const app = await start(t);
  const other = await register(app, 'other-stock@example.com');
  assert.equal((await put(app, [stock()])).status, 200);
  assert.equal((await put(other, [stock({ uid: 'other-user-stock' })])).status, 200);
  assert.equal((await request(app, path)).json.records[0].uid, 'received-spool-one');
  assert.equal((await request(other, path)).json.records[0].uid, 'other-user-stock');
  assert.equal(receiptCount(app), 1);
  assert.equal(receiptCount(other), 1);
});
