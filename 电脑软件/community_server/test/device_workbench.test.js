import assert from 'node:assert/strict';
import { request as httpRequest } from 'node:http';
import test from 'node:test';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';

import { createCommunityServer } from '../src/server.js';
import { MIGRATIONS } from '../src/migrations.js';

const KEY_A = 'a'.repeat(64);
const KEY_B = 'b'.repeat(64);
const BEFORE = new Date(Date.now() - 120_000).toISOString();
const AFTER = new Date(Date.now() - 60_000).toISOString();

function snapshot(overrides = {}) {
  return { printerKey: KEY_A, name: '书房打印机', model: 'P1S', online: true,
    state: 'running', taskName: '设备入口测试任务', progress: 35, remainingMinutes: 30,
    nozzleTemperature: 219.5, bedTemperature: 60.25, observedAt: BEFORE, ...overrides };
}

function maintenance(overrides = {}) {
  return { eventId: 'maintenance-event-01', printerKey: KEY_A, kind: 'cleaning',
    notes: '清洁导杆与设备表面', performedAt: BEFORE, nextDueAt: null, faultEventId: null,
    ...overrides };
}

function inventoryRecord(overrides = {}) {
  return { uid: 'independent-spool-uid', manufacturer: 'eSUN', model: 'PLA Basic', materialType: 'PLA Basic',
    colorHex: '#12ABEF', colorName: '湖蓝', totalGrams: 1000, remainingGrams: 640.25, batchNo: null,
    purchaseDate: BEFORE, note: null, createdAt: BEFORE, updatedAt: BEFORE, density: 1.24,
    recommendedNozzleTemp: 220, hygroscopicity: 'low', trayUuid: null, rfidSyncedAt: null,
    rfidTagUid: '04A1B2C3', rfidTagType: 'CUID', rfidTagCycle: 1, lifecycleStatus: 'active',
    previousConsumableUid: null, ...overrides };
}

async function setup(t) {
  const directory = mkdtempSync(join(tmpdir(), 'sohun-device-workbench-'));
  const databasePath = join(directory, 'test.sqlite');
  const options = { databasePath, passwordPepper: 'device-workbench-test-pepper', autoVerifyEmail: true };
  let server;
  const start = async () => {
    server = createCommunityServer(options);
    await server.operationalReady;
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  };
  const stop = async () => {
    if (!server?.listening) return;
    await new Promise((resolve) => server.close(resolve));
  };
  await start();
  t.after(async () => { await stop(); rmSync(directory, { recursive: true, force: true }); });
  const request = async (path, token, body, method = body === undefined ? 'GET' : 'POST') => {
    const response = await fetch(`http://127.0.0.1:${server.address().port}${path}`, {
      method, headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), 'Content-Type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    return { status: response.status, data: await response.json(), headers: response.headers };
  };
  const register = async (name) => {
    const result = await request('/v1/auth/register', null, { email: `${name}@example.com`, handle: name,
      displayName: name, password: 'StrongPass123', acceptTerms: true,
      termsVersion: '2026-07-29', privacyVersion: '2026-07-29' });
    assert.equal(result.status, 201, JSON.stringify(result.data));
    return result.data.accessToken;
  };
  const database = (action) => {
    const db = new DatabaseSync(databasePath);
    try { return action(db); } finally { db.close(); }
  };
  const delayedBody = async (path, token, body, method = 'PATCH') => {
    const bytes = JSON.stringify(body);
    let resolveReached;
    const reached = new Promise((resolve) => { resolveReached = resolve; });
    const listener = (incoming) => {
      if (incoming.headers['x-device-test-delayed'] !== 'true') return;
      server.off('request', listener);
      // All route microtasks have run and readJson is now waiting for the body.
      setImmediate(resolveReached);
    };
    server.on('request', listener);
    let outgoing;
    const result = new Promise((resolve, reject) => {
      outgoing = httpRequest(`http://127.0.0.1:${server.address().port}${path}`, {
        method, headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(bytes), 'X-Device-Test-Delayed': 'true' },
      }, (response) => {
        const chunks = [];
        response.on('data', (chunk) => chunks.push(chunk));
        response.on('end', () => resolve({ status: response.statusCode, data: JSON.parse(Buffer.concat(chunks)) }));
      });
      outgoing.on('error', reject);
      outgoing.flushHeaders();
    });
    await reached;
    return { finish: async () => { outgoing.end(bytes); return result; } };
  };
  return { request, register, database, stop, start, delayedBody };
}

