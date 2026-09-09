import { createHash, randomBytes } from 'node:crypto';

const hash = (text) => createHash('sha256').update(text).digest('hex');
const KEYS = new Set(['eventId', 'printerKey', 'printerName', 'model', 'code', 'kind',
  'severity', 'title', 'message', 'source', 'sourceVersion', 'helpUrl',
  'firstSeenAt', 'lastSeenAt', 'clearedAt', 'readAt']);

export async function handlePrinterFaultRequest(ctx) {
  const { database: db, request, response, path, method, url, requestId,
    authenticatedUser, readJson, sendJson, ApiError, checkRateLimit,
    maxPrinterFaultsPerUser, maxPrinterFaultBytesPerUser } = ctx;
  if (!path.startsWith('/v1/me/printer-faults') && path !== '/v1/notifications/printer-faults') return false;
  // A shared IP bucket also bounds invalid/expired lease lookups. Normal
  // foreground clients poll four times per minute, well below this allowance.
  checkRateLimit(request, 'printer-fault-requests', 600, 60_000);
  const fail = (message, status = 400) => { throw new ApiError(status, 'printer_fault_request', message); };
  const text = (value, max = 200, optional = false) => {
    if (optional && value == null) return null;
    if (typeof value !== 'string' || value.length > max || (!optional && !value.trim())) fail('故障信息格式不正确');
    return value;
  };
  const iso = (value, optional = false) => {
    if (optional && value == null) return null;
    if (typeof value !== 'string' || !Number.isFinite(Date.parse(value))) fail('故障时间不正确');
    const normalized = new Date(value).toISOString();
    if (normalized.length !== 24) fail('故障时间不正确');
    return normalized;
  };
  let userId;
  const readOnly = path === '/v1/notifications/printer-faults';
  if (readOnly) {
    const bearer = request.headers.authorization?.match(/^Bearer ([A-Za-z0-9_-]{40,100})$/)?.[1];
    const lease = bearer && db.prepare(`SELECT l.user_id FROM printer_fault_monitor_leases l
      JOIN users u ON u.id=l.user_id WHERE token_hash=? AND expires_at>? AND u.status='active'`)
      .get(hash(bearer), new Date().toISOString());
    if (!lease) fail('后台提醒登录已过期，请打开手机软件重新连接', 401);
    userId = lease.user_id;
    if (method === 'DELETE') {
      db.prepare('DELETE FROM printer_fault_monitor_leases WHERE token_hash=?').run(hash(bearer));
      sendJson(response, 200, { ok: true }, requestId); return true;
    }
    if (method !== 'GET') fail('提醒凭据只允许读取故障', 403);
  } else {
    userId = authenticatedUser(db, request).id;
  }

  const update = (event) => {
    const sequence = Number(db.prepare('INSERT INTO printer_fault_sequences DEFAULT VALUES').run().lastInsertRowid);
    db.prepare(`INSERT INTO personal_printer_faults(user_id,event_uid,sequence,event_json)
      VALUES (?,?,?,?) ON CONFLICT(user_id,event_uid) DO UPDATE SET
      sequence=excluded.sequence,event_json=excluded.event_json`).run(userId, event.eventId, sequence, JSON.stringify(event));
    // Sequence allocation needs no history; sqlite_sequence keeps monotonicity.
    db.prepare('DELETE FROM printer_fault_sequences WHERE sequence=?').run(sequence);
  };
  if (method === 'GET' && (readOnly || path === '/v1/me/printer-faults')) {
    const after = Number(url.searchParams.get('after') ?? '0');
    if (!Number.isSafeInteger(after) || after < 0) fail('提醒分页参数不正确');
    const rows = db.prepare('SELECT sequence,event_json FROM personal_printer_faults WHERE user_id=? AND sequence>? ORDER BY sequence LIMIT 201')
      .all(userId, after);
    const page = rows.slice(0, 200);
    sendJson(response, 200, { events: page.map((r) => JSON.parse(r.event_json)),
      cursor: page.at(-1)?.sequence ?? after, hasMore: rows.length > 200 }, requestId);
    return true;
  }
  if (method === 'POST' && path === '/v1/me/printer-faults/monitor') {
    checkRateLimit(request, `printer-fault-leases:${userId}`, 10, 60_000);
    const token = randomBytes(32).toString('base64url');
    const expiresAt = new Date(Date.now() + 7 * 24 * 3600_000).toISOString();
    db.prepare('DELETE FROM printer_fault_monitor_leases WHERE expires_at<?').run(new Date().toISOString());
    const existing = db.prepare('SELECT token_hash FROM printer_fault_monitor_leases WHERE user_id=? ORDER BY expires_at DESC').all(userId);
    for (const row of existing.slice(9)) db.prepare('DELETE FROM printer_fault_monitor_leases WHERE token_hash=?').run(row.token_hash);
    db.prepare('INSERT INTO printer_fault_monitor_leases(token_hash,user_id,expires_at) VALUES (?,?,?)').run(hash(token), userId, expiresAt);
    sendJson(response, 200, { token, expiresAt }, requestId); return true;
  }
  if (method === 'POST' && path === '/v1/me/printer-faults/read') {
    checkRateLimit(request, `printer-fault-writes:${userId}`, 120, 60_000);
    const body = await readJson(request);
    if (Object.keys(body).some((k) => k !== 'eventIds') || !Array.isArray(body.eventIds) || body.eventIds.length > 100) fail('已读事件参数不正确');
    const ids = body.eventIds.map((id) => text(id, 80));
    db.exec('BEGIN IMMEDIATE');
    try {
      for (const id of ids) {
        const row = db.prepare('SELECT event_json FROM personal_printer_faults WHERE user_id=? AND event_uid=?').get(userId, id);
        if (!row) continue;
        const event = JSON.parse(row.event_json);
        if (!event.readAt) update({ ...event, readAt: new Date().toISOString() });
      }
      db.exec('COMMIT');
    } catch (e) { db.exec('ROLLBACK'); throw e; }
    sendJson(response, 200, { ok: true }, requestId); return true;
  }
  if (method === 'POST' && path === '/v1/me/printer-faults') {
    checkRateLimit(request, `printer-fault-writes:${userId}`, 120, 60_000);
    const body = await readJson(request);
    if (Object.keys(body).some((k) => k !== 'events') || !Array.isArray(body.events) || body.events.length > 100) fail('每批故障最多 100 条');
    const events = body.events.map((raw) => {
      if (!raw || typeof raw !== 'object' || Array.isArray(raw) || Object.keys(raw).some((k) => !KEYS.has(k))) fail('故障包含不支持的字段');
      const e = { eventId: text(raw.eventId, 80), printerKey: text(raw.printerKey, 128), printerName: text(raw.printerName, 120),
        model: text(raw.model ?? '', 80, true), code: text(raw.code, 80), kind: text(raw.kind, 30), severity: text(raw.severity, 12),
        title: text(raw.title, 200), message: text(raw.message, 8000), source: text(raw.source, 40),
        sourceVersion: text(raw.sourceVersion, 80, true), helpUrl: text(raw.helpUrl, 500, true),
        firstSeenAt: iso(raw.firstSeenAt), lastSeenAt: iso(raw.lastSeenAt), clearedAt: iso(raw.clearedAt, true), readAt: iso(raw.readAt, true) };
      if (!['hms', 'print_error', 'device_state'].includes(e.kind) || !['error', 'warning', 'info'].includes(e.severity)
          || e.lastSeenAt < e.firstSeenAt || (e.clearedAt && e.clearedAt < e.firstSeenAt)) fail('故障状态不正确');
      if (e.helpUrl) {
        let link;
        try { link = new URL(e.helpUrl); } catch { fail('故障帮助链接不正确'); }
        if (link.protocol !== 'https:' || !['e.bambulab.com', 'wiki.bambulab.com'].includes(link.hostname) || link.username || link.password) fail('仅支持拓竹官方帮助链接');
      }
      return e;
    });
    if (events.length === 0) {
      sendJson(response, 200, { accepted: 0 }, requestId); return true;
    }
    db.exec('BEGIN IMMEDIATE');
    try {
      // Reserve the difference between JSON null (4 bytes) and a quoted ISO
      // timestamp (26 bytes), so a full account can still read/clear faults.
      const storageBytes = (event) => Buffer.byteLength(JSON.stringify(event), 'utf8')
        + (event.readAt == null ? 22 : 0) + (event.clearedAt == null ? 22 : 0);
      const usage = db.prepare(`SELECT COUNT(*) AS count, COALESCE(SUM(
        LENGTH(CAST(event_json AS BLOB))
        + CASE WHEN json_extract(event_json, '$.readAt') IS NULL THEN 22 ELSE 0 END
        + CASE WHEN json_extract(event_json, '$.clearedAt') IS NULL THEN 22 ELSE 0 END
      ), 0) AS bytes FROM personal_printer_faults WHERE user_id=?`).get(userId);
      let eventCount = Number(usage.count), eventBytes = Number(usage.bytes);
      const rejectedEventIds = new Set();
      let countExceeded = false;
      for (const e of events) {
        const row = db.prepare('SELECT event_json FROM personal_printer_faults WHERE user_id=? AND event_uid=?').get(userId, e.eventId);
        let previousBytes = 0;
        if (row) {
          const previous = JSON.parse(row.event_json);
          previousBytes = storageBytes(previous);
          if (previous.printerKey !== e.printerKey || previous.code !== e.code || previous.kind !== e.kind || previous.firstSeenAt !== e.firstSeenAt) fail('同一故障事件不能替换设备或代码', 409);
          if (previous.lastSeenAt > e.lastSeenAt || (previous.clearedAt && !e.clearedAt)) continue;
          if (previous.severity !== 'error' && e.severity === 'error') e.readAt = null;
          else e.readAt ??= previous.readAt;
          if (JSON.stringify(e) === JSON.stringify(previous)) continue;
        }
        const nextCount = eventCount + (row ? 0 : 1);
        const byteGrowth = storageBytes(e) - previousBytes;
        if (!row && nextCount > maxPrinterFaultsPerUser) {
          rejectedEventIds.add(e.eventId); countExceeded = true; continue;
        }
        if (byteGrowth > 0 && eventBytes + byteGrowth > maxPrinterFaultBytesPerUser) {
          rejectedEventIds.add(e.eventId); continue;
        }
        update(e);
        eventCount = nextCount;
        eventBytes += byteGrowth;
      }
      if (rejectedEventIds.size > 0) {
        // Still roll back the entire batch. Clients may retain these IDs for
        // later retry and resend the remaining updates without guessing which
        // rows were committed or splitting into up to 100 separate requests.
        throw new ApiError(
          countExceeded ? 409 : 413,
          countExceeded ? 'printer_fault_count_quota_exceeded' : 'printer_fault_storage_quota_exceeded',
          '账号的打印故障同步配额已用尽，请联系支持人员；已有历史不会删除',
          { rejectedEventIds: [...rejectedEventIds] },
        );
      }
      db.exec('COMMIT');
    } catch (e) { db.exec('ROLLBACK'); throw e; }
    sendJson(response, 200, { accepted: events.length }, requestId); return true;
  }
  fail('不支持的提醒操作', 405);
}
