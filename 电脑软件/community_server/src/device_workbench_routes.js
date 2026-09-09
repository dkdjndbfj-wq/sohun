import { randomBytes } from 'node:crypto';

const KEY = /^[a-f0-9]{64}$/;
const TOKEN = /^[a-f0-9]{32}$/;
const SNAPSHOT_KEYS = new Set(['printerKey', 'name', 'model', 'online', 'state', 'taskName',
  'progress', 'remainingMinutes', 'nozzleTemperature', 'bedTemperature', 'observedAt']);
const EVENT_KEYS = new Set(['eventId', 'printerKey', 'kind', 'notes', 'performedAt', 'nextDueAt', 'faultEventId']);
const KINDS = new Set(['inspection', 'cleaning', 'lubrication', 'belt', 'nozzle', 'hotend', 'repair']);

export async function handleDeviceWorkbenchRequest(ctx) {
  const { database: db, request, response, path, method, url, requestId,
    authenticatedUser, readJson, sendJson, ApiError, checkRateLimit } = ctx;
  if (!path.startsWith('/v1/me/devices') && !path.startsWith('/v1/me/device-tags/')) return false;
  checkRateLimit(request, 'device-workbench', 600, 60_000);
  const owner = authenticatedUser(db, request).id;
  const fail = (message, status = 400, code = 'invalid_device_request') => { throw new ApiError(status, code, message); };
  const object = (value, keys) => {
    if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).some((k) => !keys.has(k))) fail('设备数据包含不支持的字段');
  };
  const text = (value, max, optional = false) => {
    if (optional && value == null) return null;
    if (typeof value !== 'string' || value.length > max || (!optional && !value.trim())) fail('设备信息格式不正确');
    return value.trim();
  };
  const date = (value, optional = false) => {
    if (optional && value == null) return null;
    if (typeof value !== 'string' || !Number.isFinite(Date.parse(value))) fail('设备记录时间不正确');
    const result = new Date(value).toISOString();
    if (result.length !== 24 || Date.parse(result) > Date.now() + 300_000) fail('设备记录时间超出范围');
    return result;
  };
  const number = (value, min, max, integer = false) => {
    if (value == null) return null;
    if (typeof value !== 'number' || !Number.isFinite(value) || value < min || value > max || (integer && !Number.isInteger(value))) fail('设备状态数值不正确');
    return value;
  };
  const owned = (key, archived = false) => {
    if (!KEY.test(key)) fail('设备不存在', 404, 'device_not_found');
    const row = db.prepare('SELECT * FROM personal_devices WHERE user_id=? AND printer_key=?').get(owner, key);
    if (!row || (!archived && row.archived)) fail('设备不存在或已停止共享', 404, 'device_not_found');
    return row;
  };
  const publicDevice = (row) => ({ ...JSON.parse(row.snapshot_json), deviceToken: row.device_token,
    cameraUrl: row.camera_url, archived: row.archived === 1, receivedAt: row.received_at });
  const reply = (body, status = 200) => { sendJson(response, status, body, requestId); return true; };

  if (method === 'GET' && path === '/v1/me/devices') {
    const all = url.searchParams.get('includeArchived') === 'true';
    return reply({ devices: db.prepare(`SELECT * FROM personal_devices WHERE user_id=? ${all ? '' : 'AND archived=0'} ORDER BY printer_key`).all(owner).map(publicDevice) });
  }
  if (method === 'GET' && path === '/v1/me/devices/maintenance') {
    const after = Number(url.searchParams.get('after') ?? 0);
    if (!Number.isSafeInteger(after) || after < 0) fail('维护分页参数不正确');
    const rows = db.prepare('SELECT sequence,event_json FROM personal_device_maintenance WHERE user_id=? AND sequence>? ORDER BY sequence LIMIT 101').all(owner, after);
    const page = rows.slice(0,100);
    return reply({ records: page.map((r) => JSON.parse(r.event_json)), cursor: page.at(-1)?.sequence ?? after, hasMore: rows.length > 100 });
  }
  if (method === 'GET' && path.startsWith('/v1/me/device-tags/')) {
    const token = path.slice('/v1/me/device-tags/'.length);
    if (!TOKEN.test(token)) fail('设备标签无效', 404, 'device_not_found');
    const row = db.prepare('SELECT * FROM personal_devices WHERE user_id=? AND device_token=? AND archived=0').get(owner, token);
    if (!row) fail('当前账号无权查看该设备，或标签已失效', 404, 'device_not_found');
    return reply({ device: publicDevice(row) });
  }
  if (method === 'POST' && path === '/v1/me/devices/status') {
    checkRateLimit(request, `device-status:${owner}`, 30, 60_000);
    const body = await readJson(request);
    object(body, new Set(['devices']));
    if (!Array.isArray(body.devices) || body.devices.length > 200) fail('每批最多同步200台设备');
    const snapshots = body.devices.map((raw) => {
      object(raw, SNAPSHOT_KEYS);
      const printerKey = text(raw.printerKey, 64);
      if (!KEY.test(printerKey) || typeof raw.online !== 'boolean') fail('设备身份或连接状态不正确');
      return { printerKey, name: text(raw.name, 120), model: text(raw.model ?? '', 80, true),
        online: raw.online, state: text(raw.state ?? 'unknown', 30), taskName: text(raw.taskName, 200, true),
        progress: number(raw.progress, 0, 100, true), remainingMinutes: number(raw.remainingMinutes, 0, 100000, true),
        nozzleTemperature: number(raw.nozzleTemperature, -50, 600), bedTemperature: number(raw.bedTemperature, -50, 300),
        observedAt: date(raw.observedAt) };
    });
    if (new Set(snapshots.map((d) => d.printerKey)).size !== snapshots.length) fail('同一批次设备不能重复');
    db.exec('BEGIN IMMEDIATE');
    try {
      let count = db.prepare('SELECT COUNT(*) AS n FROM personal_devices WHERE user_id=?').get(owner).n;
      for (const device of snapshots) {
        const old = db.prepare('SELECT * FROM personal_devices WHERE user_id=? AND printer_key=?').get(owner, device.printerKey);
        if (old?.archived) continue;
        if (old && JSON.parse(old.snapshot_json).observedAt > device.observedAt) continue;
        if (!old && ++count > 200) fail('设备数量已达到200台上限', 409);
        db.prepare(`INSERT INTO personal_devices(user_id,printer_key,device_token,snapshot_json,received_at)
          VALUES (?,?,?,?,?) ON CONFLICT(user_id,printer_key) DO UPDATE SET snapshot_json=excluded.snapshot_json, received_at=excluded.received_at`)
          .run(owner, device.printerKey, old?.device_token ?? randomBytes(16).toString('hex'), JSON.stringify(device), new Date().toISOString());
      }
      db.exec('COMMIT');
    } catch (error) { db.exec('ROLLBACK'); throw error; }
    return reply({ accepted: snapshots.length });
  }
  const match = path.match(/^\/v1\/me\/devices\/([a-f0-9]{64})(?:\/(maintenance|rotate-tag))?$/);
  if (!match) fail('设备接口不存在', 404);
  const [, key, action] = match;
  if (method === 'PATCH' && !action) {
    const body = await readJson(request); object(body, new Set(['cameraUrl', 'archived']));
    const previous = owned(key, true);
    if ('archived' in body && typeof body.archived !== 'boolean') fail('设备共享状态不正确');
    let link;
    if ('cameraUrl' in body) {
      link = text(body.cameraUrl, 1000, true);
      if (link) {
        let camera;
        try { camera = new URL(link); } catch { fail('摄像头链接格式不正确'); }
        if (camera.protocol !== 'https:' || camera.username || camera.password) fail('摄像头入口需要不含用户名密码的 HTTPS 链接');
      }
    }
    db.exec('BEGIN IMMEDIATE');
    try {
      if ('cameraUrl' in body) db.prepare('UPDATE personal_devices SET camera_url=? WHERE user_id=? AND printer_key=?').run(link || null, owner, key);
      if ('archived' in body && body.archived !== (previous.archived === 1)) db.prepare('UPDATE personal_devices SET archived=?,device_token=? WHERE user_id=? AND printer_key=?')
        .run(body.archived ? 1 : 0, randomBytes(16).toString('hex'), owner, key);
      db.exec('COMMIT');
    } catch(error) { db.exec('ROLLBACK'); throw error; }
    return reply({ device: publicDevice(owned(key, true)) });
  }
  const device = owned(key);
  if (method === 'POST' && action === 'rotate-tag') {
    const body = await readJson(request); object(body, new Set());
    owned(key);
    db.prepare('UPDATE personal_devices SET device_token=? WHERE user_id=? AND printer_key=?').run(randomBytes(16).toString('hex'), owner, key);
    return reply({ device: publicDevice(owned(key)) });
  }
  if (method === 'GET' && !action) return reply({ device: publicDevice(device) });
  if (method === 'GET' && action === 'maintenance') {
    const after = Number(url.searchParams.get('after') ?? 0);
    if (!Number.isSafeInteger(after) || after < 0) fail('维护分页参数不正确');
    const rows = db.prepare(`SELECT sequence,event_json FROM personal_device_maintenance WHERE user_id=? AND printer_key=? AND sequence>? ORDER BY sequence LIMIT 101`).all(owner, key, after);
    const page = rows.slice(0, 100);
    return reply({ records: page.map((r) => JSON.parse(r.event_json)), cursor: page.at(-1)?.sequence ?? after, hasMore: rows.length > 100 });
  }
  if (method === 'POST' && action === 'maintenance') {
    checkRateLimit(request, `device-maintenance:${owner}`, 120, 60_000);
    const body = await readJson(request); object(body, EVENT_KEYS);
    owned(key);
    const eventId = text(body.eventId, 80);
    if (!/^[a-zA-Z0-9_-]{8,80}$/.test(eventId) || body.printerKey !== key || !KINDS.has(body.kind)) fail('维护记录身份不正确');
    const event = { eventId, printerKey: key, kind: body.kind, notes: text(body.notes ?? '', 2000, true),
      performedAt: date(body.performedAt), nextDueAt: null, faultEventId: text(body.faultEventId, 80, true) };
    if (body.nextDueAt != null) {
      if (typeof body.nextDueAt !== 'string' || !Number.isFinite(Date.parse(body.nextDueAt))) fail('下次维护日期不正确');
      event.nextDueAt = new Date(body.nextDueAt).toISOString();
      if (event.nextDueAt.length !== 24 || event.nextDueAt < event.performedAt) fail('下次维护日期不能早于本次维护');
    }
    if (event.faultEventId) {
      const fault = db.prepare('SELECT event_json FROM personal_printer_faults WHERE user_id=? AND event_uid=?').get(owner, event.faultEventId);
      if (!fault || JSON.parse(fault.event_json).printerKey !== key) fail('故障记录不属于当前设备');
    }
    const payload = JSON.stringify(event);
    const previous = db.prepare('SELECT printer_key,event_json FROM personal_device_maintenance WHERE user_id=? AND event_uid=?').get(owner, eventId);
    if (previous) {
      if (previous.printer_key !== key || previous.event_json !== payload) fail('已保存的维护记录不能被覆盖', 409);
      return reply({ record: event });
    }
    if (db.prepare('SELECT COUNT(*) AS n FROM personal_device_maintenance WHERE user_id=?').get(owner).n >= 10000) fail('维护记录存储已满', 409);
    db.prepare('INSERT INTO personal_device_maintenance(user_id,printer_key,event_uid,event_json) VALUES (?,?,?,?)').run(owner, key, eventId, payload);
    return reply({ record: event }, 201);
  }
  fail('设备操作不支持', 405);
}