test('设备及标签解析要求登录，同一打印机键在不同账号具有独立 token', async (t) => {
  const { request, register } = await setup(t);
  const alice = await register('device_alice'), bob = await register('device_bob');
  for (const token of [alice, bob]) {
    assert.equal((await request('/v1/me/devices/status', token, { devices: [snapshot()] })).status, 200);
  }
  const a = (await request('/v1/me/devices', alice)).data.devices[0];
  const b = (await request('/v1/me/devices', bob)).data.devices[0];
  assert.match(a.deviceToken, /^[a-f0-9]{32}$/);
  assert.notEqual(a.deviceToken, b.deviceToken);
  assert.equal((await request('/v1/me/devices')).status, 401);
  assert.equal((await request(`/v1/me/device-tags/${a.deviceToken}`)).status, 401);
  assert.equal((await request(`/v1/me/device-tags/${a.deviceToken}`, bob)).status, 404);
  assert.equal((await request(`/v1/me/device-tags/${b.deviceToken}`, alice)).status, 404);
  const resolved = await request(`/v1/me/device-tags/${a.deviceToken}`, alice);
  assert.equal(resolved.status, 200);
  assert.equal(resolved.data.device.printerKey, KEY_A);
  assert.equal(resolved.headers.get('cache-control'), 'no-store');
  assert.equal((await request('/v1/me/device-tags/04AABBCCDDEE11', alice)).status, 404);
});

test('设备状态白名单拒绝凭据、耗材字段、客户端伪造 token 和整批部分提交', async (t) => {
  const { request, register } = await setup(t);
  const token = await register('device_whitelist');
  const upload = (devices, extra = {}) => request('/v1/me/devices/status', token, { devices, ...extra });
  assert.equal((await upload([snapshot()])).status, 200);
  for (const field of ['accessCode', 'accessToken', 'ipAddress', 'cameraUrl', 'rfidTagUid', 'remainingGrams', 'deviceToken']) {
    const result = await upload([snapshot({ printerKey: KEY_B }), snapshot({ [field]: 'never-save-this' })]);
    assert.equal(result.status, 400, field);
    const stored = (await request('/v1/me/devices', token)).data.devices;
    assert.equal(stored.length, 1);
    assert.doesNotMatch(JSON.stringify(stored), /never-save-this/);
  }
  assert.equal((await upload([snapshot(), snapshot()])).status, 400);
  assert.equal((await upload([], { accessCode: 'no' })).status, 400);
  for (const values of [
    { online: 'true' }, { progress: 100.1 }, { progress: -1 }, { remainingMinutes: 1.5 },
    { nozzleTemperature: 601 }, { bedTemperature: -51 }, { name: ' ' },
    { observedAt: new Date(Date.now() + 600_000).toISOString() },
  ]) {
    assert.equal((await upload([snapshot(values)])).status, 400, JSON.stringify(values));
  }
});

test('改名和新状态保留标签 token，较旧状态不会回滚设备或摄像头设置', async (t) => {
  const { request, register } = await setup(t);
  const token = await register('device_status_order');
  const upload = (value) => request('/v1/me/devices/status', token, { devices: [value] });
  await upload(snapshot());
  const first = (await request(`/v1/me/devices/${KEY_A}`, token)).data.device;
  const cameraUrl = 'https://camera.example/device-entry';
  assert.equal((await request(`/v1/me/devices/${KEY_A}`, token, { cameraUrl }, 'PATCH')).status, 200);
  await upload(snapshot({ name: '重命名后的打印机', state: 'idle', progress: 100, observedAt: AFTER }));
  await upload(snapshot({ name: '迟到的旧名称', state: 'running', progress: 10 }));
  const current = (await request(`/v1/me/device-tags/${first.deviceToken}`, token)).data.device;
  assert.equal(current.deviceToken, first.deviceToken);
  assert.equal(current.name, '重命名后的打印机');
  assert.equal(current.state, 'idle');
  assert.equal(current.progress, 100);
  assert.equal(current.observedAt, AFTER);
  assert.equal(current.cameraUrl, cameraUrl);
});

