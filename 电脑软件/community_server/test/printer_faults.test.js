import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createCommunityServer } from '../src/server.js';

async function setup(t, options = {}) {
  const directory = mkdtempSync(join(tmpdir(), 'sohun-fault-test-'));
  const server = createCommunityServer({ databasePath: join(directory, 'test.sqlite'), passwordPepper: 'fault-test-pepper', autoVerifyEmail: true, ...options });
  await server.operationalReady;
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => { await new Promise((resolve) => server.close(resolve)); rmSync(directory, { recursive: true, force: true }); });
  const request = async (path, token, body, method = body ? 'POST' : 'GET') => {
    const res = await fetch(`http://127.0.0.1:${server.address().port}${path}`, {
      method, headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), 'Content-Type': 'application/json' },
      body: body ? JSON.stringify(body) : undefined });
    return { status: res.status, data: await res.json(), headers: res.headers };
  };
  const register = async (name) => {
    const result = await request('/v1/auth/register', null, { email: `${name}@example.com`, handle: name,
      displayName: name, password: 'StrongPass123', acceptTerms: true, termsVersion: '2026-07-29', privacyVersion: '2026-07-29' });
    assert.equal(result.status, 201); return result.data.accessToken;
  };
  return { request, register };
}
const fault = (id = 'fault-1') => ({ eventId: id, printerKey: 'opaque-printer-id', printerName: '书房 X1C', model: 'X1C',
  code: '07004001', kind: 'print_error', severity: 'error', title: '打印任务异常', message: '请将耗材退回 AMS。',
  source: 'bambu-official', sourceVersion: '202608251159', helpUrl: 'https://e.bambulab.com/index.php?e=07004001&s=device_error&lang=zh-cn',
  firstSeenAt: '2026-09-06T01:00:00.000Z', lastSeenAt: '2026-09-06T01:00:00.000Z', clearedAt: null, readAt: null });

test('printer faults isolate accounts, deduplicate retries, preserve reads and explicit clears', async (t) => {
  const { request, register } = await setup(t);
  const alice = await register('fault_alice'), bob = await register('fault_bob');
  const post = (events, token = alice) => request('/v1/me/printer-faults', token, { events });
  assert.equal((await request('/v1/me/printer-faults')).status, 401);
  assert.equal((await post([fault()])).status, 200);
  const first = await request('/v1/me/printer-faults', alice);
  assert.equal(first.data.events.length, 1);
  assert.equal((await request('/v1/me/printer-faults', bob)).data.events.length, 0);
  await post([fault()]);
  assert.equal((await request(`/v1/me/printer-faults?after=${first.data.cursor}`, alice)).data.events.length, 0);
  await request('/v1/me/printer-faults/read', bob, { eventIds: ['fault-1'] });
  assert.equal((await request('/v1/me/printer-faults', alice)).data.events[0].readAt, null);
  await request('/v1/me/printer-faults/read', alice, { eventIds: ['fault-1'] });
  await post([{ ...fault(), lastSeenAt: '2026-09-06T01:01:00.000Z' }]);
  assert.ok((await request('/v1/me/printer-faults', alice)).data.events[0].readAt);
  await post([{ ...fault(), lastSeenAt: '2026-09-06T01:02:00.000Z', clearedAt: '2026-09-06T01:02:00.000Z' }]);
  await post([{ ...fault(), lastSeenAt: '2026-09-06T01:03:00.000Z' }]);
  assert.ok((await request('/v1/me/printer-faults', alice)).data.events[0].clearedAt);
  assert.equal((await post([{ ...fault(), printerKey: 'different' }])).status, 409);
  assert.equal((await post([{ ...fault('bad'), accessCode: 'should-not-upload' }])).status, 400);
  assert.equal((await post([{ ...fault('bad-url'), helpUrl: 'https://example.com/' }])).status, 400);
  await post([fault('fault-recur')]);
  assert.equal((await request('/v1/me/printer-faults', alice)).data.events.length, 2);
});

test('background lease only reads this account faults and can be revoked', async (t) => {
  const { request, register } = await setup(t);
  const alice = await register('lease_alice'), bob = await register('lease_bob');
  await request('/v1/me/printer-faults', alice, { events: [fault()] });
  const lease = await request('/v1/me/printer-faults/monitor', alice, {});
  assert.equal(lease.status, 200);
  const token = lease.data.token;
  assert.equal((await request('/v1/notifications/printer-faults', token)).data.events.length, 1);
  assert.equal((await request('/v1/me/inventory/snapshot', token)).status, 401);
  assert.equal((await request('/v1/notifications/printer-faults', token, { events: [] })).status, 403);
  const other = await request('/v1/me/printer-faults/monitor', bob, {});
  assert.equal((await request('/v1/notifications/printer-faults', other.data.token)).data.events.length, 0);
  assert.equal((await request('/v1/notifications/printer-faults', token, null, 'DELETE')).status, 200);
  assert.equal((await request('/v1/notifications/printer-faults', token)).status, 401);
});

