import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';

import { createCommunityServer } from '../src/server.js';

const snapshotPath = '/v1/me/inventory/snapshot';

function spool(overrides = {}) {
  return {
    uid: 'physical-roll-one',
    manufacturer: 'eSUN',
    model: 'PLA',
    materialType: 'PLA',
    colorHex: '#112233',
    totalGrams: 750,
    remainingGrams: 123,
    createdAt: '2026-09-08T00:00:00.000Z',
    updatedAt: '2026-09-08T00:00:00.000Z',
    rfidTagUid: '04A1B2C3',
    rfidTagType: 'CUID',
    rfidTagCycle: 1,
    lifecycleStatus: 'active',
    previousConsumableUid: null,
    rfidTagHistory: [],
    ...overrides,
  };
}

async function request(app, path, { method = 'GET', body, authenticated = true } = {}) {
  const response = await fetch(`${app.baseUrl}${path}`, {
    method,
    headers: {
      ...(authenticated ? { Authorization: `Bearer ${app.token}` } : {}),
      ...(body ? { 'Content-Type': 'application/json' } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  return { status: response.status, json: await response.json() };
}

async function start(t) {
  const directory = mkdtempSync(join(tmpdir(), 'sohun-cuid-purpose-'));
  const databasePath = join(directory, 'inventory.sqlite');
  const server = createCommunityServer({ databasePath, passwordPepper: 'cuid-purpose-test' });
  await server.operationalReady;
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => {
    await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
    rmSync(directory, { recursive: true, force: true });
  });
  const app = { baseUrl: `http://127.0.0.1:${server.address().port}`, databasePath };
  const registration = await request(app, '/v1/auth/register', {
    method: 'POST',
    authenticated: false,
    body: {
      email: 'cuid-purpose@example.com',
      handle: 'cuid_purpose',
      displayName: '耗材标签用途回归',
      password: 'PurposeTest!123',
      acceptTerms: true,
      termsVersion: '2026-07-29',
      privacyVersion: '2026-07-29',
    },
  });
  assert.equal(registration.status, 201, JSON.stringify(registration.json));
  return { ...app, token: registration.json.accessToken, userId: registration.json.user.id };
}

// Only the isolated test database is seeded. A second SQLite connection models
// inventory that an older application version had already stored on the server.
function seedLegacy(app, records) {
  const seed = new DatabaseSync(app.databasePath);
  try {
    seed.prepare(`INSERT INTO personal_inventory_snapshots
      (user_id, revision, records_json, catalog_json, deleted_json, events_json, updated_at)
      VALUES (?, 7, ?, '[]', '{}', '[]', ?)`)
      .run(app.userId, JSON.stringify(records), '2026-09-08T00:00:00.000Z');
  } finally {
    seed.close();
  }
}

function put(app, records, revision = 0) {
  return request(app, snapshotPath, { method: 'PUT', body: { revision, records } });
}

async function assertRejectedWithoutMutation(app, records, original) {
  const result = await put(app, records, 7);
  assert.ok(result.status === 400 || result.status === 409, JSON.stringify(result));
  const current = await request(app, snapshotPath);
  assert.equal(current.status, 200);
  assert.equal(current.json.revision, 7);
  assert.deepEqual(current.json.records, Array.isArray(original) ? original : [original]);
}

for (const type of ['CUID', ' fuid ', 'ams']) {
  test(`new ${type} inventory preserves physical spool identity and weight`, async (t) => {
    const app = await start(t);
    const record = spool({ rfidTagType: type });
    const response = await put(app, [record]);
    assert.equal(response.status, 200, JSON.stringify(response.json));
    assert.equal(response.json.records[0].uid, record.uid);
    assert.equal(response.json.records[0].totalGrams, 750);
    assert.equal(response.json.records[0].remainingGrams, 123);
  });
}

for (const type of [undefined, null, '', 'unknown', 'CLASSIC', 'NTAG213', 'NTAG213 CUID', 'FUID-emulator']) {
  test(`new ${String(type)} tagged inventory is rejected before storing any record`, async (t) => {
    const app = await start(t);
    const response = await put(app, [spool({ rfidTagType: type })]);
    assert.equal(response.status, 400, JSON.stringify(response.json));
    assert.equal(response.json.error.code, 'unsupported_inventory_tag_type');
    const current = await request(app, snapshotPath);
    assert.equal(current.json.revision, 0);
    assert.deepEqual(current.json.records, []);
  });
}

test('ordinary manual inventory remains available without a tag', async (t) => {
  const app = await start(t);
  const response = await put(app, [spool({ rfidTagUid: null, rfidTagType: null })]);
  assert.equal(response.status, 200, JSON.stringify(response.json));
  assert.equal(response.json.records[0].rfidTagUid, null);
  assert.equal(response.json.records[0].remainingGrams, 123);
});

for (const type of ['NTAG213', 'unknown', 'CLASSIC', null]) {
  test(`legacy ${String(type)} history can round-trip and archive without losing stock`, async (t) => {
    const app = await start(t);
    const record = spool({ rfidTagType: type });
    seedLegacy(app, [record]);
    const roundTrip = await put(app, [record], 7);
    assert.equal(roundTrip.status, 200, JSON.stringify(roundTrip.json));
    const archived = await put(app, [{ ...roundTrip.json.records[0], lifecycleStatus: 'retired' }], 8);
    assert.equal(archived.status, 200, JSON.stringify(archived.json));
    assert.equal(archived.json.records[0].uid, record.uid);
    assert.equal(archived.json.records[0].totalGrams, 750);
    assert.equal(archived.json.records[0].remainingGrams, 123);
    assert.equal(archived.json.records[0].lifecycleStatus, 'retired');
  });
}

test('known NTAG history cannot change consumable data, weight, tag or declared card type', async (t) => {
  const app = await start(t);
  const original = spool({ rfidTagType: 'NTAG213' });
  seedLegacy(app, [original]);
  for (const changes of [
    { manufacturer: 'new manufacturer' },
    { model: 'PETG' },
    { colorHex: '#FF0000' },
    { note: 'attempted NFC metadata rewrite' },
    { remainingGrams: 120 },
    { remainingGrams: 130 },
    { totalGrams: 1000 },
    { rfidTagUid: '04BB0002' },
    { rfidTagType: 'CUID' },
    { rfidTagType: 'FUID' },
    { rfidTagType: 'ams' },
  ]) {
    await assertRejectedWithoutMutation(app, [{ ...original, ...changes }], original);
  }
});

for (const type of ['NTAG213', 'CUID']) {
  test(`NTAG history cannot gain a new ${type} successor cycle`, async (t) => {
    const app = await start(t);
    const original = spool({ rfidTagType: 'NTAG213', lifecycleStatus: 'retired' });
    seedLegacy(app, [original]);
    await assertRejectedWithoutMutation(app, [
      original,
      spool({ uid: 'forbidden-next', rfidTagType: type, rfidTagCycle: 2, previousConsumableUid: original.uid }),
    ], original);
  });
}

test('old NTAG cannot be retagged to a CUID through appended binding history', async (t) => {
  const app = await start(t);
  const original = spool({ rfidTagType: 'NTAG213', lifecycleStatus: 'replaced' });
  const successor = spool({ uid: 'legacy-next', rfidTagType: 'NTAG213', rfidTagCycle: 2, previousConsumableUid: original.uid });
  seedLegacy(app, [original, successor]);
  await assertRejectedWithoutMutation(app, [
    spool({
      rfidTagUid: '04BB0002',
      rfidTagHistory: [{ tagUid: original.rfidTagUid, tagType: 'NTAG213', cycle: 1, previousInventoryUid: null }],
    }),
    successor,
  ], [original, successor]);
});

for (const type of [null, '', 'CLASSIC', 'MIFARE_CLASSIC', 'MIFARE_CLASSIC_1K', 'MIFARE CLASSIC', 'MIFARE CLASSIC 1K']) {
  test(`legacy ${String(type)} can be explicitly confirmed as CUID on the same roll`, async (t) => {
    const app = await start(t);
    const original = spool({ rfidTagType: type });
    seedLegacy(app, [original]);
    const confirmation = await put(app, [{ ...original, rfidTagType: 'CUID' }], 7);
    assert.equal(confirmation.status, 200, JSON.stringify(confirmation.json));
    const confirmed = confirmation.json.records[0];
    assert.equal(confirmed.uid, original.uid);
    assert.equal(confirmed.rfidTagUid, original.rfidTagUid);
    assert.equal(confirmed.rfidTagCycle, original.rfidTagCycle);
    assert.equal(confirmed.remainingGrams, original.remainingGrams);
    assert.equal(confirmed.totalGrams, original.totalGrams);
    assert.equal(confirmed.rfidTagType, 'CUID');
  });
}

test('confirming a legacy card variant cannot refill or consume its physical spool', async (t) => {
  const app = await start(t);
  const original = spool({ rfidTagType: 'CLASSIC' });
  seedLegacy(app, [original]);
  for (const changes of [
    { remainingGrams: 750 },
    { remainingGrams: 100 },
    { totalGrams: 2000, remainingGrams: 2000 },
    { lifecycleStatus: 'retired' },
  ]) {
    await assertRejectedWithoutMutation(app, [{ ...original, rfidTagType: 'CUID', ...changes }], original);
  }
});