test('摄像头 PATCH 校验完整请求，非法字段或协议不能留下部分归档或链接变更', async (t) => {
  const { request, register } = await setup(t);
  const token = await register('device_camera_atomic');
  await request('/v1/me/devices/status', token, { devices: [snapshot()] });
  const patch = (body) => request(`/v1/me/devices/${KEY_A}`, token, body, 'PATCH');
  const original = (await patch({ cameraUrl: 'https://camera.example/entry' })).data.device;
  for (const cameraUrl of ['http://camera.example/', 'rtsp://camera.example/', 'https://user:pass@camera.example/',
    'file:///private', 'javascript:alert(1)', '/camera', 'not a URL']) {
    assert.equal((await patch({ cameraUrl, archived: true })).status, 400);
    const current = (await request(`/v1/me/devices/${KEY_A}`, token)).data.device;
    assert.equal(current.cameraUrl, original.cameraUrl);
    assert.equal(current.archived, false);
    assert.equal(current.deviceToken, original.deviceToken);
  }
  assert.equal((await patch({ cameraUrl: 'https://camera.example/other', archived: 'true' })).status, 400);
  assert.equal((await patch({ cameraUrl: 'https://camera.example/other', accessCode: 'no' })).status, 400);
  assert.equal((await request(`/v1/me/devices/${KEY_A}`, token)).data.device.cameraUrl, original.cameraUrl);
  assert.equal((await patch({ cameraUrl: null })).data.device.cameraUrl, null);
});

test('归档停止标签访问和状态推送，恢复及主动轮换均使旧标签失效', async (t) => {
  const { request, register } = await setup(t);
  const token = await register('device_archive');
  await request('/v1/me/devices/status', token, { devices: [snapshot()] });
  const first = (await request(`/v1/me/devices/${KEY_A}`, token)).data.device;
  const archived = (await request(`/v1/me/devices/${KEY_A}`, token, { archived: true }, 'PATCH')).data.device;
  assert.equal(archived.archived, true);
  assert.notEqual(archived.deviceToken, first.deviceToken);
  assert.equal((await request(`/v1/me/device-tags/${first.deviceToken}`, token)).status, 404);
  assert.equal((await request(`/v1/me/device-tags/${archived.deviceToken}`, token)).status, 404);
  assert.deepEqual((await request('/v1/me/devices', token)).data.devices, []);
  assert.equal((await request('/v1/me/devices?includeArchived=true', token)).data.devices.length, 1);
  await request('/v1/me/devices/status', token, { devices: [snapshot({ name: '不得恢复共享', observedAt: AFTER })] });
  assert.equal((await request(`/v1/me/devices/${KEY_A}/rotate-tag`, token, {})).status, 404);
  assert.equal((await request(`/v1/me/devices/${KEY_A}/maintenance`, token, maintenance())).status, 404);
  const restored = (await request(`/v1/me/devices/${KEY_A}`, token, { archived: false }, 'PATCH')).data.device;
  assert.equal(restored.archived, false);
  assert.equal(restored.name, first.name);
  assert.notEqual(restored.deviceToken, archived.deviceToken);
  assert.equal((await request(`/v1/me/device-tags/${first.deviceToken}`, token)).status, 404);
  assert.equal((await request(`/v1/me/device-tags/${restored.deviceToken}`, token)).status, 200);
  const rotated = (await request(`/v1/me/devices/${KEY_A}/rotate-tag`, token, {})).data.device;
  assert.notEqual(rotated.deviceToken, restored.deviceToken);
  assert.equal((await request(`/v1/me/device-tags/${restored.deviceToken}`, token)).status, 404);
  assert.equal((await request(`/v1/me/device-tags/${rotated.deviceToken}`, token)).status, 200);
});

