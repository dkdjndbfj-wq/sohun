import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import { createCommunityServer } from '../src/server.js';

const receipt = '81bccc00-1212-4321-8123-123456789abc';
const route = '/v1/me/inventory/snapshot';
const sourceKeys = ['sourceRfidTagUid', 'sourceRfidTagType', 'stockReceiptUid',
  'stockReceiptIndex', 'stockReceiptQuantity'];
function stock(overrides = {}) {
  return { uid: 'manual-spool-1', manufacturer: 'eSUN', model: 'PLA', materialType: 'PLA',
    colorHex: '#112233', totalGrams: 1000, remainingGrams: 1000,
    createdAt: '2026-09-09T00:00:00.000Z', updatedAt: '2026-09-09T00:00:00.000Z',
    sourceRfidTagUid: null, sourceRfidTagType: null, stockReceiptUid: receipt,
    stockReceiptIndex: 0, stockReceiptQuantity: 2, ...overrides };
}
async function request(app, path, { body, method = body ? 'POST' : 'GET', token = app.token } = {}) {
  const response = await fetch(`${app.baseUrl}${path}`, { method,
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(body ? { 'Content-Type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined });
  return { status: response.status, json: await response.json() };
}
async function register(app, name = 'manual-stock') {
  const response = await request(app, '/v1/auth/register', { token: null,
    body: { email: `${name}@example.com`, handle: name, displayName: name,
      password: 'ManualStockTest!123', acceptTerms: true,
      termsVersion: '2026-07-29', privacyVersion: '2026-07-29' } });
  assert.equal(response.status, 201, JSON.stringify(response.json));
  return { ...app, token: response.json.accessToken, userId: response.json.user.id };
}
async function start(t) {
  const directory = mkdtempSync(join(tmpdir(), 'sohun-manual-receipts-'));
  const databasePath = join(directory, 'community.sqlite');
  const server = createCommunityServer({ databasePath, passwordPepper: 'manual-receipts-test' });
  await server.operationalReady;
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => {
    await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
    rmSync(directory, { recursive: true, force: true });
  });
  return register({ baseUrl: `http://127.0.0.1:${server.address().port}`, databasePath });
}
const put = (app, records, revision = 0, extra = {}) =>
  request(app, route, { method: 'PUT', body: { revision, records, ...extra } });
function stored(app, callback) {
  const db = new DatabaseSync(app.databasePath, { readOnly: true });
  try { return callback(db); } finally { db.close(); }
}
const receiptRows = (app) => stored(app, (db) => db.prepare(
  'SELECT * FROM personal_stock_receipt_items WHERE user_id=? ORDER BY item_index',
).all(app.userId));

test('manual receipts remain tagless in public snapshots and use existing schema 27', async (t) => {
  const app = await start(t);
  const first = await put(app, [stock(), stock({ uid: 'manual-spool-2', stockReceiptIndex: 1 })]);
  assert.equal(first.status, 200, JSON.stringify(first.json));
  for (const record of first.json.records) {
    assert.equal(record.sourceRfidTagUid, null);
    assert.equal(record.sourceRfidTagType, null);
    assert.equal(record.rfidTagUid, null);
    assert.equal(record.stockReceiptUid, receipt);
  }
  assert.ok(receiptRows(app).every((row) => row.source_tag_uid === '' && row.source_tag_type === ''));
  assert.equal(receiptRows(app).length, 2);
  assert.equal(stored(app, (db) => db.prepare('SELECT MAX(version) v FROM community_schema_migrations').get().v), 27);
  const replay = await put(app, first.json.records, 1);
  assert.equal(replay.status, 200, JSON.stringify(replay.json));
  assert.equal(receiptRows(app).length, 2);
});

for (const changes of [
  { sourceRfidTagUid: '04AABBCC' }, { sourceRfidTagType: 'CUID' },
  { sourceRfidTagUid: '', sourceRfidTagType: '' },
  { sourceRfidTagUid: '04AABBCCDDEEFF', sourceRfidTagType: 'NTAG213' },
  { sourceRfidTagUid: '04AABBCC', sourceRfidTagType: 'NTAG213 CUID' },
  { stockReceiptUid: null }, { stockReceiptUid: '' },
  { stockReceiptIndex: null }, { stockReceiptQuantity: null },
  { stockReceiptIndex: -1 }, { stockReceiptIndex: 2 }, { stockReceiptIndex: 0.5 },
  { stockReceiptQuantity: 0 }, { stockReceiptQuantity: 101 },
  { stockReceiptQuantity: true }, { remainingGrams: 2001 },
]) {
  test(`manual source rejects partial or invalid provenance: ${JSON.stringify(changes)}`, async (t) => {
    const app = await start(t);
    const result = await put(app, [stock(changes)]);
    assert.equal(result.status, 400, JSON.stringify(result.json));
    assert.deepEqual(receiptRows(app), []);
    assert.equal((await request(app, route)).json.revision, 0);
  });
}

test('card receipts cannot be relabeled manual and manual receipts cannot gain a fake source card', async (t) => {
  const app = await start(t);
  const card = stock({ uid: 'card-spool', sourceRfidTagUid: '04AABBCC', sourceRfidTagType: 'CUID',
    stockReceiptUid: '81bccc00-1212-4321-8123-123456789abd' });
  const first = await put(app, [stock(), card]);
  assert.equal(first.status, 200, JSON.stringify(first.json));
  for (const changed of [
    first.json.records.map((r) => r.uid === 'card-spool' ? { ...r, sourceRfidTagUid: null, sourceRfidTagType: null } : r),
    first.json.records.map((r) => r.uid === 'manual-spool-1' ? { ...r, sourceRfidTagUid: '04AABBCC', sourceRfidTagType: 'CUID' } : r),
  ]) {
    const result = await put(app, changed, 1);
    assert.equal(result.status, 409, JSON.stringify(result.json));
    assert.equal(result.json.error.code, 'inventory_stock_receipt_conflict');
    assert.deepEqual((await request(app, route)).json.records, first.json.records);
  }
});

test('old clients cannot erase manual receipt identity or downgrade its single-spool weight limit', async (t) => {
  const app = await start(t);
  const first = await put(app, [stock()]);
  const legacy = { ...first.json.records[0], remainingGrams: 123 };
  for (const key of sourceKeys) delete legacy[key];
  const updated = await put(app, [legacy], 1);
  assert.equal(updated.status, 200, JSON.stringify(updated.json));
  assert.equal(updated.json.records[0].stockReceiptUid, receipt);
  assert.equal(updated.json.records[0].sourceRfidTagUid, null);
  const overfilled = await put(app, [{ ...legacy, remainingGrams: 2001 }], 2);
  assert.equal(overfilled.status, 400, JSON.stringify(overfilled.json));
  const cleared = Object.fromEntries(sourceKeys.map((key) => [key, null]));
  const explicitNull = await put(app, [{ ...legacy, ...cleared }], 2);
  assert.equal(explicitNull.status, 200, JSON.stringify(explicitNull.json));
  assert.equal(explicitNull.json.records[0].stockReceiptUid, receipt);
  assert.equal(receiptRows(app).length, 1);
});

test('one receipt cannot mix manual and scanned-card sources, change size, or reuse an occupied index', async (t) => {
  const app = await start(t);
  for (const second of [
    stock({ uid: 'other', stockReceiptIndex: 1, sourceRfidTagUid: '04AABBCC', sourceRfidTagType: 'FUID' }),
    stock({ uid: 'other', stockReceiptIndex: 1, stockReceiptQuantity: 3 }),
    stock({ uid: 'other' }),
  ]) {
    const result = await put(app, [stock(), second]);
    assert.equal(result.status, 409, JSON.stringify(result.json));
    assert.deepEqual(receiptRows(app), []);
  }
});

test('manual receipt tombstones prevent resurrection with reused or omitted provenance', async (t) => {
  const app = await start(t);
  assert.equal((await put(app, [stock()])).status, 200);
  assert.equal((await put(app, [], 1, { deletedUids: { 'manual-spool-1': '2026-09-09T01:00:00.000Z' } })).status, 200);
  const legacy = stock();
  for (const key of sourceKeys) delete legacy[key];
  for (const candidate of [stock(), stock({ uid: 'invented-stock' }), legacy]) {
    const result = await put(app, [candidate], 2);
    assert.equal(result.status, 409, JSON.stringify(result.json));
  }
  assert.equal(receiptRows(app).length, 1);
  assert.deepEqual((await request(app, route)).json.records, []);
});

test('manual receipt IDs do not cross account boundaries and anonymous writes are rejected', async (t) => {
  const app = await start(t);
  const other = await register(app, 'manual-other');
  const anon = await request(app, route, { method: 'PUT', token: null, body: { revision: 0, records: [stock()] } });
  assert.equal(anon.status, 401);
  assert.equal((await put(app, [stock()])).status, 200);
  assert.equal((await put(other, [stock({ uid: 'other-owner-spool' })])).status, 200);
  assert.equal((await request(app, route)).json.records[0].uid, 'manual-spool-1');
  assert.equal((await request(other, route)).json.records[0].uid, 'other-owner-spool');
  assert.equal(receiptRows(app).length, 1);
  assert.equal(receiptRows(other).length, 1);
});