test('fault cursor pages through more than 200 events and includes later clears', async (t) => {
  const { request, register } = await setup(t);
  const token = await register('fault_paging');
  for (let offset = 0; offset < 250; offset += 100) {
    const events = Array.from({ length: Math.min(100, 250 - offset) }, (_, i) => fault(`page-${offset + i}`));
    assert.equal((await request('/v1/me/printer-faults', token, { events })).status, 200);
  }
  const first = (await request('/v1/me/printer-faults', token)).data;
  assert.equal(first.events.length, 200); assert.equal(first.hasMore, true);
  const second = (await request(`/v1/me/printer-faults?after=${first.cursor}`, token)).data;
  assert.equal(second.events.length, 50); assert.equal(second.hasMore, false);
  await request('/v1/me/printer-faults', token, { events: [{ ...fault('page-0'), clearedAt: '2026-09-06T01:05:00.000Z', lastSeenAt: '2026-09-06T01:05:00.000Z' }] });
  const clear = (await request(`/v1/me/printer-faults?after=${second.cursor}`, token)).data;
  assert.equal(clear.events.length, 1); assert.ok(clear.events[0].clearedAt);
});

test('background fault responses and expired credentials cannot be cached', async (t) => {
  const { request, register } = await setup(t);
  const token = await register('fault_cache');
  const lease = await request('/v1/me/printer-faults/monitor', token, {});
  for (const credential of [lease.data.token, undefined]) {
    const result = await request('/v1/notifications/printer-faults', credential);
    assert.equal(result.status, credential ? 200 : 401);
    assert.equal(result.headers.get('cache-control'), 'no-store');
    assert.equal(result.headers.get('pragma'), 'no-cache');
  }
});

test('fault count quota is account scoped, atomic and permits retries, reads and clears', async (t) => {
  const { request, register } = await setup(t, { maxPrinterFaultsPerUser: 2 });
  const alice = await register('quota_alice'), bob = await register('quota_bob');
  const post = (events, token = alice) => request('/v1/me/printer-faults', token, { events });
  assert.equal((await post([fault('one'), fault('one'), fault('two')])).status, 200);
  const first = (await request('/v1/me/printer-faults', alice)).data;
  assert.equal(first.events.length, 2);
  const rejected = await post([{ ...fault('one'), title: 'must roll back' }, fault('three'), fault('four'), fault('three')]);
  assert.equal(rejected.status, 409);
  assert.equal(rejected.data.error.code, 'printer_fault_count_quota_exceeded');
  assert.deepEqual(rejected.data.error.details.rejectedEventIds, ['three', 'four']);
  const afterFailure = (await request('/v1/me/printer-faults', alice)).data;
  assert.equal(afterFailure.cursor, first.cursor);
  assert.equal(afterFailure.events[0].title, fault().title);
  assert.equal((await post([fault('one')])).status, 200);
  assert.equal((await request('/v1/me/printer-faults/read', alice, { eventIds: ['one'] })).status, 200);
  assert.equal((await post([{ ...fault('one'), lastSeenAt: '2026-09-06T01:05:00.000Z', clearedAt: '2026-09-06T01:05:00.000Z' }])).status, 200);
  const cleared = (await request('/v1/me/printer-faults', alice)).data.events.find((e) => e.eventId === 'one');
  assert.ok(cleared.clearedAt); assert.ok(cleared.readAt);
  assert.equal((await post([fault('three')], bob)).status, 200);
});

test('fault UTF-8 storage quota reserves lifecycle timestamps and rejects growth atomically', async (t) => {
  const initial = { ...fault(), message: '故障'.repeat(20) };
  const reservedBytes = Buffer.byteLength(JSON.stringify(initial)) + 44;
  const { request, register } = await setup(t, { maxPrinterFaultBytesPerUser: reservedBytes });
  const token = await register('bytes_quota');
  const post = (events) => request('/v1/me/printer-faults', token, { events });
  assert.equal((await post([initial])).status, 200);
  const first = (await request('/v1/me/printer-faults', token)).data;
  const rejected = await post([{ ...initial, message: `${initial.message}多` }]);
  assert.equal(rejected.status, 413);
  assert.equal(rejected.data.error.code, 'printer_fault_storage_quota_exceeded');
  assert.deepEqual(rejected.data.error.details.rejectedEventIds, [initial.eventId]);
  assert.equal((await request('/v1/me/printer-faults', token)).data.cursor, first.cursor);
  assert.equal((await request('/v1/me/printer-faults/read', token, { eventIds: [initial.eventId] })).status, 200);
  assert.equal((await post([{ ...initial, lastSeenAt: '2026-09-06T01:05:00.000Z', clearedAt: '2026-09-06T01:05:00.000Z' }])).status, 200);
  const cleared = (await request('/v1/me/printer-faults', token)).data.events[0];
  assert.ok(cleared.readAt); assert.ok(cleared.clearedAt);
});

test('fault writes, lease creation and anonymous reads are rate limited and recover', async (t) => {
  let now = Date.now();
  const { request, register } = await setup(t, { rateLimitNow: () => now });
  const token = await register('fault_throttle');
  for (let i = 0; i < 120; i++) {
    assert.equal((await request('/v1/me/printer-faults', token, { events: [] })).status, 200);
  }
  assert.equal((await request('/v1/me/printer-faults', token, { events: [] })).status, 429);
  // Writes cannot prevent the user from reading existing fault history.
  assert.equal((await request('/v1/me/printer-faults', token)).status, 200);
  now += 60_001;
  assert.equal((await request('/v1/me/printer-faults', token, { events: [] })).status, 200);
  for (let i = 0; i < 10; i++) {
    assert.equal((await request('/v1/me/printer-faults/monitor', token, {})).status, 200);
  }
  assert.equal((await request('/v1/me/printer-faults/monitor', token, {})).status, 429);
  now += 60_001;
  for (let i = 0; i < 600; i++) {
    assert.equal((await request('/v1/notifications/printer-faults')).status, 401);
  }
  assert.equal((await request('/v1/notifications/printer-faults')).status, 429);
});