test('维护事件重试幂等，内容冲突不可覆盖，事件 UID 按账号隔离', async (t) => {
  const { request, register } = await setup(t);
  const alice = await register('maintenance_alice'), bob = await register('maintenance_bob');
  for (const token of [alice, bob]) {
    await request('/v1/me/devices/status', token, { devices: [snapshot(), snapshot({ printerKey: KEY_B })] });
  }
  const url = `/v1/me/devices/${KEY_A}/maintenance`;
  const entry = maintenance({ nextDueAt: new Date(Date.now() + 30 * 86400_000).toISOString() });
  const first = await request(url, alice, entry);
  assert.equal(first.status, 201, JSON.stringify(first.data));
  assert.equal((await request(url, alice, entry)).status, 200);
  assert.equal((await request(url, alice, { ...entry, notes: '覆盖旧记录' })).status, 409);
  assert.equal((await request(`/v1/me/devices/${KEY_B}/maintenance`, alice, { ...entry, printerKey: KEY_B })).status, 409);
  const records = (await request(url, alice)).data.records;
  assert.equal(records.length, 1);
  assert.equal(records[0].notes, entry.notes);
  assert.equal((await request(url, bob)).data.records.length, 0);
  assert.equal((await request(url, bob, { ...entry, notes: '乙账号独立记录' })).status, 201);
  assert.equal((await request(url, alice)).data.records[0].notes, entry.notes);
});

test('维护分页跨过100条且正确跳过其他账号和其他设备的序号', async (t) => {
  const { request, register } = await setup(t);
  const alice = await register('maintenance_paging'), bob = await register('maintenance_other');
  await request('/v1/me/devices/status', alice, { devices: [snapshot(), snapshot({ printerKey: KEY_B })] });
  await request('/v1/me/devices/status', bob, { devices: [snapshot()] });
  const url = `/v1/me/devices/${KEY_A}/maintenance`;
  for (let i = 0; i < 101; i++) {
    const body = maintenance({ eventId: `maintenance-page-${i}` });
    assert.equal((await request(url, alice, body)).status, 201);
    if (i === 50) assert.equal((await request(url, bob, body)).status, 201);
  }
  assert.equal((await request(`/v1/me/devices/${KEY_B}/maintenance`, alice,
    maintenance({ eventId: 'maintenance-other-device', printerKey: KEY_B }))).status, 201);
  const first = (await request(url, alice)).data;
  assert.equal(first.records.length, 100);
  assert.equal(first.hasMore, true);
  const second = (await request(`${url}?after=${first.cursor}`, alice)).data;
  assert.equal(second.records.length, 1);
  assert.equal(second.hasMore, false);
  assert.equal(new Set([...first.records, ...second.records].map((r) => r.eventId)).size, 101);
  const allFirst = (await request('/v1/me/devices/maintenance', alice)).data;
  const allSecond = (await request(`/v1/me/devices/maintenance?after=${allFirst.cursor}`, alice)).data;
  assert.equal(allFirst.records.length + allSecond.records.length, 102);
  assert.equal(allSecond.records.find((r) => r.printerKey === KEY_B)?.eventId, 'maintenance-other-device');
  assert.equal((await request('/v1/me/devices/maintenance', bob)).data.records.length, 1);
  for (const after of ['-1', '1.5', 'NaN', '9007199254740992']) {
    assert.equal((await request(`${url}?after=${after}`, alice)).status, 400);
    assert.equal((await request(`/v1/me/devices/maintenance?after=${after}`, alice)).status, 400);
  }
});

test('维护实际发生时间限制与未来保养日期相互独立，非法资料不写账', async (t) => {
  const { request, register } = await setup(t);
  const token = await register('maintenance_dates');
  await request('/v1/me/devices/status', token, { devices: [snapshot()] });
  const url = `/v1/me/devices/${KEY_A}/maintenance`;
  const future = new Date(Date.now() + 90 * 86400_000).toISOString();
  assert.equal((await request(url, token, maintenance({ nextDueAt: future }))).status, 201);
  const invalid = [
    { performedAt: new Date(Date.now() + 600_000).toISOString() },
    { performedAt: 'not-a-date' }, { nextDueAt: 'not-a-date' },
    { nextDueAt: new Date(Date.parse(BEFORE) - 1000).toISOString() },
    { kind: 'consume_spool' }, { printerKey: KEY_B }, { remainingGrams: 500 },
    { eventId: 'short' }, { notes: 'x'.repeat(2001) },
  ];
  for (const [index, fields] of invalid.entries()) {
    const result = await request(url, token, maintenance({ eventId: `maintenance-invalid-${index}`, ...fields }));
    assert.equal(result.status, 400, JSON.stringify(fields));
  }
  assert.equal((await request(url, token)).data.records.length, 1);
  assert.equal((await request(url, token)).data.records[0].nextDueAt, future);
});

test('维护关联故障必须同时属于当前账号及设备', async (t) => {
  const { request, register } = await setup(t);
  const alice = await register('maintenance_fault_a'), bob = await register('maintenance_fault_b');
  await request('/v1/me/devices/status', alice, { devices: [snapshot()] });
  const fault = (eventId, printerKey) => ({ eventId, printerKey, printerName: '书房打印机', model: 'P1S',
    code: '07004001', kind: 'print_error', severity: 'error', title: '打印任务异常', message: '请检查设备',
    source: 'bambu-official', sourceVersion: '202608251159',
    helpUrl: 'https://e.bambulab.com/index.php?e=07004001&s=device_error&lang=zh-cn',
    firstSeenAt: BEFORE, lastSeenAt: BEFORE, clearedAt: null, readAt: null });
  assert.equal((await request('/v1/me/printer-faults', bob, { events: [fault('fault-other-account', KEY_A)] })).status, 200);
  assert.equal((await request('/v1/me/printer-faults', alice, { events: [fault('fault-other-device', KEY_B), fault('fault-owned-device', KEY_A)] })).status, 200);
  const url = `/v1/me/devices/${KEY_A}/maintenance`;
  for (const id of ['fault-missing', 'fault-other-account', 'fault-other-device']) {
    assert.equal((await request(url, alice, maintenance({ faultEventId: id }))).status, 400);
  }
  assert.equal((await request(url, alice, maintenance({ faultEventId: 'fault-owned-device' }))).status, 201);
});

test('外账号不能更新、归档、轮换或记录未拥有设备', async (t) => {
  const { request, register } = await setup(t);
  const alice = await register('device_owner_a'), bob = await register('device_owner_b');
  await request('/v1/me/devices/status', alice, { devices: [snapshot()] });
  const first = (await request(`/v1/me/devices/${KEY_A}`, alice)).data.device;
  assert.equal((await request(`/v1/me/devices/${KEY_A}`, bob)).status, 404);
  assert.equal((await request(`/v1/me/devices/${KEY_A}`, bob, { archived: true }, 'PATCH')).status, 404);
  assert.equal((await request(`/v1/me/devices/${KEY_A}/rotate-tag`, bob, {})).status, 404);
  assert.equal((await request(`/v1/me/devices/${KEY_A}/maintenance`, bob, maintenance())).status, 404);
  assert.equal((await request(`/v1/me/devices/${KEY_A}/maintenance`, bob)).status, 404);
  assert.deepEqual((await request(`/v1/me/devices/${KEY_A}`, alice)).data.device, first);
});

test('设备和保养操作不创建或修改任何耗材库存及消耗账本', async (t) => {
  const { request, register, database } = await setup(t);
  const token = await register('device_inventory_isolation');
  const record = inventoryRecord();
  const saved = await request('/v1/me/inventory/snapshot', token, { revision: 0, records: [record], materialCatalog: ['PLA Basic'] }, 'PUT');
  assert.equal(saved.status, 200, JSON.stringify(saved.data));
  const readInventory = () => database((db) => Object.fromEntries([
    'personal_inventory_snapshots', 'personal_inventory_events', 'personal_inventory_tag_claims',
  ].map((name) => [name, db.prepare(`SELECT * FROM ${name} ORDER BY rowid`).all()])));
  const before = readInventory();
  await request('/v1/me/devices/status', token, { devices: [snapshot()] });
  await request(`/v1/me/devices/${KEY_A}/maintenance`, token, maintenance());
  await request(`/v1/me/devices/${KEY_A}`, token, { cameraUrl: 'https://camera.example/entry' }, 'PATCH');
  await request(`/v1/me/devices/${KEY_A}/rotate-tag`, token, {});
  await request(`/v1/me/devices/${KEY_A}`, token, { archived: true }, 'PATCH');
  await request(`/v1/me/devices/${KEY_A}`, token, { archived: false }, 'PATCH');
  assert.deepEqual(readInventory(), before);
  assert.equal((await request('/v1/me/inventory/snapshot', token)).data.records[0].remainingGrams, 640.25);
  assert.equal((await request('/v1/me/devices/maintenance', token)).data.records.length, 1);
});

test('v25已有账号与库存可升级当前版本，重启保留设备、标签及维护记录', async (t) => {
  const { request, register, database, stop, start } = await setup(t);
  const token = await register('device_upgrade');
  assert.equal((await request('/v1/me/inventory/snapshot', token,
    { revision: 0, records: [inventoryRecord()], materialCatalog: ['PLA Basic'] }, 'PUT')).status, 200);
  const beforeInventory = (await request('/v1/me/inventory/snapshot', token)).data;
  await stop();
  database((db) => {
    // This isolated fixture has no device rows. Removing only the new empty
    // tables reproduces the actual v25 table set while retaining old data.
    assert.equal(db.prepare('SELECT COUNT(*) AS count FROM personal_stock_receipt_items').get().count, 0);
    db.exec('DROP TABLE personal_stock_receipt_items; DROP TABLE personal_device_maintenance; DROP TABLE personal_devices; DELETE FROM community_schema_migrations WHERE version>=26;');
    assert.equal(db.prepare('SELECT MAX(version) AS version FROM community_schema_migrations').get().version, 25);
  });
  await start();
  assert.equal(database((db) => db.prepare('SELECT MAX(version) AS version FROM community_schema_migrations').get().version), Math.max(...MIGRATIONS.map((migration) => migration.version)));
  assert.deepEqual((await request('/v1/me/inventory/snapshot', token)).data, beforeInventory);
  assert.equal((await request('/v1/me/devices/status', token, { devices: [snapshot()] })).status, 200);
  assert.equal((await request(`/v1/me/devices/${KEY_A}/maintenance`, token, maintenance())).status, 201);
  const before = (await request(`/v1/me/devices/${KEY_A}`, token)).data.device;
  await stop();
  await start();
  assert.deepEqual((await request(`/v1/me/device-tags/${before.deviceToken}`, token)).data.device, before);
  assert.equal((await request(`/v1/me/devices/${KEY_A}/maintenance`, token)).data.records.length, 1);
  assert.equal(database((db) => db.prepare('PRAGMA foreign_key_check').all().length), 0);
});

test('PATCH在等待读取请求体期间发生归档，后提交的明确恢复仍会生效', async (t) => {
  const { request, register, delayedBody } = await setup(t);
  const token = await register('device_patch_race');
  await request('/v1/me/devices/status', token, { devices: [snapshot()] });
  const pending = await delayedBody(`/v1/me/devices/${KEY_A}`, token,
    { archived: false, cameraUrl: 'https://camera.example/restored' });
  const archived = await request(`/v1/me/devices/${KEY_A}`, token, { archived: true }, 'PATCH');
  assert.equal(archived.status, 200);
  assert.equal(archived.data.device.archived, true);
  const restored = await pending.finish();
  assert.equal(restored.status, 200);
  assert.equal(restored.data.device.archived, false);
  assert.equal(restored.data.device.cameraUrl, 'https://camera.example/restored');
  assert.notEqual(restored.data.device.deviceToken, archived.data.device.deviceToken);
});

test('维护请求体到达前设备被归档，不得在停用设备上追加新维护记录', async (t) => {
  const { request, register, delayedBody } = await setup(t);
  const token = await register('device_maintenance_race');
  await request('/v1/me/devices/status', token, { devices: [snapshot()] });
  const pending = await delayedBody(`/v1/me/devices/${KEY_A}/maintenance`, token, maintenance(), 'POST');
  assert.equal((await request(`/v1/me/devices/${KEY_A}`, token, { archived: true }, 'PATCH')).status, 200);
  const rejected = await pending.finish();
  assert.equal(rejected.status, 404);
  assert.equal((await request('/v1/me/devices/maintenance', token)).data.records.length, 0);
});
