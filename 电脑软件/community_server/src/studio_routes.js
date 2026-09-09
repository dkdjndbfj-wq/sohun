import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';

import {
  renderHomePage,
  renderMessagePage,
  renderPortalLogin,
  renderPublicPage,
} from './public_site.js';

const STUDIO_ROLES = new Set(['owner', 'admin', 'operator']);
const MANAGER_ROLES = new Set(['owner', 'admin']);
const PORTAL_COOKIE = 'sohun_portal_session';
const PORTAL_SESSION_MS = 12 * 60 * 60 * 1000;
const PORTAL_LOCK_MS = 15 * 60 * 1000;
const PORTAL_MAX_ATTEMPTS = 5;
const VIDEO_SESSION_MS = 2 * 60 * 60 * 1000;
const VIDEO_FRAME_MAX_BYTES = 600 * 1024;
const VIDEO_FRAME_MIN_INTERVAL_MS = 700;
const VIDEO_FRAME_STALE_MS = 12_000;
const VIDEO_VIEWER_TTL_MS = 18_000;
const STUDIO_RUNTIME = new WeakMap();
const FARM_STAFF_LOCK_MS = 15 * 60 * 1000;
const FARM_STAFF_MAX_ATTEMPTS = 5;
const SITE_ASSETS = new Map([
  ['/studio/assets/sohun-logo.webp', {
    bytes: readFileSync(new URL('./site_assets/sohun-logo.webp', import.meta.url)),
    contentType: 'image/webp',
  }],
  ['/studio/assets/app-workbench-v2.png', {
    bytes: readFileSync(new URL('./site_assets/app-workbench-v2.png', import.meta.url)),
    contentType: 'image/png',
  }],
]);
const FARM_SUBJECT_TYPES = new Set([
  'company',
  'sole_proprietor',
  'studio',
  'individual_operator',
  'unregistered_studio',
]);
const FARM_ROLE_NAMES = {
  owner: ['管理员', '管理成员并使用全部农场功能'],
  member: ['成员', '与其他成员共享农场数据并使用全部农场功能'],
};
const FARM_ROLE_PERMISSIONS = {
  member: [
    'organization.view', 'organization.update', 'organization.submit_verification',
    'member.view', 'member.create', 'member.update', 'member.disable',
    'member.reset_credential', 'order.read', 'order.manage', 'plate.read',
    'plate.slice', 'job.assign', 'job.execute', 'printer.read', 'printer.control',
    'printer.maintain', 'inventory.read', 'inventory.consume', 'inventory.adjust',
    'customer.manage', 'customer.share', 'finance.view', 'finance.manage',
    'audit.view', 'workspace.snapshot.write',
  ],
};
const FORBIDDEN_SNAPSHOT_KEYS = new Set([
  'password',
  'passwordhash',
  'accesstoken',
  'refreshtoken',
  'accesscode',
  'secret',
  'credential',
  'printerserial',
  'serialnumber',
  'ipaddress',
  'trayuuid',
  'owneraccount',
]);

function cleanText(value, name, ApiError, { min = 1, max = 200 } = {}) {
  const text = String(value ?? '').trim();
  if (text.length < min || text.length > max) {
    throw new ApiError(400, 'invalid_request', `${name} 长度必须为 ${min}-${max} 个字符`);
  }
  return text;
}

function optionalText(value, name, ApiError, { max = 200 } = {}) {
  if (value == null || String(value).trim() === '') return null;
  return cleanText(value, name, ApiError, { min: 1, max });
}

function cleanStringArray(value, name, ApiError, { maxItems = 40, maxLength = 120 } = {}) {
  if (value == null) return [];
  if (!Array.isArray(value) || value.length > maxItems) {
    throw new ApiError(400, 'invalid_request', `${name} 必须是最多 ${maxItems} 项的数组`);
  }
  return [...new Set(value.map((item) => cleanText(item, name, ApiError, { max: maxLength })))];
}

function cleanNonNegativeInteger(value, name, ApiError, fallback = 0) {
  if (value == null || value === '') return fallback;
  const number = Number(value);
  if (!Number.isSafeInteger(number) || number < 0) {
    throw new ApiError(400, 'invalid_request', `${name} 必须是非负整数`);
  }
  return number;
}

function validateFarmLoginName(value, ApiError) {
  const loginName = cleanText(value, '成员登录名', ApiError, { min: 3, max: 32 }).toLowerCase();
  if (!/^[a-z0-9][a-z0-9._-]*$/.test(loginName)) {
    throw new ApiError(400, 'invalid_farm_login_name', '成员登录名只能包含小写字母、数字、点、下划线和短横线');
  }
  return loginName;
}

function validateFarmPassword(value, ApiError) {
  const password = String(value ?? '');
  if (password.length < 12 || password.length > 128
      || !/[a-z]/.test(password) || !/[A-Z]/.test(password)
      || !/\d/.test(password) || !/[^A-Za-z0-9]/.test(password)) {
    throw new ApiError(400, 'weak_farm_password', '密码至少 12 位，并包含大小写字母、数字和符号');
  }
  return password;
}

function generatedInitialPassword() {
  return `Sf!${randomBytes(12).toString('base64url')}9a`;
}

function generatedOrganizationCode(database) {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    const code = `F${randomBytes(5).toString('hex').toUpperCase()}`;
    const exists = database.prepare(
      'SELECT 1 FROM farm_organizations WHERE organization_code = ?',
    ).get(code);
    if (!exists) return code;
  }
  throw new Error('unable_to_generate_farm_organization_code');
}

function tokenHash(token) {
  return createHash('sha256').update(token, 'utf8').digest('hex');
}

function runtimeFor(database) {
  let runtime = STUDIO_RUNTIME.get(database);
  if (!runtime) {
    runtime = {
      frames: new Map(),
      liveStreams: new Map(),
      videoViewers: new Map(),
    };
    STUDIO_RUNTIME.set(database, runtime);
  }
  return runtime;
}

export function buildTencentLiveUrl({
  protocol,
  domain,
  appName,
  streamName,
  key,
  expiresAt,
}) {
  if (!['rtmp', 'webrtc'].includes(protocol)) {
    throw new Error('unsupported Tencent live protocol');
  }
  if (!/^[A-Za-z0-9_-]{1,100}$/.test(streamName)) {
    throw new Error('invalid Tencent live stream name');
  }
  const txTime = Math.floor(expiresAt.getTime() / 1000)
    .toString(16)
    .toUpperCase();
  const txSecret = createHash('md5')
    .update(`${key}${streamName}${txTime}`, 'utf8')
    .digest('hex');
  return `${protocol}://${domain}/${appName}/${streamName}`
    + `?txSecret=${txSecret}&txTime=${txTime}`;
}

function createTencentPushUrl(config, streamName) {
  return buildTencentLiveUrl({
    protocol: 'rtmp',
    domain: config.pushDomain,
    appName: config.appName,
    streamName,
    key: config.pushKey,
    expiresAt: new Date(Date.now() + VIDEO_SESSION_MS),
  });
}

function createTencentPlaybackUrl(config, streamName) {
  return buildTencentLiveUrl({
    protocol: 'webrtc',
    domain: config.playbackDomain,
    appName: config.appName,
    streamName,
    key: config.playbackKey,
    expiresAt: new Date(Date.now() + 5 * 60 * 1000),
  });
}

function createOpenStreamPushUrl(config, streamName, uploadToken) {
  return new URL(
    `${encodeURIComponent(streamName)}?token=${encodeURIComponent(uploadToken)}`,
    config.rtmpBaseUrl,
  ).toString();
}

function createOpenStreamPlaybackUrl(config, streamName) {
  return new URL(
    `${encodeURIComponent(streamName)}/index.m3u8`,
    config.hlsBaseUrl,
  ).toString();
}

function videoViewerKey(workspaceId, orderId, workOrderId) {
  return `${workspaceId}\u0000${orderId}\u0000${workOrderId}`;
}

function pruneVideoViewers(runtime, now = Date.now()) {
  for (const [key, demand] of runtime.videoViewers) {
    for (const [sessionId, lastSeenAt] of demand.viewers) {
      if (now - lastSeenAt > VIDEO_VIEWER_TTL_MS) {
        demand.viewers.delete(sessionId);
      }
    }
    if (demand.viewers.size === 0) runtime.videoViewers.delete(key);
  }
}

function registerVideoViewer(runtime, {
  workspaceId,
  orderId,
  workOrderId,
  portalSessionId,
}) {
  const now = Date.now();
  pruneVideoViewers(runtime, now);
  const key = videoViewerKey(workspaceId, orderId, workOrderId);
  let demand = runtime.videoViewers.get(key);
  if (!demand) {
    demand = {
      workspaceId,
      orderId,
      workOrderId,
      viewers: new Map(),
    };
    runtime.videoViewers.set(key, demand);
  }
  demand.viewers.set(portalSessionId, now);
  return demand.viewers.size;
}

function activeVideoDemand(runtime, workspaceId) {
  const now = Date.now();
  pruneVideoViewers(runtime, now);
  return [...runtime.videoViewers.values()]
    .filter((item) => item.workspaceId === workspaceId)
    .map((item) => ({
      orderId: item.orderId,
      workOrderId: item.workOrderId,
      viewerCount: item.viewers.size,
      expiresAt: new Date(
        Math.max(...item.viewers.values()) + VIDEO_VIEWER_TTL_MS,
      ).toISOString(),
    }));
}

function parseCookies(request) {
  const result = new Map();
  for (const part of String(request.headers.cookie ?? '').split(';')) {
    const separator = part.indexOf('=');
    if (separator <= 0) continue;
    const name = part.slice(0, separator).trim();
    const value = part.slice(separator + 1).trim();
    if (!name) continue;
    try {
      result.set(name, decodeURIComponent(value));
    } catch {
      // Ignore malformed client cookies and treat the request as unauthenticated.
    }
  }
  return result;
}

function bearerToken(request) {
  const match = String(request.headers.authorization ?? '').match(/^Bearer\s+(.+)$/i);
  return match?.[1]?.trim() ?? null;
}

async function readBody(request, maxBytes) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > maxBytes) {
      throw new Error('request_body_too_large');
    }
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}

function isHttpsRequest(request) {
  return Boolean(request.socket?.encrypted)
    || String(request.headers['x-forwarded-proto'] ?? '').split(',')[0].trim() === 'https';
}

function portalSession(database, request, shareId, nowIso) {
  const token = parseCookies(request).get(PORTAL_COOKIE);
  if (!token) return null;
  const session = database.prepare(`
    SELECT * FROM studio_portal_sessions
    WHERE token_hash = ? AND share_id = ? AND expires_at > ?
  `).get(tokenHash(token), shareId, nowIso());
  if (!session) return null;
  database.prepare(
    'UPDATE studio_portal_sessions SET last_seen_at = ? WHERE id = ?',
  ).run(nowIso(), session.id);
  return session;
}

function portalSessionForRequest(database, request, nowIso) {
  const token = parseCookies(request).get(PORTAL_COOKIE);
  if (!token) return null;
  const session = database.prepare(`
    SELECT sessions.*
    FROM studio_portal_sessions sessions
    JOIN studio_share_links links ON links.id = sessions.share_id
    WHERE sessions.token_hash = ? AND sessions.expires_at > ?
      AND links.active = 1
      AND (links.expires_at IS NULL OR links.expires_at > ?)
    ORDER BY sessions.last_seen_at DESC
    LIMIT 1
  `).get(tokenHash(token), nowIso(), nowIso());
  if (!session) return null;
  database.prepare(
    'UPDATE studio_portal_sessions SET last_seen_at = ? WHERE id = ?',
  ).run(nowIso(), session.id);
  return session;
}

function normalizedKey(value) {
  return String(value).replaceAll('_', '').replaceAll('-', '').toLowerCase();
}

function assertSnapshotSafe(value, ApiError, depth = 0) {
  if (depth > 12) {
    throw new ApiError(400, 'invalid_studio_snapshot', '工作室数据嵌套层级过深');
  }
  if (Array.isArray(value)) {
    if (value.length > 5000) {
      throw new ApiError(413, 'studio_snapshot_too_large', '工作室记录数量过多');
    }
    for (const item of value) assertSnapshotSafe(item, ApiError, depth + 1);
    return;
  }
  if (value == null || typeof value !== 'object') return;
  for (const [key, child] of Object.entries(value)) {
    if (FORBIDDEN_SNAPSHOT_KEYS.has(normalizedKey(key))) {
      throw new ApiError(
        400,
        'sensitive_studio_field',
        `工作室同步数据不能包含敏感字段：${key}`,
      );
    }
    assertSnapshotSafe(child, ApiError, depth + 1);
  }
}

function assertSnapshotBusinessInvariants(snapshot, ApiError) {
  const strict = Number(snapshot.schemaVersion ?? 0) >= 2;
  const fail = (message) => {
    throw new ApiError(400, 'invalid_studio_snapshot', message);
  };
  const list = (key) => {
    const value = snapshot[key];
    if (value == null) return [];
    if (!Array.isArray(value)) fail(`${key} 必须是数组`);
    return value;
  };
  const finite = (value, label, { min = 0, integer = false } = {}) => {
    if (value == null && !strict) return min;
    const number = Number(value);
    if (!Number.isFinite(number) || number < min || (integer && !Number.isSafeInteger(number))) {
      fail(`${label} 数值无效`);
    }
    return number;
  };
  const anyFinite = (value, label) => {
    const number = Number(value);
    if (!Number.isFinite(number)) fail(`${label} 数值无效`);
    return number;
  };
  const oneOf = (value, label, allowed) => {
    if (value == null && !strict) return;
    if (!allowed.has(String(value ?? ''))) fail(`${label} 状态无效`);
  };
  const uniqueIds = (key) => {
    const seen = new Set();
    for (const item of list(key)) {
      if (!item || typeof item !== 'object' || Array.isArray(item)) fail(`${key} 记录无效`);
      const id = String(key === 'inventoryItems' ? item.uid ?? '' : item.id ?? '').trim();
      if (!id) fail(`${key} 记录缺少稳定标识`);
      if (seen.has(id)) fail(`${key} 存在重复 id`);
      seen.add(id);
    }
  };
  for (const key of [
    'customers', 'orders', 'workOrders', 'workOrderMaterials', 'printAttempts',
    'productionPackages', 'productionPlates', 'orderItems', 'quotes',
    'inventoryItems', 'inventoryEvents', 'inventoryBatches',
    'inventoryBatchItems', 'activityEvents',
  ]) uniqueIds(key);

  for (const item of list('inventoryItems')) {
    const total = finite(item.totalGrams, 'inventoryItems.totalGrams');
    const remaining = finite(item.remainingGrams, 'inventoryItems.remainingGrams');
    if (item.totalGrams != null && item.remainingGrams != null && remaining > total + 0.0001) {
      fail('库存余量不能大于累计入库量');
    }
  }
  for (const item of list('inventoryBatches')) {
    finite(item.rollCount, 'inventoryBatches.rollCount', { min: 1, integer: true });
    finite(item.totalGrams, 'inventoryBatches.totalGrams', { min: 0.0001 });
  }
  for (const item of list('inventoryBatchItems')) {
    finite(item.rollCount, 'inventoryBatchItems.rollCount', { min: 1, integer: true });
    finite(item.gramsPerRoll, 'inventoryBatchItems.gramsPerRoll', { min: 0.0001 });
    finite(item.unitCost, 'inventoryBatchItems.unitCost');
    if (!String(item.batchId ?? '').trim() || !String(item.consumableUid ?? '').trim()) {
      fail('批次明细缺少批次或库存引用');
    }
  }
  for (const item of list('workOrders')) {
    const quantity = finite(item.quantity, 'workOrders.quantity', {
      min: strict ? 1 : 0,
      integer: true,
    });
    const completed = finite(item.completedQuantity, 'workOrders.completedQuantity', { integer: true });
    if (completed > quantity) fail('工单完成数量不能大于计划数量');
    finite(item.materialCostSnapshot, 'workOrders.materialCostSnapshot');
    finite(item.quotedPriceSnapshot, 'workOrders.quotedPriceSnapshot');
    oneOf(item.status, 'workOrders.status', new Set([
      'queued', 'assigned', 'printing', 'paused', 'completed', 'failed', 'cancelled',
    ]));
  }
  for (const item of list('workOrderMaterials')) {
    const estimated = finite(item.estimatedGrams, 'workOrderMaterials.estimatedGrams');
    const reserved = finite(item.reservedGrams, 'workOrderMaterials.reservedGrams');
    finite(item.consumedGrams, 'workOrderMaterials.consumedGrams');
    if (reserved > estimated + 0.0001) fail('工单耗材预留量不能大于计划量');
    oneOf(item.status, 'workOrderMaterials.status', new Set([
      'unallocated', 'reserved', 'settled', 'released',
    ]));
  }
  for (const item of list('printAttempts')) {
    finite(item.attemptNo, 'printAttempts.attemptNo', { min: 1, integer: true });
    finite(item.consumedGrams, 'printAttempts.consumedGrams');
    finite(item.materialCost, 'printAttempts.materialCost');
    if (item.progressPercent != null) {
      const progress = finite(item.progressPercent, 'printAttempts.progressPercent', { integer: true });
      if (progress > 100) fail('打印进度不能大于 100');
    }
    oneOf(item.outcome, 'printAttempts.outcome', new Set([
      'completed', 'failed', 'stopped', 'quality_rejected', 'accounting_review',
    ]));
  }
  for (const item of list('productionPlates')) {
    finite(item.requiredRuns, 'productionPlates.requiredRuns', { min: 1, integer: true });
    finite(item.estimatedSeconds, 'productionPlates.estimatedSeconds', { integer: true });
    finite(item.estimatedGrams, 'productionPlates.estimatedGrams');
  }
  for (const item of list('orderItems')) {
    finite(item.perRunQuantity, 'orderItems.perRunQuantity', { min: 1, integer: true });
    finite(item.requiredQuantity, 'orderItems.requiredQuantity', { min: 1, integer: true });
  }
  for (const item of list('orders')) {
    finite(item.totalPrice, 'orders.totalPrice');
    oneOf(item.status, 'orders.status', new Set([
      'draft', 'confirmed', 'production', 'completed', 'delivered', 'cancelled',
    ]));
  }
  for (const item of list('quotes')) {
    for (const field of [
      'estimatedGrams', 'materialCostPerKgSnapshot', 'machineHours',
      'machineRatePerHour', 'laborHours', 'laborRatePerHour',
      'electricityCost', 'packagingCost', 'riskPercent', 'markupPercent',
      'totalCost', 'quotedPrice',
    ]) finite(item[field], `quotes.${field}`);
    oneOf(item.status, 'quotes.status', new Set(['draft', 'sent', 'accepted', 'rejected', 'expired']));
  }
  for (const item of list('inventoryEvents')) {
    anyFinite(item.deltaGrams, 'inventoryEvents.deltaGrams');
    oneOf(item.type, 'inventoryEvents.type', new Set([
      'receive', 'adjustment', 'reserve', 'consume', 'returnToStock',
    ]));
  }
  if (strict) {
    const ids = (key, field = 'id') => new Set(list(key).map((item) => String(item[field] ?? '')));
    const orders = ids('orders');
    const packages = ids('productionPackages');
    const plates = ids('productionPlates');
    const workOrders = ids('workOrders');
    const batches = ids('inventoryBatches');
    const inventory = ids('inventoryItems', 'uid');
    for (const item of list('productionPackages')) {
      if (!orders.has(String(item.orderId ?? ''))) fail('生产包引用了不存在的订单');
    }
    for (const item of list('productionPlates')) {
      if (!orders.has(String(item.orderId ?? '')) || !packages.has(String(item.packageId ?? ''))) {
        fail('生产盘引用了不存在的订单或生产包');
      }
    }
    for (const item of list('workOrders')) {
      if (!orders.has(String(item.orderId ?? ''))) fail('工单引用了不存在的订单');
      if (item.productionPlateId != null && !plates.has(String(item.productionPlateId))) {
        fail('工单引用了不存在的生产盘');
      }
    }
    for (const item of list('workOrderMaterials')) {
      if (!workOrders.has(String(item.workOrderId ?? ''))
          || !plates.has(String(item.productionPlateId ?? ''))) {
        fail('工单耗材引用了不存在的工单或生产盘');
      }
      if (item.consumableUid != null && !inventory.has(String(item.consumableUid))) {
        fail('工单耗材引用了不存在的库存');
      }
    }
    for (const item of list('printAttempts')) {
      if (!workOrders.has(String(item.workOrderId ?? ''))) fail('打印尝试引用了不存在的工单');
    }
    for (const item of list('inventoryBatchItems')) {
      if (!batches.has(String(item.batchId ?? ''))
          || !inventory.has(String(item.consumableUid ?? ''))) {
        fail('批次明细引用了不存在的批次或库存');
      }
    }
  }
  for (const item of list('deletedEntities')) {
    if (!String(item?.entityType ?? '').trim() || !String(item?.entityId ?? '').trim()) {
      fail('删除墓碑缺少实体类型或 id');
    }
    if (!Number.isFinite(Date.parse(String(item.deletedAt ?? '')))) {
      fail('删除墓碑时间无效');
    }
  }
}

function membership(database, user, workspaceId) {
  const member = database.prepare(`
    SELECT * FROM studio_members
    WHERE workspace_id = ? AND active = 1
      AND (user_id = ? OR lower(email) = lower(?))
    LIMIT 1
  `).get(workspaceId, user.id, user.email);
  if (member && !member.user_id) {
    database.prepare('UPDATE studio_members SET user_id = ? WHERE id = ?')
      .run(user.id, member.id);
    member.user_id = user.id;
  }
  return member ?? null;
}

function requireMembership(database, user, workspaceId, ApiError, roles = STUDIO_ROLES) {
  const member = membership(database, user, workspaceId);
  if (!member || !roles.has(member.role)) {
    throw new ApiError(403, 'studio_permission_denied', '没有此工作室操作权限');
  }
  return member;
}

function audit(database, workspaceId, userId, action, subjectId, nowIso) {
  database.prepare(`
    INSERT INTO studio_audit_events(id, workspace_id, actor_user_id, action, subject_id, created_at)
    VALUES (?, ?, ?, ?, ?, ?)
  `).run(randomUUID(), workspaceId, userId, action, subjectId ?? null, nowIso());
}

function ensureFarmOrganization(database, workspaceId, ownerUserId, displayName, timestamp) {
  let organization = database.prepare(
    'SELECT * FROM farm_organizations WHERE id = ?',
  ).get(workspaceId);
  if (!organization) {
    database.prepare(`
      INSERT INTO farm_organizations(
        id, organization_code, owner_user_id, display_name, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?)
    `).run(
      workspaceId,
      generatedOrganizationCode(database),
      ownerUserId,
      displayName,
      timestamp,
      timestamp,
    );
    organization = database.prepare(
      'SELECT * FROM farm_organizations WHERE id = ?',
    ).get(workspaceId);
  }

  database.prepare(`
    INSERT OR IGNORE INTO auth_identity_realms(user_id, realm, organization_id, created_at)
    VALUES (?, 'farm_owner', ?, ?)
  `).run(ownerUserId, workspaceId, timestamp);
  database.prepare(`
    INSERT OR IGNORE INTO farm_security_policies(organization_id, updated_by, updated_at)
    VALUES (?, ?, ?)
  `).run(workspaceId, ownerUserId, timestamp);

  const roleIdByCode = new Map();
  for (const [code, [roleName, description]] of Object.entries(FARM_ROLE_NAMES)) {
    const roleId = `system:${workspaceId}:${code}`;
    roleIdByCode.set(code, roleId);
    database.prepare(`
      INSERT OR IGNORE INTO farm_roles(
        id, organization_id, code, display_name, description,
        system_role, active, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, 1, 1, ?, ?)
    `).run(roleId, workspaceId, code, roleName, description, timestamp, timestamp);
    const insertPermission = database.prepare(`
      INSERT OR IGNORE INTO farm_role_permissions(role_id, permission_code)
      VALUES (?, ?)
    `);
    for (const permission of FARM_ROLE_PERMISSIONS[code] ?? []) {
      insertPermission.run(roleId, permission);
    }
  }

  const ownerMember = database.prepare(`
    SELECT * FROM studio_members
    WHERE workspace_id = ? AND role = 'owner'
    ORDER BY created_at ASC LIMIT 1
  `).get(workspaceId);
  if (ownerMember) {
    database.prepare(`
      UPDATE studio_members
      SET primary_role_code = 'owner', account_status = 'active'
      WHERE id = ?
    `).run(ownerMember.id);
    database.prepare(`
      INSERT OR IGNORE INTO farm_member_role_assignments(
        member_id, role_id, assigned_by, assigned_at
      ) VALUES (?, ?, ?, ?)
    `).run(ownerMember.id, roleIdByCode.get('owner'), ownerUserId, timestamp);
    database.prepare(`
      INSERT OR IGNORE INTO farm_member_scopes(
        id, member_id, scope_type, scope_id, created_at
      ) VALUES (?, ?, 'organization', NULL, ?)
    `).run(`scope:${ownerMember.id}:organization`, ownerMember.id, timestamp);
  }
  return organization;
}

function hasFarmPermission(database, member, permissionCode) {
  if (!member || !member.active || member.account_status === 'deactivated') return false;
  if (member.role === 'owner' || member.primary_role_code === 'owner') return true;
  // 农场没有岗位权限分工。所有正常成员都可使用日常功能，只有组织所有权
  // 转移仍属于主账号的身份边界，不能由成员账号执行。
  return permissionCode !== 'organization.transfer_ownership';
}

function requireFarmPermission(database, user, workspaceId, permissionCode, ApiError) {
  const member = membership(database, user, workspaceId);
  if (!member || member.account_status === 'pending_activation') {
    throw new ApiError(
      403,
      member?.account_status === 'pending_activation'
        ? 'farm_password_change_required'
        : 'farm_permission_denied',
      member?.account_status === 'pending_activation'
        ? '首次登录后必须先修改初始密码'
        : '没有此农场操作权限',
    );
  }
  if (!hasFarmPermission(database, member, permissionCode)) {
    throw new ApiError(403, 'farm_permission_denied', `缺少权限：${permissionCode}`);
  }
  return member;
}

function farmAudit(
  database,
  request,
  requestId,
  organizationId,
  actor,
  action,
  resourceType,
  resourceId,
  nowIso,
  { result = 'success', before = null, after = null } = {},
) {
  const member = actor
    ? database.prepare(`
        SELECT id, role, display_name FROM studio_members
        WHERE workspace_id = ? AND user_id = ? LIMIT 1
      `).get(organizationId, actor.id)
    : null;
  const resourceMember = !member && resourceType === 'member' && resourceId
    ? database.prepare(`
        SELECT id, role, display_name FROM studio_members
        WHERE workspace_id = ? AND id = ? LIMIT 1
      `).get(organizationId, resourceId)
    : null;
  const actorUser = actor
    ? database.prepare('SELECT display_name FROM users WHERE id = ?').get(actor.id)
    : null;
  const actorDisplayName = actorUser?.display_name
    ?? member?.display_name
    ?? resourceMember?.display_name
    ?? '系统';
  const actorIdentity = member
    ? member.role === 'owner' ? 'administrator' : 'member'
    : actor ? 'administrator' : resourceMember ? 'member' : 'system';
  database.prepare(`
    INSERT INTO farm_audit_logs(
      id, organization_id, actor_user_id, actor_member_id, client_event_id,
      actor_display_name, actor_identity, action, resource_type, resource_id,
      result, summary, before_json, after_json, ip_address, user_agent,
      request_id, created_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `).run(
    randomUUID(),
    organizationId,
    actor?.id ?? null,
    member?.id ?? resourceMember?.id ?? null,
    null,
    actorDisplayName,
    actorIdentity,
    action,
    resourceType ?? null,
    resourceId ?? null,
    result,
    null,
    before == null ? null : JSON.stringify(before),
    after == null ? null : JSON.stringify(after),
    String(request.socket?.remoteAddress ?? '').slice(0, 100) || null,
    String(request.headers['user-agent'] ?? '').slice(0, 500) || null,
    requestId,
    nowIso(),
  );
}

function ingestSnapshotActivityEvents(database, organizationId, snapshot, user, timestamp) {
  const events = Array.isArray(snapshot?.activityEvents) ? snapshot.activityEvents : [];
  const authenticatedMember = database.prepare(`
    SELECT id, user_id, role, display_name FROM studio_members
    WHERE workspace_id = ? AND user_id = ? AND active = 1 LIMIT 1
  `).get(organizationId, user.id);
  const actorDisplayName = authenticatedMember?.display_name ?? user.display_name ?? '管理员';
  const actorIdentity = authenticatedMember?.role === 'owner' ? 'administrator' : 'member';
  const insert = database.prepare(`
    INSERT OR IGNORE INTO farm_audit_logs(
      id, organization_id, actor_user_id, actor_member_id, client_event_id,
      actor_display_name, actor_identity, action, resource_type, resource_id,
      result, summary, before_json, after_json, ip_address, user_agent,
      request_id, created_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'success', ?, NULL, NULL, NULL, NULL, NULL, ?)
  `);
  for (const event of events) {
    if (!event || typeof event !== 'object' || Array.isArray(event)) continue;
    const clientEventId = String(event.id ?? '').trim().slice(0, 120);
    const action = String(event.actionCode ?? '').trim().slice(0, 120);
    const resourceType = String(event.entityType ?? '').trim().slice(0, 80);
    const resourceId = String(event.entityId ?? '').trim().slice(0, 160);
    if (!clientEventId || !action || !resourceType || !resourceId) continue;
    const summary = String(event.summary ?? '执行农场操作').trim().slice(0, 1000)
      || '执行农场操作';
    insert.run(
      randomUUID(),
      organizationId,
      user.id,
      authenticatedMember?.id ?? null,
      clientEventId,
      actorDisplayName,
      actorIdentity,
      action,
      resourceType,
      resourceId,
      summary,
      timestamp,
    );
  }
}

function parsedArray(value) {
  try {
    const decoded = JSON.parse(value ?? '[]');
    return Array.isArray(decoded) ? decoded : [];
  } catch {
    return [];
  }
}

function farmOrganizationJson(row) {
  return {
    id: row.id,
    organizationCode: row.organization_code,
    displayName: row.display_name,
    legalName: row.legal_name,
    subjectType: row.subject_type,
    registrationNumber: row.registration_number,
    contactName: row.contact_name,
    contactPhone: row.contact_phone,
    contactEmail: row.contact_email,
    region: row.region,
    businessAddress: row.business_address,
    serviceArea: row.service_area,
    printerCount: row.printer_count,
    staffCount: row.staff_count,
    locationCount: row.location_count,
    printerModels: parsedArray(row.printer_models_json),
    materials: parsedArray(row.materials_json),
    orderTypes: parsedArray(row.order_types_json),
    invoiceCapability: Boolean(row.invoice_capability),
    verificationStatus: row.verification_status,
    verificationLevel: row.verification_level,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function parseSnapshot(row) {
  if (!row?.payload_json) return {};
  try {
    const value = JSON.parse(row.payload_json);
    return value && typeof value === 'object' && !Array.isArray(value) ? value : {};
  } catch {
    return {};
  }
}

function publicShareFromLink(link) {
  const snapshot = parseSnapshot(link);
  const orders = Array.isArray(snapshot.orders) ? snapshot.orders : [];
  const workOrders = Array.isArray(snapshot.workOrders) ? snapshot.workOrders : [];
  const customers = Array.isArray(snapshot.customers) ? snapshot.customers : [];
  const productionPlates = Array.isArray(snapshot.productionPlates) ? snapshot.productionPlates : [];
  const orderItems = Array.isArray(snapshot.orderItems) ? snapshot.orderItems : [];
  const order = orders.find((item) => item?.id === link.order_id);
  if (!order) return null;
  const work = workOrders.filter((item) => item?.orderId === link.order_id);
  const customer = customers.find((item) => item?.id === order.customerId);
  const plates = productionPlates.filter((item) => item?.orderId === link.order_id);
  const completedRunsByPlate = new Map();
  for (const item of work) {
    if (!item?.productionPlateId) continue;
    completedRunsByPlate.set(
      item.productionPlateId,
      (completedRunsByPlate.get(item.productionPlateId) ?? 0)
        + Math.max(0, Number(item.completedQuantity) || 0),
    );
  }
  const total = work.reduce((sum, item) => sum + Math.max(0, Number(item.quantity) || 0), 0);
  const completed = work.reduce(
    (sum, item) => sum + Math.max(0, Number(item.completedQuantity) || 0),
    0,
  );
  return {
    link,
    snapshot,
    data: {
      workspaceName: link.workspace_name,
      customerName: customer?.name ?? null,
      order: {
        id: order.id,
        orderNo: order.orderNo,
        title: order.title,
        status: order.status,
        dueAt: order.dueAt == null ? null : String(order.dueAt).slice(0, 10),
        note: order.publicNote ?? null,
        videoEnabled: order.portalVideoEnabled !== false,
      },
      workOrders: work.map((item) => ({
        id: item.id,
        title: item.title,
        quantity: Number(item.quantity) || 0,
        completedQuantity: Number(item.completedQuantity) || 0,
        status: item.status,
        printerName: item.printerName ?? null,
        progressPercent: Math.max(0, Math.min(100, Number(item.progressPercent) || 0)),
        currentLayer: Math.max(0, Number(item.currentLayer) || 0),
        totalLayers: Math.max(0, Number(item.totalLayers) || 0),
        remainingMinutes: Math.max(0, Number(item.remainingMinutes) || 0),
        activePrint: item.activePrint === true,
        updatedAt: item.updatedAt ?? null,
      })),
      items: orderItems
        .filter((item) => item?.orderId === link.order_id)
        .map((item) => {
          const required = Math.max(0, Number(item.requiredQuantity) || 0);
          const perRun = Math.max(1, Number(item.perRunQuantity) || 1);
          const completedRuns = completedRunsByPlate.get(item.plateId) ?? 0;
          return {
            id: item.id,
            name: item.name,
            requiredQuantity: required,
            completedQuantity: Math.min(required, completedRuns * perRun),
          };
        }),
      plateCount: plates.length,
      completion: total <= 0 ? 0 : Math.min(1, completed / total),
      updatedAt: link.updated_at,
      revision: link.revision,
    },
  };
}

function publicShare(database, token, nowIso) {
  const link = database.prepare(`
    SELECT links.*, workspaces.name AS workspace_name, snapshots.payload_json,
           snapshots.revision, snapshots.updated_at
    FROM studio_share_links links
    JOIN studio_workspaces workspaces ON workspaces.id = links.workspace_id
    JOIN studio_snapshots snapshots ON snapshots.workspace_id = links.workspace_id
    WHERE links.token_hash = ? AND links.active = 1
      AND (links.expires_at IS NULL OR links.expires_at > ?)
  `).get(tokenHash(token), nowIso()) ?? database.prepare(`
    SELECT links.*, workspaces.name AS workspace_name, snapshots.payload_json,
           snapshots.revision, snapshots.updated_at
    FROM studio_share_links links
    JOIN studio_workspaces workspaces ON workspaces.id = links.workspace_id
    JOIN studio_snapshots snapshots ON snapshots.workspace_id = links.workspace_id
    WHERE links.id = ? AND links.active = 1
      AND (links.expires_at IS NULL OR links.expires_at > ?)
  `).get(token, nowIso());
  return link ? publicShareFromLink(link) : null;
}

function publicShareById(database, shareId, nowIso) {
  const link = database.prepare(`
    SELECT links.*, workspaces.name AS workspace_name, snapshots.payload_json,
           snapshots.revision, snapshots.updated_at
    FROM studio_share_links links
    JOIN studio_workspaces workspaces ON workspaces.id = links.workspace_id
    JOIN studio_snapshots snapshots ON snapshots.workspace_id = links.workspace_id
    WHERE links.id = ? AND links.active = 1
      AND (links.expires_at IS NULL OR links.expires_at > ?)
  `).get(shareId, nowIso());
  return link ? publicShareFromLink(link) : null;
}

function publicSharesByOrderNo(database, orderNo, nowIso) {
  const normalized = orderNo.trim().toLocaleUpperCase('en-US');
  const links = database.prepare(`
    SELECT links.*, workspaces.name AS workspace_name, snapshots.payload_json,
           snapshots.revision, snapshots.updated_at
    FROM studio_share_links links
    JOIN studio_workspaces workspaces ON workspaces.id = links.workspace_id
    JOIN studio_snapshots snapshots ON snapshots.workspace_id = links.workspace_id
    WHERE links.active = 1 AND links.password_hash IS NOT NULL
      AND (links.expires_at IS NULL OR links.expires_at > ?)
    ORDER BY links.created_at DESC
  `).all(nowIso());
  return links
    .map(publicShareFromLink)
    .filter(Boolean)
    .filter((share) => String(share.data.order.orderNo ?? '')
      .trim().toLocaleUpperCase('en-US') === normalized);
}

function sendHtml(response, status, html, requestId, { nonce = null } = {}) {
  const data = Buffer.from(html, 'utf8');
  const scriptPolicy = nonce
    ? `; script-src 'nonce-${nonce}' https://tcsdk.com https://cdn.jsdelivr.net; connect-src 'self' https: wss:; media-src https: blob:; font-src 'self' https://tcsdk.com; worker-src blob:`
    : '';
  response.writeHead(status, {
    'Content-Type': 'text/html; charset=utf-8',
    'Content-Length': data.length,
    'Cache-Control': 'no-store',
    'Content-Security-Policy': `default-src 'none'; style-src 'unsafe-inline' https://tcsdk.com; img-src 'self' blob: data: https://tcsdk.com${scriptPolicy}; base-uri 'none'; form-action 'self'; frame-ancestors 'none'`,
    'Referrer-Policy': 'no-referrer',
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY',
    'X-Request-Id': requestId,
  });
  response.end(data);
}

function sendSiteAsset(response, asset, requestId) {
  response.writeHead(200, {
    'Content-Type': asset.contentType,
    'Content-Length': asset.bytes.length,
    'Cache-Control': 'public, max-age=604800, immutable',
    'X-Content-Type-Options': 'nosniff',
    'X-Request-Id': requestId,
  });
  response.end(asset.bytes);
}

function issuePortalSession({
  database,
  request,
  response,
  requestId,
  share,
  nowIso,
  createToken,
  location = '/studio/order',
}) {
  const sessionToken = createToken();
  const sessionId = randomUUID();
  const timestamp = nowIso();
  const shareExpiry = share.link.expires_at
    ? Date.parse(share.link.expires_at)
    : Number.POSITIVE_INFINITY;
  const expiresAt = new Date(
    Math.min(Date.now() + PORTAL_SESSION_MS, shareExpiry),
  ).toISOString();
  database.prepare(`
    INSERT INTO studio_portal_sessions(
      id, share_id, token_hash, expires_at, created_at, last_seen_at
    ) VALUES (?, ?, ?, ?, ?, ?)
  `).run(
    sessionId,
    share.link.id,
    tokenHash(sessionToken),
    expiresAt,
    timestamp,
    timestamp,
  );
  database.prepare(`
    UPDATE studio_share_links
    SET failed_attempts = 0, locked_until = NULL
    WHERE id = ?
  `).run(share.link.id);
  const secure = isHttpsRequest(request) ? '; Secure' : '';
  response.writeHead(303, {
    Location: location,
    'Set-Cookie': `${PORTAL_COOKIE}=${encodeURIComponent(sessionToken)}; Path=/; HttpOnly; SameSite=Strict; Max-Age=${Math.floor(PORTAL_SESSION_MS / 1000)}${secure}`,
    'Cache-Control': 'no-store',
    'X-Request-Id': requestId,
  });
  response.end();
}

function registerPortalFailure(database, share) {
  const attempts = Number(share.link.failed_attempts ?? 0) + 1;
  const lockedUntil = attempts >= PORTAL_MAX_ATTEMPTS
    ? new Date(Date.now() + PORTAL_LOCK_MS).toISOString()
    : null;
  database.prepare(`
    UPDATE studio_share_links
    SET failed_attempts = ?, locked_until = ?
    WHERE id = ?
  `).run(lockedUntil ? 0 : attempts, lockedUntil, share.link.id);
  return lockedUntil;
}

function shareForPortalSession(database, request, nowIso) {
  const session = portalSessionForRequest(database, request, nowIso);
  if (!session) return null;
  return publicShareById(database, session.share_id, nowIso);
}

function sendPublicVideoFrame({
  database,
  request,
  response,
  requestId,
  share,
  portalSessionId,
  nowIso,
}) {
  if (!share.data.order.videoEnabled) {
    response.writeHead(204, {
      'Cache-Control': 'no-store',
      'X-Request-Id': requestId,
    });
    response.end();
    return;
  }
  const requestedWorkOrderId = new URL(
    request.url ?? '/',
    'http://localhost',
  ).searchParams.get('workOrderId');
  const activeWorkOrders = new Set(
    share.data.workOrders
      .filter((item) => item.status === 'printing' && item.activePrint)
      .map((item) => item.id),
  );
  if (requestedWorkOrderId && !activeWorkOrders.has(requestedWorkOrderId)) {
    response.writeHead(204, {
      'Cache-Control': 'no-store',
      'X-Request-Id': requestId,
    });
    response.end();
    return;
  }
  const watchedWorkOrderId = requestedWorkOrderId ?? activeWorkOrders.values().next().value;
  if (watchedWorkOrderId) {
    registerVideoViewer(runtimeFor(database), {
      workspaceId: share.link.workspace_id,
      orderId: share.link.order_id,
      workOrderId: watchedWorkOrderId,
      portalSessionId,
    });
  }
  const sessions = database.prepare(`
    SELECT * FROM studio_video_sessions
    WHERE workspace_id = ? AND order_id = ? AND active = 1 AND expires_at > ?
    ORDER BY created_at DESC
  `).all(share.link.workspace_id, share.link.order_id, nowIso());
  const runtime = runtimeFor(database);
  let selected = null;
  for (const session of sessions) {
    if (!activeWorkOrders.has(session.work_order_id)) continue;
    if (requestedWorkOrderId && session.work_order_id !== requestedWorkOrderId) {
      continue;
    }
    const frame = runtime.frames.get(session.id);
    if (!frame || Date.now() - frame.receivedAt > VIDEO_FRAME_STALE_MS) continue;
    selected = frame;
    break;
  }
  if (!selected) {
    response.writeHead(204, {
      'Cache-Control': 'no-store',
      'X-Request-Id': requestId,
    });
    response.end();
    return;
  }
  response.writeHead(200, {
    'Content-Type': 'image/jpeg',
    'Content-Length': selected.bytes.length,
    'Cache-Control': 'no-store, max-age=0',
    'X-Content-Type-Options': 'nosniff',
    'X-Request-Id': requestId,
  });
  response.end(selected.bytes);
}

function sendPublicLivePlayback({
  database,
  request,
  response,
  requestId,
  share,
  portalSessionId,
  nowIso,
  studioLive,
  studioOpenStream,
  sendJson,
}) {
  if (!share.data.order.videoEnabled) {
    response.writeHead(204, {
      'Cache-Control': 'no-store',
      'X-Request-Id': requestId,
    });
    response.end();
    return;
  }
  const requestedWorkOrderId = new URL(
    request.url ?? '/',
    'http://localhost',
  ).searchParams.get('workOrderId');
  const activeWorkOrders = new Set(
    share.data.workOrders
      .filter((item) => item.status === 'printing' && item.activePrint)
      .map((item) => item.id),
  );
  if (requestedWorkOrderId && !activeWorkOrders.has(requestedWorkOrderId)) {
    response.writeHead(204, {
      'Cache-Control': 'no-store',
      'X-Request-Id': requestId,
    });
    response.end();
    return;
  }
  const watchedWorkOrderId = requestedWorkOrderId
    ?? activeWorkOrders.values().next().value;
  if (!watchedWorkOrderId) {
    response.writeHead(204, {
      'Cache-Control': 'no-store',
      'X-Request-Id': requestId,
    });
    response.end();
    return;
  }
  const runtime = runtimeFor(database);
  registerVideoViewer(runtime, {
    workspaceId: share.link.workspace_id,
    orderId: share.link.order_id,
    workOrderId: watchedWorkOrderId,
    portalSessionId,
  });
  const sessions = database.prepare(`
    SELECT * FROM studio_video_sessions
    WHERE workspace_id = ? AND order_id = ? AND work_order_id = ?
      AND active = 1 AND expires_at > ?
    ORDER BY created_at DESC
  `).all(
    share.link.workspace_id,
    share.link.order_id,
    watchedWorkOrderId,
    nowIso(),
  );
  const session = sessions.find((item) => runtime.liveStreams.has(item.id));
  const stream = session && runtime.liveStreams.get(session.id);
  if (!session || !stream) {
    response.writeHead(204, {
      'Cache-Control': 'no-store',
      'X-Request-Id': requestId,
    });
    response.end();
    return;
  }
  const isTencent = Boolean(studioLive);
  sendJson(response, 200, {
    transport: isTencent ? 'webrtc' : 'hls',
    url: isTencent
      ? createTencentPlaybackUrl(studioLive, stream.streamName)
      : createOpenStreamPlaybackUrl(studioOpenStream, stream.streamName),
    ...(isTencent ? { licenseUrl: studioLive.licenseUrl } : {}),
    sessionId: session.id,
    workOrderId: watchedWorkOrderId,
    publicPrinterName: session.public_printer_name,
    expiresInSeconds: 300,
  }, requestId);
}

function memberRoleCodes(database, row) {
  return row.role === 'owner' || row.primary_role_code === 'owner'
    ? ['owner']
    : ['member'];
}

function memberJson(row, database) {
  const roleCodes = memberRoleCodes(database, row);
  return {
    id: row.id,
    email: row.login_name ? row.recovery_email : row.email,
    loginName: row.login_name,
    employeeNo: row.employee_no,
    phone: row.phone,
    recoveryEmail: row.recovery_email,
    displayName: row.display_name,
    role: row.role,
    primaryRoleCode: roleCodes[0],
    roleCodes,
    accountStatus: row.account_status,
    mustChangePassword: Boolean(row.must_change_password),
    active: Boolean(row.active),
    lastLoginAt: row.last_login_at,
    deactivatedAt: row.deactivated_at,
    createdAt: row.created_at,
  };
}

export async function handleStudioRequest({
  database,
  request,
  response,
  method,
  path,
  requestId,
  ApiError,
  authenticatedUser,
  verifiedAuthenticatedUser,
  readJson,
  sendJson,
  nowIso,
  createToken,
  issueSession,
  checkRateLimit,
  requireAdmin,
  passwordHash,
  passwordMatches,
  studioLive,
  studioOpenStream,
}) {
  const decodePathSegment = (value) => {
    try {
      return decodeURIComponent(value);
    } catch {
      throw new ApiError(400, 'invalid_path', '请求路径不正确');
    }
  };

  if (method === 'POST' && path === '/internal/mediamtx-auth') {
    const remoteAddress = String(request.socket?.remoteAddress ?? '');
    if (!['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(remoteAddress)) {
      sendJson(response, 403, { error: { code: 'media_auth_local_only' } }, requestId);
      return true;
    }
    if (!studioOpenStream) {
      sendJson(response, 403, { error: { code: 'media_server_disabled' } }, requestId);
      return true;
    }
    const body = await readJson(request);
    const action = String(body.action ?? '');
    const streamPath = String(body.path ?? '').trim().replace(/^\/+/, '');
    if (!['publish', 'read', 'playback'].includes(action) || !streamPath) {
      sendJson(response, 401, { error: { code: 'media_auth_denied' } }, requestId);
      return true;
    }
    const runtime = runtimeFor(database);
    const streamEntry = [...runtime.liveStreams.values()].find((item) => (
      item.transport === 'open' && item.streamName === streamPath
    ));
    // The runtime map is keyed by session ID; resolve it without exposing IDs
    // to MediaMTX, which only knows the random stream path.
    const sessionId = streamEntry
      ? [...runtime.liveStreams.entries()].find(([, item]) => item === streamEntry)?.[0]
      : null;
    const activeSession = sessionId && database.prepare(`
      SELECT active, expires_at FROM studio_video_sessions
      WHERE id = ? AND active = 1 AND expires_at > ?
    `).get(sessionId, nowIso());
    if (!streamEntry || !activeSession) {
      sendJson(response, 401, { error: { code: 'media_auth_denied' } }, requestId);
      return true;
    }
    if (action === 'publish') {
      const query = new URLSearchParams(String(body.query ?? '').replace(/^\?/, ''));
      const token = query.get('token');
      if (!token || tokenHash(token) !== streamEntry.uploadTokenHash) {
        sendJson(response, 401, { error: { code: 'media_publish_denied' } }, requestId);
        return true;
      }
    }
    sendJson(response, 200, { ok: true }, requestId);
    return true;
  }

  const siteAsset = SITE_ASSETS.get(path);
  if (method === 'GET' && siteAsset) {
    sendSiteAsset(response, siteAsset, requestId);
    return true;
  }

  if (method === 'GET' && (path === '' || path === '/')) {
    sendHtml(response, 200, renderHomePage(), requestId);
    return true;
  }

  if (method === 'POST' && path === '/studio/order-login') {
    checkRateLimit(request, 'studio-portal-order-login', 20, 15 * 60_000);
    let body;
    try {
      body = await readBody(request, 16 * 1024);
    } catch {
      throw new ApiError(413, 'portal_login_too_large', '登录请求过大');
    }
    const form = new URLSearchParams(body.toString('utf8'));
    const orderNo = String(form.get('orderNo') ?? '').trim();
    const password = String(form.get('password') ?? '');
    if (orderNo.length < 1 || orderNo.length > 100 || password.length > 64) {
      sendHtml(response, 400, renderHomePage({
        error: '请输入有效的订单号和访问密码。',
        orderNo: orderNo.slice(0, 100),
      }), requestId);
      return true;
    }
    const shares = publicSharesByOrderNo(database, orderNo, nowIso);
    const now = Date.now();
    const unlocked = shares.filter((share) => (
      !share.link.locked_until || Date.parse(share.link.locked_until) <= now
    ));
    const share = unlocked.find((candidate) => (
      passwordMatches(password, candidate.link.password_hash)
    ));
    if (!share) {
      for (const candidate of unlocked) registerPortalFailure(database, candidate);
      sendHtml(response, 401, renderHomePage({
        error: '订单号或访问密码不正确。',
        orderNo,
      }), requestId);
      return true;
    }
    issuePortalSession({
      database,
      request,
      response,
      requestId,
      share,
      nowIso,
      createToken,
    });
    return true;
  }

  if (method === 'GET' && path === '/studio/order') {
    const share = shareForPortalSession(database, request, nowIso);
    if (!share) {
      response.writeHead(303, {
        Location: '/#order-access',
        'Cache-Control': 'no-store',
        'X-Request-Id': requestId,
      });
      response.end();
      return true;
    }
    const nonce = randomBytes(18).toString('base64url');
    sendHtml(
      response,
      200,
      renderPublicPage(
        share.data,
        nonce,
        studioLive || studioOpenStream
          ? {
              videoUrl: '/v1/studio/public/order/video-playback',
              liveVideo: true,
              liveTransport: studioLive ? 'tencent' : 'hls',
            }
          : undefined,
      ),
      requestId,
      { nonce },
    );
    return true;
  }

  if (method === 'GET' && path === '/v1/studio/public/order') {
    const share = shareForPortalSession(database, request, nowIso);
    if (!share) {
      throw new ApiError(401, 'studio_portal_auth_required', '请输入订单号和访问密码');
    }
    sendJson(response, 200, share.data, requestId);
    return true;
  }

  if (method === 'GET' && path === '/v1/studio/public/order/events') {
    const session = portalSessionForRequest(database, request, nowIso);
    const share = session && publicShareById(database, session.share_id, nowIso);
    if (!share) {
      throw new ApiError(401, 'studio_portal_auth_required', '请输入订单号和访问密码');
    }
    response.writeHead(200, {
      'Content-Type': 'text/event-stream; charset=utf-8',
      'Cache-Control': 'no-store',
      Connection: 'keep-alive',
      'X-Accel-Buffering': 'no',
      'X-Request-Id': requestId,
    });
    let revision = -1;
    const push = () => {
      const latest = publicShareById(database, session.share_id, nowIso);
      if (!latest) {
        response.write('event: revoked\ndata: {}\n\n');
        response.end();
        return false;
      }
      if (latest.data.revision !== revision) {
        revision = latest.data.revision;
        response.write(`data: ${JSON.stringify(latest.data)}\n\n`);
      } else {
        response.write(': keepalive\n\n');
      }
      return true;
    };
    push();
    const timer = setInterval(() => {
      if (!push()) clearInterval(timer);
    }, 2500);
    request.on('close', () => clearInterval(timer));
    return true;
  }

  if (method === 'GET' && path === '/v1/studio/public/order/video.jpg') {
    const session = portalSessionForRequest(database, request, nowIso);
    const share = session && publicShareById(database, session.share_id, nowIso);
    if (!share) {
      throw new ApiError(401, 'studio_portal_auth_required', '请输入订单号和访问密码');
    }
    sendPublicVideoFrame({
      database,
      request,
      response,
      requestId,
      share,
      portalSessionId: session.id,
      nowIso,
    });
    return true;
  }

  if (
    (studioLive || studioOpenStream)
    && method === 'GET'
    && path === '/v1/studio/public/order/video-playback'
  ) {
    const session = portalSessionForRequest(database, request, nowIso);
    const share = session && publicShareById(database, session.share_id, nowIso);
    if (!share) {
      throw new ApiError(401, 'studio_portal_auth_required', '请输入订单号和访问密码');
    }
    sendPublicLivePlayback({
      database,
      request,
      response,
      requestId,
      share,
      portalSessionId: session.id,
      nowIso,
      studioLive,
      studioOpenStream,
      sendJson,
    });
    return true;
  }

  const publicHtml = path.match(/^\/studio\/share\/([^/]+)$/);
  if (method === 'GET' && publicHtml) {
    const token = decodePathSegment(publicHtml[1]);
    const share = publicShare(database, token, nowIso);
    if (!share) {
      sendHtml(response, 404, renderMessagePage(
        '链接不可用',
        '此进度链接不存在、已撤销或已过期。',
      ), requestId);
    } else if (!share.link.password_hash) {
      sendHtml(response, 410, renderMessagePage(
        '链接需要更新',
        '此旧链接没有访问密码，请联系服务方重新生成客户进度链接。',
      ), requestId);
    } else if (!portalSession(database, request, share.link.id, nowIso)) {
      sendHtml(response, 200, renderPortalLogin(share, token), requestId);
    } else {
      const nonce = randomBytes(18).toString('base64url');
      sendHtml(
        response,
        200,
        renderPublicPage(
          share.data,
          nonce,
        studioLive || studioOpenStream
          ? {
              videoUrl: '/v1/studio/public/order/video-playback',
              liveVideo: true,
              liveTransport: studioLive ? 'tencent' : 'hls',
            }
            : undefined,
        ),
        requestId,
        { nonce },
      );
    }
    return true;
  }

  const publicLogin = path.match(/^\/studio\/share\/([^/]+)\/login$/);
  if (method === 'POST' && publicLogin) {
    const token = decodePathSegment(publicLogin[1]);
    const share = publicShare(database, token, nowIso);
    if (!share || !share.link.password_hash) {
      sendHtml(response, 404, renderMessagePage(
        '链接不可用',
        '此进度链接不存在、已撤销或已过期。',
      ), requestId);
      return true;
    }
    if (share.link.locked_until && Date.parse(share.link.locked_until) > Date.now()) {
      sendHtml(response, 429, renderPortalLogin(share, token, {
        error: '密码尝试次数过多，请 15 分钟后再试。',
      }), requestId);
      return true;
    }
    let body;
    try {
      body = await readBody(request, 16 * 1024);
    } catch {
      throw new ApiError(413, 'portal_login_too_large', '登录请求过大');
    }
    const form = new URLSearchParams(body.toString('utf8'));
    const password = String(form.get('password') ?? '');
    if (!passwordMatches(password, share.link.password_hash)) {
      const lockedUntil = registerPortalFailure(database, share);
      const refreshed = publicShare(database, token, nowIso) ?? share;
      sendHtml(response, 401, renderPortalLogin(refreshed, token, {
        error: lockedUntil ? '密码尝试次数过多，请 15 分钟后再试。' : '访问密码不正确。',
      }), requestId);
      return true;
    }
    issuePortalSession({
      database,
      request,
      response,
      requestId,
      share,
      nowIso,
      createToken,
    });
    return true;
  }

  const publicApi = path.match(/^\/v1\/studio\/public\/orders\/([^/]+)$/);
  if (method === 'GET' && publicApi) {
    const share = publicShare(database, decodePathSegment(publicApi[1]), nowIso);
    if (!share) throw new ApiError(404, 'studio_share_not_found', '进度链接不存在、已撤销或已过期');
    if (!portalSession(database, request, share.link.id, nowIso)) {
      throw new ApiError(401, 'studio_portal_auth_required', '请输入客户进度页密码');
    }
    sendJson(response, 200, share.data, requestId);
    return true;
  }

  const publicEvents = path.match(/^\/v1\/studio\/public\/orders\/([^/]+)\/events$/);
  if (method === 'GET' && publicEvents) {
    const token = decodePathSegment(publicEvents[1]);
    const share = publicShare(database, token, nowIso);
    if (!share) throw new ApiError(404, 'studio_share_not_found', '进度链接不存在、已撤销或已过期');
    if (!portalSession(database, request, share.link.id, nowIso)) {
      throw new ApiError(401, 'studio_portal_auth_required', '请输入客户进度页密码');
    }
    response.writeHead(200, {
      'Content-Type': 'text/event-stream; charset=utf-8',
      'Cache-Control': 'no-store',
      Connection: 'keep-alive',
      'X-Accel-Buffering': 'no',
      'X-Request-Id': requestId,
    });
    let revision = -1;
    const push = () => {
      const latest = publicShare(database, token, nowIso);
      if (!latest) {
        response.write('event: revoked\ndata: {}\n\n');
        response.end();
        return false;
      }
      if (latest.data.revision !== revision) {
        revision = latest.data.revision;
        response.write(`data: ${JSON.stringify(latest.data)}\n\n`);
      } else {
        response.write(': keepalive\n\n');
      }
      return true;
    };
    push();
    const timer = setInterval(() => {
      if (!push()) clearInterval(timer);
    }, 2500);
    request.on('close', () => clearInterval(timer));
    return true;
  }

  const publicVideo = path.match(/^\/v1\/studio\/public\/orders\/([^/]+)\/video\.jpg$/);
  const publicPlayback = path.match(
    /^\/v1\/studio\/public\/orders\/([^/]+)\/video-playback$/,
  );
  if ((studioLive || studioOpenStream) && method === 'GET' && publicPlayback) {
    const token = decodePathSegment(publicPlayback[1]);
    const share = publicShare(database, token, nowIso);
    if (!share) {
      throw new ApiError(404, 'studio_share_not_found', '进度链接不存在、已撤销或已过期');
    }
    const session = portalSession(database, request, share.link.id, nowIso);
    if (!session) {
      throw new ApiError(401, 'studio_portal_auth_required', '请输入客户进度页密码');
    }
    sendPublicLivePlayback({
      database,
      request,
      response,
      requestId,
      share,
      portalSessionId: session.id,
      nowIso,
      studioLive,
      studioOpenStream,
      sendJson,
    });
    return true;
  }

  if (method === 'GET' && publicVideo) {
    const token = decodePathSegment(publicVideo[1]);
    const share = publicShare(database, token, nowIso);
    if (!share) throw new ApiError(404, 'studio_share_not_found', '进度链接不存在、已撤销或已过期');
    const session = portalSession(database, request, share.link.id, nowIso);
    if (!session) {
      throw new ApiError(401, 'studio_portal_auth_required', '请输入客户进度页密码');
    }
    sendPublicVideoFrame({
      database,
      request,
      response,
      requestId,
      share,
      portalSessionId: session.id,
      nowIso,
    });
    return true;
  }

  const videoUplink = path.match(/^\/v1\/studio\/video-uplink\/([^/]+)\/frame$/);
  if (method === 'PUT' && videoUplink) {
    const sessionId = decodePathSegment(videoUplink[1]);
    const uploadToken = bearerToken(request);
    const session = uploadToken && database.prepare(`
      SELECT * FROM studio_video_sessions
      WHERE id = ? AND upload_token_hash = ? AND active = 1 AND expires_at > ?
    `).get(sessionId, tokenHash(uploadToken), nowIso());
    if (!session) throw new ApiError(401, 'studio_video_uplink_denied', '视频上行会话无效或已过期');
    if (String(request.headers['content-type'] ?? '').split(';')[0].trim() !== 'image/jpeg') {
      throw new ApiError(415, 'studio_video_frame_type', '视频帧必须为 JPEG');
    }
    const runtime = runtimeFor(database);
    const previous = runtime.frames.get(sessionId);
    if (previous && Date.now() - previous.receivedAt < VIDEO_FRAME_MIN_INTERVAL_MS) {
      throw new ApiError(429, 'studio_video_frame_rate', '视频帧上传过于频繁');
    }
    let bytes;
    try {
      bytes = await readBody(request, VIDEO_FRAME_MAX_BYTES);
    } catch {
      throw new ApiError(413, 'studio_video_frame_too_large', '视频帧超过大小限制');
    }
    if (bytes.length < 4 || bytes[0] !== 0xff || bytes[1] !== 0xd8 || bytes.at(-2) !== 0xff || bytes.at(-1) !== 0xd9) {
      throw new ApiError(400, 'studio_video_frame_invalid', '视频帧不是完整 JPEG');
    }
    const timestamp = nowIso();
    runtime.frames.set(sessionId, { bytes, receivedAt: Date.now() });
    database.prepare(
      'UPDATE studio_video_sessions SET last_frame_at = ? WHERE id = ?',
    ).run(timestamp, sessionId);
    response.writeHead(204, { 'Cache-Control': 'no-store', 'X-Request-Id': requestId });
    response.end();
    return true;
  }

  if (method === 'GET' && path === '/v1/admin/farm/verification-submissions') {
    requireAdmin(request);
    const rows = database.prepare(`
      SELECT submissions.*, organizations.organization_code,
             organizations.display_name AS organization_name,
             organizations.subject_type
      FROM farm_verification_submissions submissions
      JOIN farm_organizations organizations
        ON organizations.id = submissions.organization_id
      WHERE submissions.status IN ('submitted', 'under_review', 'needs_information')
      ORDER BY submissions.submitted_at ASC
      LIMIT 200
    `).all();
    sendJson(response, 200, {
      items: rows.map((row) => ({
        id: row.id,
        organizationId: row.organization_id,
        organizationCode: row.organization_code,
        organizationName: row.organization_name,
        subjectType: row.subject_type,
        submissionNumber: row.submission_number,
        status: row.status,
        profile: JSON.parse(row.profile_json),
        documentManifest: parsedArray(row.document_manifest_json),
        submittedAt: row.submitted_at,
      })),
    }, requestId);
    return true;
  }

  const adminVerificationRoute = path.match(
    /^\/v1\/admin\/farm\/verification-submissions\/([^/]+)$/,
  );
  if (adminVerificationRoute && method === 'PATCH') {
    requireAdmin(request);
    const submissionId = decodePathSegment(adminVerificationRoute[1]);
    const submission = database.prepare(`
      SELECT * FROM farm_verification_submissions WHERE id = ?
    `).get(submissionId);
    if (!submission) {
      throw new ApiError(404, 'farm_verification_submission_not_found', '审核提交不存在');
    }
    const body = await readJson(request);
    const decision = cleanText(body.decision, '审核决定', ApiError, { max: 40 });
    const decisionMap = {
      approved: ['approved', 'verified'],
      needs_information: ['needs_information', 'needs_information'],
      rejected: ['rejected', 'rejected'],
    };
    const mapped = decisionMap[decision];
    if (!mapped) {
      throw new ApiError(400, 'invalid_farm_verification_decision', '审核决定不正确');
    }
    const reviewNote = optionalText(body.reviewNote, '审核说明', ApiError, { max: 1000 });
    if (decision !== 'approved' && reviewNote == null) {
      throw new ApiError(400, 'farm_verification_note_required', '需要补充或拒绝时必须填写审核说明');
    }
    const verificationLevel = decision === 'approved'
      ? Math.min(3, Math.max(1, cleanNonNegativeInteger(
          body.verificationLevel,
          '认证等级',
          ApiError,
          1,
        )))
      : 0;
    const timestamp = nowIso();
    database.exec('BEGIN IMMEDIATE');
    try {
      database.prepare(`
        UPDATE farm_verification_submissions
        SET status = ?, review_note = ?, reviewed_at = ? WHERE id = ?
      `).run(mapped[0], reviewNote, timestamp, submissionId);
      database.prepare(`
        UPDATE farm_organizations
        SET verification_status = ?,
            verification_level = CASE WHEN ? = 'verified' THEN ? ELSE verification_level END,
            updated_at = ?
        WHERE id = ?
      `).run(
        mapped[1],
        mapped[1],
        verificationLevel,
        timestamp,
        submission.organization_id,
      );
      farmAudit(
        database,
        request,
        requestId,
        submission.organization_id,
        null,
        `organization.verification_${decision}`,
        'verification_submission',
        submissionId,
        nowIso,
        { after: { decision, reviewNote, verificationLevel } },
      );
      database.exec('COMMIT');
    } catch (error) {
      database.exec('ROLLBACK');
      throw error;
    }
    sendJson(response, 200, {
      submission: {
        id: submissionId,
        status: mapped[0],
        reviewNote,
        reviewedAt: timestamp,
      },
      organizationStatus: mapped[1],
      verificationLevel,
    }, requestId);
    return true;
  }

  if (method === 'POST' && path === '/v1/farm/auth/staff-login') {
    const body = await readJson(request);
    const organizationCode = cleanText(
      body.organizationCode,
      '农场编号',
      ApiError,
      { min: 4, max: 32 },
    ).toUpperCase();
    const loginName = validateFarmLoginName(body.loginName, ApiError);
    const password = String(body.password ?? '');
    checkRateLimit(
      request,
      `farm-staff-login:${organizationCode}:${loginName}`,
      10,
      15 * 60_000,
    );
    const credential = database.prepare(`
      SELECT credentials.*, organizations.organization_code,
             organizations.display_name AS organization_name,
             members.display_name, members.employee_no, members.phone,
             members.account_status, members.primary_role_code, members.active,
             users.email, users.handle, users.status AS user_status,
             users.created_at AS user_created_at, users.updated_at AS user_updated_at
      FROM farm_staff_credentials credentials
      JOIN farm_organizations organizations
        ON organizations.id = credentials.organization_id
      JOIN studio_members members ON members.id = credentials.member_id
      JOIN users ON users.id = credentials.user_id
      WHERE organizations.organization_code = ? AND credentials.login_name = ?
      LIMIT 1
    `).get(organizationCode, loginName);
    const timestamp = nowIso();
    const locked = credential?.locked_until
      && Date.parse(credential.locked_until) > Date.now();
    if (locked) {
      throw new ApiError(423, 'farm_staff_login_locked', '登录失败次数过多，请稍后再试或联系管理员重置密码');
    }
    if (!credential || !passwordMatches(password, credential.password_hash)) {
      if (credential) {
        const attempts = Number(credential.failed_attempts ?? 0) + 1;
        const lockedUntil = attempts >= FARM_STAFF_MAX_ATTEMPTS
          ? new Date(Date.now() + FARM_STAFF_LOCK_MS).toISOString()
          : null;
        database.prepare(`
          UPDATE farm_staff_credentials
          SET failed_attempts = ?, locked_until = ?, updated_at = ?
          WHERE member_id = ?
        `).run(attempts, lockedUntil, timestamp, credential.member_id);
        farmAudit(
          database,
          request,
          requestId,
          credential.organization_id,
          null,
          'staff.login_failed',
          'member',
          credential.member_id,
          nowIso,
          { result: 'denied' },
        );
      }
      throw new ApiError(401, 'invalid_farm_staff_credentials', '农场编号、成员账号或密码不正确');
    }
    if (!credential.active || credential.account_status === 'deactivated'
        || credential.user_status !== 'active') {
      throw new ApiError(403, 'farm_staff_disabled', '成员账号已停用，请联系管理员');
    }
    database.prepare(`
      UPDATE farm_staff_credentials
      SET failed_attempts = 0, locked_until = NULL, last_login_at = ?, updated_at = ?
      WHERE member_id = ?
    `).run(timestamp, timestamp, credential.member_id);
    database.prepare(`
      UPDATE studio_members SET last_login_at = ? WHERE id = ?
    `).run(timestamp, credential.member_id);
    database.prepare(`
      UPDATE users SET last_login_at = ?, updated_at = ? WHERE id = ?
    `).run(timestamp, timestamp, credential.user_id);
    const session = issueSession(database, credential.user_id);
    const roleCodes = memberRoleCodes(database, {
      id: credential.member_id,
      primary_role_code: credential.primary_role_code,
      role: credential.primary_role_code === 'farm_admin' ? 'admin' : 'operator',
    });
    farmAudit(
      database,
      request,
      requestId,
      credential.organization_id,
      { id: credential.user_id },
      'staff.login',
      'member',
      credential.member_id,
      nowIso,
    );
    sendJson(response, 200, {
      user: {
        id: credential.user_id,
        email: credential.email,
        handle: credential.handle,
        displayName: credential.display_name,
        emailVerified: true,
        createdAt: credential.user_created_at,
        updatedAt: credential.user_updated_at,
      },
      organization: {
        id: credential.organization_id,
        organizationCode: credential.organization_code,
        displayName: credential.organization_name,
      },
      staff: {
        id: credential.member_id,
        loginName: credential.login_name,
        employeeNo: credential.employee_no,
        displayName: credential.display_name,
        primaryRoleCode: credential.primary_role_code,
        roleCodes,
        accountStatus: credential.account_status,
      },
      mustChangePassword: Boolean(credential.must_change_password),
      ...session,
    }, requestId);
    return true;
  }

  if (method === 'POST' && path === '/v1/farm/auth/change-initial-password') {
    const user = verifiedAuthenticatedUser(database, request);
    const body = await readJson(request);
    const currentPassword = String(body.currentPassword ?? '');
    const newPassword = validateFarmPassword(body.newPassword, ApiError);
    const credential = database.prepare(`
      SELECT credentials.*, members.account_status
      FROM farm_staff_credentials credentials
      JOIN studio_members members ON members.id = credentials.member_id
      WHERE credentials.user_id = ?
    `).get(user.id);
    if (!credential || !passwordMatches(currentPassword, credential.password_hash)) {
      throw new ApiError(400, 'invalid_password', '当前初始密码不正确');
    }
    const timestamp = nowIso();
    const encoded = passwordHash(newPassword);
    database.exec('BEGIN IMMEDIATE');
    try {
      database.prepare(`
        UPDATE farm_staff_credentials
        SET password_hash = ?, must_change_password = 0,
            password_changed_at = ?, updated_at = ?
        WHERE member_id = ?
      `).run(encoded, timestamp, timestamp, credential.member_id);
      database.prepare(`
        UPDATE studio_members
        SET must_change_password = 0, account_status = 'active'
        WHERE id = ?
      `).run(credential.member_id);
      database.prepare(`
        UPDATE users SET password_hash = ?, updated_at = ? WHERE id = ?
      `).run(encoded, timestamp, user.id);
      database.prepare(`
        UPDATE sessions SET revoked_at = ?
        WHERE user_id = ? AND revoked_at IS NULL
      `).run(timestamp, user.id);
      farmAudit(
        database,
        request,
        requestId,
        credential.organization_id,
        user,
        'staff.initial_password_changed',
        'member',
        credential.member_id,
        nowIso,
      );
      database.exec('COMMIT');
    } catch (error) {
      database.exec('ROLLBACK');
      throw error;
    }
    sendJson(response, 200, {
      ok: true,
      mustChangePassword: false,
      ...issueSession(database, user.id),
    }, requestId);
    return true;
  }

  if (path.startsWith('/v1/farm/')) {
    const user = verifiedAuthenticatedUser(database, request);
    const organizationRoute = path.match(/^\/v1\/farm\/organizations\/([^/]+)$/);
    if (organizationRoute) {
      const organizationId = decodePathSegment(organizationRoute[1]);
      const permission = method === 'GET' ? 'organization.view' : 'organization.update';
      requireFarmPermission(database, user, organizationId, permission, ApiError);
      const organization = database.prepare(
        'SELECT * FROM farm_organizations WHERE id = ?',
      ).get(organizationId);
      if (!organization) throw new ApiError(404, 'farm_organization_not_found', '农场不存在');
      if (method === 'GET') {
        const roles = database.prepare(`
          SELECT code, display_name, description, system_role
          FROM farm_roles WHERE organization_id = ? AND active = 1
          ORDER BY system_role DESC, created_at ASC
        `).all(organizationId).map((row) => ({
          code: row.code,
          displayName: row.display_name,
          description: row.description,
          systemRole: Boolean(row.system_role),
        }));
        sendJson(response, 200, {
          organization: farmOrganizationJson(organization),
          roles,
        }, requestId);
        return true;
      }
      if (method === 'PATCH') {
        const body = await readJson(request);
        const subjectType = body.subjectType == null
          ? organization.subject_type
          : cleanText(body.subjectType, '主体类型', ApiError, { max: 40 });
        if (!FARM_SUBJECT_TYPES.has(subjectType)) {
          throw new ApiError(400, 'invalid_farm_subject_type', '不支持的经营主体类型');
        }
        const displayName = body.displayName == null
          ? organization.display_name
          : cleanText(body.displayName, '农场名称', ApiError, { max: 120 });
        const legalName = body.legalName === undefined
          ? organization.legal_name
          : optionalText(body.legalName, '主体法定名称', ApiError, { max: 160 });
        const registrationNumber = body.registrationNumber === undefined
          ? organization.registration_number
          : optionalText(body.registrationNumber, '统一社会信用代码', ApiError, { max: 80 });
        const contactName = body.contactName === undefined
          ? organization.contact_name
          : optionalText(body.contactName, '负责人姓名', ApiError, { max: 80 });
        const contactPhone = body.contactPhone === undefined
          ? organization.contact_phone
          : optionalText(body.contactPhone, '负责人电话', ApiError, { max: 40 });
        const contactEmail = body.contactEmail === undefined
          ? organization.contact_email
          : optionalText(body.contactEmail, '负责人邮箱', ApiError, { max: 320 });
        const region = body.region === undefined
          ? organization.region
          : optionalText(body.region, '经营地区', ApiError, { max: 120 });
        const businessAddress = body.businessAddress === undefined
          ? organization.business_address
          : optionalText(body.businessAddress, '经营地址', ApiError, { max: 300 });
        const serviceArea = body.serviceArea === undefined
          ? organization.service_area
          : optionalText(body.serviceArea, '服务区域', ApiError, { max: 300 });
        const printerModels = body.printerModels === undefined
          ? parsedArray(organization.printer_models_json)
          : cleanStringArray(body.printerModels, '打印机型号', ApiError);
        const materials = body.materials === undefined
          ? parsedArray(organization.materials_json)
          : cleanStringArray(body.materials, '主要材料', ApiError);
        const orderTypes = body.orderTypes === undefined
          ? parsedArray(organization.order_types_json)
          : cleanStringArray(body.orderTypes, '接单类型', ApiError);
        const timestamp = nowIso();
        database.prepare(`
          UPDATE farm_organizations SET
            display_name = ?, legal_name = ?, subject_type = ?,
            registration_number = ?, contact_name = ?, contact_phone = ?,
            contact_email = ?, region = ?, business_address = ?, service_area = ?,
            printer_count = ?, staff_count = ?, location_count = ?,
            printer_models_json = ?, materials_json = ?, order_types_json = ?,
            invoice_capability = ?,
            verification_status = CASE
              WHEN verification_status IN ('under_review', 'needs_information', 'rejected')
                THEN 'pending_submission'
              ELSE verification_status
            END,
            updated_at = ?
          WHERE id = ?
        `).run(
          displayName,
          legalName,
          subjectType,
          registrationNumber,
          contactName,
          contactPhone,
          contactEmail,
          region,
          businessAddress,
          serviceArea,
          cleanNonNegativeInteger(body.printerCount, '打印机数量', ApiError, organization.printer_count),
          cleanNonNegativeInteger(body.staffCount, '成员数量', ApiError, organization.staff_count),
          Math.max(1, cleanNonNegativeInteger(body.locationCount, '生产地点数量', ApiError, organization.location_count)),
          JSON.stringify(printerModels),
          JSON.stringify(materials),
          JSON.stringify(orderTypes),
          body.invoiceCapability == null
            ? organization.invoice_capability
            : body.invoiceCapability === true ? 1 : 0,
          timestamp,
          organizationId,
        );
        database.prepare(`
          UPDATE studio_workspaces SET name = ?, updated_at = ? WHERE id = ?
        `).run(displayName, timestamp, organizationId);
        const updated = database.prepare(
          'SELECT * FROM farm_organizations WHERE id = ?',
        ).get(organizationId);
        farmAudit(
          database,
          request,
          requestId,
          organizationId,
          user,
          'organization.profile_updated',
          'organization',
          organizationId,
          nowIso,
          { before: farmOrganizationJson(organization), after: farmOrganizationJson(updated) },
        );
        sendJson(response, 200, { organization: farmOrganizationJson(updated) }, requestId);
        return true;
      }
    }

    const submitRoute = path.match(/^\/v1\/farm\/organizations\/([^/]+)\/verification-submissions$/);
    if (submitRoute && method === 'POST') {
      const organizationId = decodePathSegment(submitRoute[1]);
      requireFarmPermission(
        database,
        user,
        organizationId,
        'organization.submit_verification',
        ApiError,
      );
      const organization = database.prepare(
        'SELECT * FROM farm_organizations WHERE id = ?',
      ).get(organizationId);
      if (!organization) throw new ApiError(404, 'farm_organization_not_found', '农场不存在');
      const missing = [];
      for (const [field, value] of [
        ['displayName', organization.display_name],
        ['contactName', organization.contact_name],
        ['contactPhone', organization.contact_phone],
        ['region', organization.region],
        ['businessAddress', organization.business_address],
      ]) {
        if (!String(value ?? '').trim()) missing.push(field);
      }
      if (organization.printer_count < 1) missing.push('printerCount');
      if (['company', 'sole_proprietor'].includes(organization.subject_type)) {
        if (!organization.legal_name) missing.push('legalName');
        if (!organization.registration_number) missing.push('registrationNumber');
      }
      if (missing.length > 0) {
        throw new ApiError(400, 'farm_verification_profile_incomplete', '农场入驻资料尚未填写完整', { missing });
      }
      const body = await readJson(request);
      const documentManifest = cleanStringArray(
        body.documentManifest ?? [],
        '证明文件清单',
        ApiError,
        { maxItems: 20, maxLength: 300 },
      );
      const latest = database.prepare(`
        SELECT MAX(submission_number) AS latest
        FROM farm_verification_submissions WHERE organization_id = ?
      `).get(organizationId);
      const submissionNumber = Number(latest?.latest ?? 0) + 1;
      const submissionId = randomUUID();
      const timestamp = nowIso();
      database.exec('BEGIN IMMEDIATE');
      try {
        database.prepare(`
          INSERT INTO farm_verification_submissions(
            id, organization_id, submission_number, status, profile_json,
            document_manifest_json, submitted_by, submitted_at
          ) VALUES (?, ?, ?, 'under_review', ?, ?, ?, ?)
        `).run(
          submissionId,
          organizationId,
          submissionNumber,
          JSON.stringify(farmOrganizationJson(organization)),
          JSON.stringify(documentManifest),
          user.id,
          timestamp,
        );
        database.prepare(`
          UPDATE farm_organizations
          SET verification_status = 'under_review', updated_at = ? WHERE id = ?
        `).run(timestamp, organizationId);
        farmAudit(
          database,
          request,
          requestId,
          organizationId,
          user,
          'organization.verification_submitted',
          'verification_submission',
          submissionId,
          nowIso,
          { after: { submissionNumber, documentManifest } },
        );
        database.exec('COMMIT');
      } catch (error) {
        database.exec('ROLLBACK');
        throw error;
      }
      sendJson(response, 201, {
        submission: {
          id: submissionId,
          submissionNumber,
          status: 'under_review',
          submittedAt: timestamp,
        },
      }, requestId);
      return true;
    }

    const staffCollectionRoute = path.match(/^\/v1\/farm\/organizations\/([^/]+)\/staff$/);
    if (staffCollectionRoute) {
      const organizationId = decodePathSegment(staffCollectionRoute[1]);
      if (method === 'GET') {
        requireFarmPermission(database, user, organizationId, 'member.view', ApiError);
        const rows = database.prepare(`
          SELECT * FROM studio_members
          WHERE workspace_id = ? ORDER BY active DESC, created_at ASC
        `).all(organizationId);
        sendJson(response, 200, {
          items: rows.map((row) => memberJson(row, database)),
        }, requestId);
        return true;
      }
      if (method === 'POST') {
        const actor = requireFarmPermission(
          database,
          user,
          organizationId,
          'member.create',
          ApiError,
        );
        const body = await readJson(request);
        const loginName = validateFarmLoginName(body.loginName, ApiError);
        const displayName = cleanText(body.displayName, '成员姓名', ApiError, { max: 80 });
        const employeeNo = optionalText(body.employeeNo, '成员编号', ApiError, { max: 50 });
        const phone = optionalText(body.phone, '成员手机号', ApiError, { max: 40 });
        const recoveryEmail = optionalText(body.recoveryEmail, '找回邮箱', ApiError, { max: 320 });
        // 兼容旧客户端仍提交 roleCodes/primaryRoleCode，但农场账号只保留
        // “管理员主账号”和“成员”两种身份，新建账号固定为成员。
        const roleCodes = ['member'];
        const requestedPrimaryRole = 'member';
        const roles = [database.prepare(`
          SELECT * FROM farm_roles
          WHERE organization_id = ? AND code = 'member' AND active = 1
        `).get(organizationId)];
        if (!roles[0]) {
          throw new ApiError(500, 'farm_member_role_missing', '农场成员身份尚未初始化');
        }
        const organization = database.prepare(
          'SELECT * FROM farm_organizations WHERE id = ?',
        ).get(organizationId);
        if (!organization) throw new ApiError(404, 'farm_organization_not_found', '农场不存在');
        const duplicate = database.prepare(`
          SELECT 1 FROM farm_staff_credentials
          WHERE organization_id = ? AND login_name = ?
        `).get(organizationId, loginName);
        if (duplicate) throw new ApiError(409, 'farm_staff_login_exists', '此成员登录名已被使用');
        const scopes = Array.isArray(body.scopes) && body.scopes.length > 0
          ? body.scopes
          : [{ type: 'organization', id: null }];
        if (scopes.length > 30) {
          throw new ApiError(400, 'farm_staff_scope_limit', '单个成员最多配置 30 个数据范围');
        }
        const allowedScopeTypes = new Set(['organization', 'location', 'printer_group', 'warehouse', 'order']);
        const normalizedScopes = scopes.map((scope) => {
          const type = cleanText(scope?.type, '权限范围类型', ApiError, { max: 40 });
          if (!allowedScopeTypes.has(type)) {
            throw new ApiError(400, 'invalid_farm_staff_scope', '不支持的成员数据范围');
          }
          const id = type === 'organization'
            ? null
            : cleanText(scope?.id, '权限范围标识', ApiError, { max: 120 });
          return { type, id };
        });
        const initialPassword = generatedInitialPassword();
        const encoded = passwordHash(initialPassword);
        const memberId = randomUUID();
        const staffUserId = randomUUID();
        const timestamp = nowIso();
        const syntheticEmail = `${staffUserId}@staff.sohun.invalid`;
        const syntheticHandle = `farm_${staffUserId.replaceAll('-', '')}`;
        const legacyRole = 'operator';
        database.exec('BEGIN IMMEDIATE');
        try {
          database.prepare(`
            INSERT INTO users(
              id, email, handle, display_name, password_hash, email_verified,
              status, created_at, updated_at, last_login_at
            ) VALUES (?, ?, ?, ?, ?, 1, 'active', ?, ?, NULL)
          `).run(
            staffUserId,
            syntheticEmail,
            syntheticHandle,
            displayName,
            encoded,
            timestamp,
            timestamp,
          );
          database.prepare(`
            INSERT INTO studio_members(
              id, workspace_id, user_id, email, display_name, role, active,
              created_at, login_name, employee_no, phone, recovery_email,
              account_status, primary_role_code, must_change_password
            ) VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, 'pending_activation', ?, 1)
          `).run(
            memberId,
            organizationId,
            staffUserId,
            syntheticEmail,
            displayName,
            legacyRole,
            timestamp,
            loginName,
            employeeNo,
            phone,
            recoveryEmail,
            requestedPrimaryRole,
          );
          database.prepare(`
            INSERT INTO farm_staff_credentials(
              member_id, organization_id, user_id, login_name, password_hash,
              must_change_password, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, 1, ?, ?)
          `).run(
            memberId,
            organizationId,
            staffUserId,
            loginName,
            encoded,
            timestamp,
            timestamp,
          );
          database.prepare(`
            INSERT INTO auth_identity_realms(user_id, realm, organization_id, created_at)
            VALUES (?, 'farm_staff', ?, ?)
          `).run(staffUserId, organizationId, timestamp);
          const insertRoleAssignment = database.prepare(`
            INSERT INTO farm_member_role_assignments(member_id, role_id, assigned_by, assigned_at)
            VALUES (?, ?, ?, ?)
          `);
          for (const role of roles) {
            insertRoleAssignment.run(memberId, role.id, user.id, timestamp);
          }
          const insertScope = database.prepare(`
            INSERT INTO farm_member_scopes(id, member_id, scope_type, scope_id, created_at)
            VALUES (?, ?, ?, ?, ?)
          `);
          for (const scope of normalizedScopes) {
            insertScope.run(randomUUID(), memberId, scope.type, scope.id, timestamp);
          }
          farmAudit(
            database,
            request,
            requestId,
            organizationId,
            user,
            'member.created',
            'member',
            memberId,
            nowIso,
            {
              after: {
                loginName,
                displayName,
                employeeNo,
                roleCodes,
                primaryRoleCode: requestedPrimaryRole,
                scopes: normalizedScopes,
              },
            },
          );
          database.exec('COMMIT');
        } catch (error) {
          database.exec('ROLLBACK');
          throw error;
        }
        const saved = database.prepare(
          'SELECT * FROM studio_members WHERE id = ?',
        ).get(memberId);
        sendJson(response, 201, {
          member: memberJson(saved, database),
          organizationCode: organization.organization_code,
          initialPassword,
          passwordShownOnce: true,
        }, requestId);
        return true;
      }
    }

    const staffRoute = path.match(/^\/v1\/farm\/organizations\/([^/]+)\/staff\/([^/]+)$/);
    if (staffRoute && method === 'PATCH') {
      const organizationId = decodePathSegment(staffRoute[1]);
      const memberId = decodePathSegment(staffRoute[2]);
      const actor = requireFarmPermission(
        database,
        user,
        organizationId,
        'member.update',
        ApiError,
      );
      const target = database.prepare(`
        SELECT * FROM studio_members WHERE id = ? AND workspace_id = ?
      `).get(memberId, organizationId);
      if (!target) throw new ApiError(404, 'farm_staff_not_found', '成员不存在');
      if (target.role === 'owner') {
        throw new ApiError(403, 'farm_owner_role_protected', '不能通过成员接口修改管理员');
      }
      const targetBefore = memberJson(target, database);
      const body = await readJson(request);
      if (target.account_status === 'removed') {
        if (body.accountStatus === 'removed') {
          sendJson(response, 200, { member: targetBefore }, requestId);
          return true;
        }
        throw new ApiError(409, 'farm_staff_removed', '已删除的成员不能恢复或修改');
      }
      const displayName = body.displayName == null
        ? target.display_name
        : cleanText(body.displayName, '成员姓名', ApiError, { max: 80 });
      const accountStatus = body.accountStatus == null
        ? target.account_status
        : cleanText(body.accountStatus, '成员状态', ApiError, { max: 40 });
      if (!['pending_activation', 'active', 'deactivated', 'removed'].includes(accountStatus)) {
        throw new ApiError(400, 'invalid_farm_staff_status', '成员状态不正确');
      }
      const roleCodes = ['member'];
      const requestedPrimaryRole = 'member';
      const roles = [database.prepare(`
        SELECT * FROM farm_roles
        WHERE organization_id = ? AND code = 'member' AND active = 1
      `).get(organizationId)];
      if (!roles[0]) {
        throw new ApiError(500, 'farm_member_role_missing', '农场成员身份尚未初始化');
      }
      const timestamp = nowIso();
      const credential = database.prepare(`
        SELECT * FROM farm_staff_credentials WHERE member_id = ?
      `).get(memberId);
      database.exec('BEGIN IMMEDIATE');
      try {
        database.prepare(`
          UPDATE studio_members SET
            display_name = ?, primary_role_code = ?,
            role = ?, account_status = ?, active = ?,
            deactivated_at = CASE WHEN ? IN ('deactivated', 'removed') THEN ? ELSE NULL END
          WHERE id = ?
        `).run(
          displayName,
          requestedPrimaryRole,
          'operator',
          accountStatus,
          ['deactivated', 'removed'].includes(accountStatus) ? 0 : 1,
          accountStatus,
          timestamp,
          memberId,
        );
        database.prepare('DELETE FROM farm_member_role_assignments WHERE member_id = ?')
          .run(memberId);
        const insertRoleAssignment = database.prepare(`
          INSERT INTO farm_member_role_assignments(member_id, role_id, assigned_by, assigned_at)
          VALUES (?, ?, ?, ?)
        `);
        for (const role of roles) {
          insertRoleAssignment.run(memberId, role.id, user.id, timestamp);
        }
        if (['deactivated', 'removed'].includes(accountStatus) && credential) {
          database.prepare(`
            UPDATE sessions SET revoked_at = ?
            WHERE user_id = ? AND revoked_at IS NULL
          `).run(timestamp, credential.user_id);
        }
        farmAudit(
          database,
          request,
          requestId,
          organizationId,
          user,
          accountStatus === 'removed'
            ? 'member.removed'
            : accountStatus === 'deactivated' ? 'member.deactivated' : 'member.updated',
          'member',
          memberId,
          nowIso,
          {
            before: targetBefore,
            after: {
              displayName,
              roleCodes,
              primaryRoleCode: requestedPrimaryRole,
              accountStatus,
            },
          },
        );
        database.exec('COMMIT');
      } catch (error) {
        database.exec('ROLLBACK');
        throw error;
      }
      const updated = database.prepare(
        'SELECT * FROM studio_members WHERE id = ?',
      ).get(memberId);
      sendJson(response, 200, { member: memberJson(updated, database) }, requestId);
      return true;
    }

    const resetCredentialRoute = path.match(/^\/v1\/farm\/organizations\/([^/]+)\/staff\/([^/]+)\/reset-credential$/);
    if (resetCredentialRoute && method === 'POST') {
      const organizationId = decodePathSegment(resetCredentialRoute[1]);
      const memberId = decodePathSegment(resetCredentialRoute[2]);
      const actor = requireFarmPermission(
        database,
        user,
        organizationId,
        'member.reset_credential',
        ApiError,
      );
      const credential = database.prepare(`
        SELECT credentials.*, members.role, members.primary_role_code,
               members.account_status
        FROM farm_staff_credentials credentials
        JOIN studio_members members ON members.id = credentials.member_id
        WHERE credentials.member_id = ? AND credentials.organization_id = ?
      `).get(memberId, organizationId);
      if (!credential) throw new ApiError(404, 'farm_staff_not_found', '成员登录账号不存在');
      if (credential.role === 'owner') {
        throw new ApiError(403, 'farm_owner_role_protected', '不能通过成员接口重置管理员凭据');
      }
      if (credential.account_status === 'removed') {
        throw new ApiError(409, 'farm_staff_removed', '已删除成员的登录凭据不能重置');
      }
      const initialPassword = generatedInitialPassword();
      const encoded = passwordHash(initialPassword);
      const timestamp = nowIso();
      database.exec('BEGIN IMMEDIATE');
      try {
        database.prepare(`
          UPDATE farm_staff_credentials
          SET password_hash = ?, must_change_password = 1, failed_attempts = 0,
              locked_until = NULL, updated_at = ? WHERE member_id = ?
        `).run(encoded, timestamp, memberId);
        database.prepare(`
          UPDATE studio_members
          SET must_change_password = 1, account_status = 'pending_activation', active = 1
          WHERE id = ?
        `).run(memberId);
        database.prepare(`
          UPDATE users SET password_hash = ?, status = 'active', updated_at = ? WHERE id = ?
        `).run(encoded, timestamp, credential.user_id);
        database.prepare(`
          UPDATE sessions SET revoked_at = ? WHERE user_id = ? AND revoked_at IS NULL
        `).run(timestamp, credential.user_id);
        farmAudit(
          database,
          request,
          requestId,
          organizationId,
          user,
          'member.credential_reset',
          'member',
          memberId,
          nowIso,
        );
        database.exec('COMMIT');
      } catch (error) {
        database.exec('ROLLBACK');
        throw error;
      }
      sendJson(response, 200, {
        ok: true,
        initialPassword,
        passwordShownOnce: true,
      }, requestId);
      return true;
    }

    const auditRoute = path.match(/^\/v1\/farm\/organizations\/([^/]+)\/audit-logs$/);
    if (auditRoute && method === 'GET') {
      const organizationId = decodePathSegment(auditRoute[1]);
      const actor = requireFarmPermission(
        database,
        user,
        organizationId,
        'audit.view',
        ApiError,
      );
      if (actor.role !== 'owner') {
        throw new ApiError(403, 'farm_audit_admin_only', '只有农场管理员可以查看完整操作记录');
      }
      const requestUrl = new URL(request.url ?? '/', 'http://localhost');
      const limit = Math.min(500, Math.max(1, Number(requestUrl.searchParams.get('limit')) || 200));
      const offset = Math.max(0, Number(requestUrl.searchParams.get('offset')) || 0);
      const rows = database.prepare(`
        SELECT logs.*, users.display_name AS actor_name
        FROM farm_audit_logs logs
        LEFT JOIN users ON users.id = logs.actor_user_id
        WHERE logs.organization_id = ?
        ORDER BY logs.created_at DESC LIMIT ? OFFSET ?
      `).all(organizationId, limit + 1, offset);
      const hasMore = rows.length > limit;
      sendJson(response, 200, {
        items: rows.slice(0, limit).map((row) => ({
          id: row.id,
          clientEventId: row.client_event_id,
          action: row.action,
          actorName: row.actor_display_name ?? row.actor_name,
          actorIdentity: row.actor_identity,
          actorMemberId: row.actor_member_id,
          resourceType: row.resource_type,
          resourceId: row.resource_id,
          result: row.result,
          summary: row.summary,
          ipAddress: row.ip_address,
          userAgent: row.user_agent,
          requestId: row.request_id,
          createdAt: row.created_at,
        })),
        hasMore,
      }, requestId);
      return true;
    }

    return false;
  }

  if (!path.startsWith('/v1/studio/')) return false;
  const creatingWorkspace = method === 'POST' && path === '/v1/studio/workspaces';
  const user = creatingWorkspace
    ? authenticatedUser(database, request)
    : verifiedAuthenticatedUser(database, request);
  if (creatingWorkspace) {
    const staffRealm = database.prepare(`
      SELECT 1 FROM auth_identity_realms
      WHERE user_id = ? AND realm = 'farm_staff' LIMIT 1
    `).get(user.id);
    if (staffRealm) {
      throw new ApiError(
        403,
        'farm_staff_cannot_create_organization',
        '农场成员账号不能创建新的农场主体',
      );
    }
  }

  if (method === 'GET' && path === '/v1/studio/workspaces') {
    const rows = database.prepare(`
      SELECT workspaces.*, members.role, members.primary_role_code,
             organizations.organization_code, organizations.verification_status
      FROM studio_workspaces workspaces
      JOIN studio_members members ON members.workspace_id = workspaces.id
      LEFT JOIN farm_organizations organizations ON organizations.id = workspaces.id
      WHERE members.active = 1
        AND (members.user_id = ? OR lower(members.email) = lower(?))
      ORDER BY workspaces.updated_at DESC
    `).all(user.id, user.email);
    sendJson(response, 200, {
      items: rows.map((row) => ({
        id: row.id,
        name: row.name,
        role: row.role,
        primaryRoleCode: row.primary_role_code,
        organizationCode: row.organization_code,
        verificationStatus: row.verification_status,
        updatedAt: row.updated_at,
      })),
    }, requestId);
    return true;
  }

  if (method === 'POST' && path === '/v1/studio/workspaces') {
    const body = await readJson(request);
    const id = cleanText(body.id ?? randomUUID(), 'id', ApiError, { max: 100 });
    const name = cleanText(body.name, 'name', ApiError, { max: 120 });
    const timestamp = nowIso();
    database.exec('BEGIN IMMEDIATE');
    try {
      const existing = database.prepare('SELECT owner_user_id FROM studio_workspaces WHERE id = ?').get(id);
      if (existing && existing.owner_user_id !== user.id) {
        throw new ApiError(409, 'studio_workspace_id_conflict', '工作室标识已被占用');
      }
      database.prepare(`
        INSERT OR IGNORE INTO studio_workspaces(id, owner_user_id, name, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?)
      `).run(id, user.id, name, timestamp, timestamp);
      database.prepare(`
        INSERT OR IGNORE INTO studio_members(id, workspace_id, user_id, email, display_name, role, active, created_at)
        VALUES (?, ?, ?, ?, ?, 'owner', 1, ?)
      `).run(randomUUID(), id, user.id, user.email, user.display_name, timestamp);
      ensureFarmOrganization(database, id, user.id, name, timestamp);
      database.prepare(`
        INSERT OR IGNORE INTO studio_snapshots(workspace_id, revision, payload_json, updated_by, updated_at)
        VALUES (?, 0, '{}', ?, ?)
      `).run(id, user.id, timestamp);
      audit(database, id, user.id, 'workspace.create', id, nowIso);
      database.exec('COMMIT');
    } catch (error) {
      database.exec('ROLLBACK');
      throw error;
    }
    sendJson(response, 201, { id, name, role: 'owner', revision: 0 }, requestId);
    return true;
  }

  const snapshotRoute = path.match(/^\/v1\/studio\/workspaces\/([^/]+)\/snapshot$/);
  if (snapshotRoute && method === 'GET') {
    const workspaceId = decodePathSegment(snapshotRoute[1]);
    requireFarmPermission(database, user, workspaceId, 'organization.view', ApiError);
    const workspace = database.prepare('SELECT * FROM studio_workspaces WHERE id = ?').get(workspaceId);
    if (!workspace) throw new ApiError(404, 'studio_workspace_not_found', '工作室不存在');
    const snapshot = database.prepare('SELECT * FROM studio_snapshots WHERE workspace_id = ?').get(workspaceId);
    const members = database.prepare('SELECT * FROM studio_members WHERE workspace_id = ? ORDER BY active DESC, created_at ASC').all(workspaceId);
    const shares = database.prepare(`
      SELECT id, order_id, token_preview, active, expires_at, created_at,
             password_hash IS NOT NULL AS password_required
      FROM studio_share_links WHERE workspace_id = ? ORDER BY created_at DESC
    `).all(workspaceId);
    sendJson(response, 200, {
      workspace: { id: workspace.id, name: workspace.name, updatedAt: workspace.updated_at },
      revision: snapshot?.revision ?? 0,
      snapshot: parseSnapshot(snapshot),
      members: members.map((row) => memberJson(row, database)),
      shareLinks: shares.map((row) => ({
        id: row.id,
        orderId: row.order_id,
        tokenPreview: row.token_preview,
        relativeUrl: `/studio/share/${encodeURIComponent(row.id)}`,
        active: Boolean(row.active),
        passwordRequired: Boolean(row.password_required),
        expiresAt: row.expires_at,
        createdAt: row.created_at,
      })),
    }, requestId);
    return true;
  }

  if (snapshotRoute && method === 'PUT') {
    const workspaceId = decodePathSegment(snapshotRoute[1]);
    requireFarmPermission(database, user, workspaceId, 'workspace.snapshot.write', ApiError);
    const body = await readJson(request);
    const baseRevision = Number(body.baseRevision);
    if (!Number.isSafeInteger(baseRevision) || baseRevision < 0) {
      throw new ApiError(400, 'invalid_studio_revision', 'baseRevision 必须是非负整数');
    }
    if (!body.snapshot || typeof body.snapshot !== 'object' || Array.isArray(body.snapshot)) {
      throw new ApiError(400, 'invalid_studio_snapshot', 'snapshot 必须是对象');
    }
    assertSnapshotSafe(body.snapshot, ApiError);
    assertSnapshotBusinessInvariants(body.snapshot, ApiError);
    const payload = JSON.stringify(body.snapshot);
    const timestamp = nowIso();
    database.exec('BEGIN IMMEDIATE');
    try {
      const current = database.prepare('SELECT revision FROM studio_snapshots WHERE workspace_id = ?').get(workspaceId);
      if (!current) throw new ApiError(404, 'studio_workspace_not_found', '工作室不存在');
      if (current.revision !== baseRevision) {
        throw new ApiError(409, 'studio_revision_conflict', '工作室数据已在其他设备更新', {
          currentRevision: current.revision,
        });
      }
      ingestSnapshotActivityEvents(database, workspaceId, body.snapshot, user, timestamp);
      const revision = baseRevision + 1;
      database.prepare(`
        UPDATE studio_snapshots SET revision = ?, payload_json = ?, updated_by = ?, updated_at = ?
        WHERE workspace_id = ? AND revision = ?
      `).run(revision, payload, user.id, timestamp, workspaceId, baseRevision);
      database.prepare('UPDATE studio_workspaces SET updated_at = ? WHERE id = ?')
        .run(timestamp, workspaceId);
      audit(database, workspaceId, user.id, 'snapshot.update', String(revision), nowIso);
      database.exec('COMMIT');
      sendJson(response, 200, { revision, updatedAt: timestamp }, requestId);
    } catch (error) {
      database.exec('ROLLBACK');
      throw error;
    }
    return true;
  }

  const membersRoute = path.match(/^\/v1\/studio\/workspaces\/([^/]+)\/members$/);
  if (membersRoute && method === 'POST') {
    const workspaceId = decodePathSegment(membersRoute[1]);
    const actor = requireFarmPermission(database, user, workspaceId, 'member.create', ApiError);
    const body = await readJson(request);
    const email = cleanText(body.email, 'email', ApiError, { max: 320 }).toLowerCase();
    const displayName = cleanText(body.displayName, 'displayName', ApiError, { max: 80 });
    const role = cleanText(body.role ?? 'operator', 'role', ApiError, { max: 20 });
    if (!STUDIO_ROLES.has(role) || role === 'owner' || (actor.role === 'admin' && role !== 'operator')) {
      throw new ApiError(403, 'studio_role_not_assignable', '不能分配此工作室角色');
    }
    const invitedUser = database.prepare('SELECT id FROM users WHERE lower(email) = lower(?)').get(email);
    const id = randomUUID();
    const timestamp = nowIso();
    database.prepare(`
      INSERT INTO studio_members(id, workspace_id, user_id, email, display_name, role, active, created_at)
      VALUES (?, ?, ?, ?, ?, ?, 1, ?)
      ON CONFLICT(workspace_id, email) DO UPDATE SET
        user_id = excluded.user_id, display_name = excluded.display_name,
        role = excluded.role, active = 1
    `).run(id, workspaceId, invitedUser?.id ?? null, email, displayName, role, timestamp);
    audit(database, workspaceId, user.id, 'member.upsert', email, nowIso);
    const saved = database.prepare('SELECT * FROM studio_members WHERE workspace_id = ? AND lower(email) = lower(?)').get(workspaceId, email);
    sendJson(response, 200, { member: memberJson(saved, database) }, requestId);
    return true;
  }

  const memberRoute = path.match(/^\/v1\/studio\/workspaces\/([^/]+)\/members\/([^/]+)$/);
  if (memberRoute && method === 'DELETE') {
    const workspaceId = decodePathSegment(memberRoute[1]);
    const actor = requireFarmPermission(database, user, workspaceId, 'member.disable', ApiError);
    const memberId = decodePathSegment(memberRoute[2]);
    const target = database.prepare('SELECT * FROM studio_members WHERE id = ? AND workspace_id = ?').get(memberId, workspaceId);
    if (!target) throw new ApiError(404, 'studio_member_not_found', '成员不存在');
    if (target.role === 'owner' || (actor.role === 'admin' && target.role !== 'operator')) {
      throw new ApiError(403, 'studio_member_protected', '不能停用此成员');
    }
    database.prepare('UPDATE studio_members SET active = 0 WHERE id = ?').run(memberId);
    audit(database, workspaceId, user.id, 'member.deactivate', memberId, nowIso);
    sendJson(response, 200, { ok: true }, requestId);
    return true;
  }

  const sharesRoute = path.match(/^\/v1\/studio\/workspaces\/([^/]+)\/share-links$/);

  const videoDemandRoute = path.match(
    /^\/v1\/studio\/workspaces\/([^/]+)\/video-demand$/,
  );
  if (videoDemandRoute && method === 'GET') {
    const workspaceId = decodePathSegment(videoDemandRoute[1]);
    requireMembership(database, user, workspaceId, ApiError, STUDIO_ROLES);
    sendJson(response, 200, {
      items: activeVideoDemand(runtimeFor(database), workspaceId),
    }, requestId);
    return true;
  }

  const videoSessionsRoute = path.match(/^\/v1\/studio\/workspaces\/([^/]+)\/video-sessions$/);
  if (videoSessionsRoute && method === 'POST') {
    const workspaceId = decodePathSegment(videoSessionsRoute[1]);
    requireMembership(database, user, workspaceId, ApiError, STUDIO_ROLES);
    const body = await readJson(request);
    const orderId = cleanText(body.orderId, 'orderId', ApiError, { max: 100 });
    const workOrderId = cleanText(body.workOrderId, 'workOrderId', ApiError, { max: 100 });
    const publicPrinterName = cleanText(
      body.publicPrinterName,
      'publicPrinterName',
      ApiError,
      { max: 80 },
    );
    const snapshotRow = database.prepare(
      'SELECT payload_json FROM studio_snapshots WHERE workspace_id = ?',
    ).get(workspaceId);
    const snapshot = parseSnapshot(snapshotRow);
    const order = Array.isArray(snapshot.orders)
      ? snapshot.orders.find((item) => item?.id === orderId)
      : null;
    const workOrder = Array.isArray(snapshot.workOrders)
      ? snapshot.workOrders.find(
          (item) => item?.id === workOrderId && item?.orderId === orderId,
        )
      : null;
    if (!order || !workOrder) {
      throw new ApiError(404, 'studio_video_order_not_found', '订单或工单不存在');
    }
    if (order.portalVideoEnabled === false) {
      throw new ApiError(409, 'studio_video_disabled', '此订单未开启客户视频');
    }
    if (workOrder.status !== 'printing' || workOrder.activePrint !== true) {
      throw new ApiError(409, 'studio_video_not_printing', '只有正在打印的工单可以转接视频');
    }
    const id = randomUUID();
    const uploadToken = createToken();
    const timestamp = nowIso();
    const expiresAt = new Date(Date.now() + VIDEO_SESSION_MS).toISOString();
    const runtime = runtimeFor(database);
    const replacedSessionIds = database.prepare(`
      SELECT id FROM studio_video_sessions
      WHERE workspace_id = ? AND order_id = ? AND work_order_id = ? AND active = 1
    `).all(workspaceId, orderId, workOrderId).map((item) => item.id);
    database.exec('BEGIN IMMEDIATE');
    try {
      database.prepare(`
        UPDATE studio_video_sessions SET active = 0
        WHERE workspace_id = ? AND order_id = ? AND work_order_id = ? AND active = 1
      `).run(workspaceId, orderId, workOrderId);
      database.prepare(`
        INSERT INTO studio_video_sessions(
          id, workspace_id, order_id, work_order_id, upload_token_hash,
          public_printer_name, active, expires_at, created_by, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?, ?)
      `).run(
        id,
        workspaceId,
        orderId,
        workOrderId,
        tokenHash(uploadToken),
        publicPrinterName,
        expiresAt,
        user.id,
        timestamp,
      );
      audit(database, workspaceId, user.id, 'video.start', workOrderId, nowIso);
      database.exec('COMMIT');
    } catch (error) {
      database.exec('ROLLBACK');
      throw error;
    }
    for (const replacedId of replacedSessionIds) {
      runtime.frames.delete(replacedId);
      runtime.liveStreams.delete(replacedId);
    }
    if (studioLive || studioOpenStream) {
      const streamName = `sohun_${randomBytes(16).toString('hex')}`;
      runtime.liveStreams.set(id, {
        streamName,
        transport: studioLive ? 'tencent' : 'open',
        uploadTokenHash: tokenHash(uploadToken),
      });
      sendJson(response, 201, {
        id,
        transport: 'rtmp',
        pushUrl: studioLive
          ? createTencentPushUrl(studioLive, streamName)
          : createOpenStreamPushUrl(studioOpenStream, streamName, uploadToken),
        expiresAt,
      }, requestId);
    } else {
      sendJson(response, 201, {
        id,
        transport: 'jpeg',
        uploadToken,
        uploadPath: `/v1/studio/video-uplink/${encodeURIComponent(id)}/frame`,
        expiresAt,
      }, requestId);
    }
    return true;
  }

  const videoSessionRoute = path.match(/^\/v1\/studio\/workspaces\/([^/]+)\/video-sessions\/([^/]+)$/);
  if (videoSessionRoute && method === 'DELETE') {
    const workspaceId = decodePathSegment(videoSessionRoute[1]);
    requireMembership(database, user, workspaceId, ApiError, STUDIO_ROLES);
    const sessionId = decodePathSegment(videoSessionRoute[2]);
    database.prepare(
      'UPDATE studio_video_sessions SET active = 0 WHERE id = ? AND workspace_id = ?',
    ).run(sessionId, workspaceId);
    const runtime = runtimeFor(database);
    runtime.frames.delete(sessionId);
    runtime.liveStreams.delete(sessionId);
    audit(database, workspaceId, user.id, 'video.stop', sessionId, nowIso);
    sendJson(response, 200, { ok: true }, requestId);
    return true;
  }

  if (sharesRoute && method === 'POST') {
    const workspaceId = decodePathSegment(sharesRoute[1]);
    requireMembership(database, user, workspaceId, ApiError, MANAGER_ROLES);
    const body = await readJson(request);
    const orderId = cleanText(body.orderId, 'orderId', ApiError, { max: 100 });
    const portalPassword = cleanText(
      body.portalPassword,
      'portalPassword',
      ApiError,
      { min: 6, max: 64 },
    );
    const snapshot = database.prepare('SELECT * FROM studio_snapshots WHERE workspace_id = ?').get(workspaceId);
    const orders = parseSnapshot(snapshot).orders;
    if (!Array.isArray(orders) || !orders.some((item) => item?.id === orderId)) {
      throw new ApiError(404, 'studio_order_not_found', '订单不存在或尚未同步');
    }
    const days = body.expiresInDays == null ? 30 : Number(body.expiresInDays);
    if (!Number.isSafeInteger(days) || days < 1 || days > 365) {
      throw new ApiError(400, 'invalid_share_expiry', '分享有效期必须为 1-365 天');
    }
    const token = randomBytes(32).toString('base64url');
    const id = randomUUID();
    const timestamp = nowIso();
    const expiresAt = new Date(Date.now() + days * 86_400_000).toISOString();
    const preview = token.slice(0, 6);
    database.prepare(`
      INSERT INTO studio_share_links(
        id, workspace_id, order_id, token_hash, token_preview,
        active, expires_at, created_by, created_at, password_hash
      ) VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?, ?)
    `).run(
      id,
      workspaceId,
      orderId,
      tokenHash(token),
      preview,
      expiresAt,
      user.id,
      timestamp,
      passwordHash(portalPassword),
    );
    audit(database, workspaceId, user.id, 'share.create', id, nowIso);
    sendJson(response, 201, {
      id,
      token,
      tokenPreview: preview,
      relativeUrl: `/studio/share/${encodeURIComponent(token)}`,
      expiresAt,
      createdAt: timestamp,
    }, requestId);
    return true;
  }

  const shareRoute = path.match(/^\/v1\/studio\/workspaces\/([^/]+)\/share-links\/([^/]+)$/);
  if (shareRoute && method === 'DELETE') {
    const workspaceId = decodePathSegment(shareRoute[1]);
    requireMembership(database, user, workspaceId, ApiError, MANAGER_ROLES);
    const shareId = decodePathSegment(shareRoute[2]);
    database.prepare('UPDATE studio_share_links SET active = 0 WHERE id = ? AND workspace_id = ?')
      .run(shareId, workspaceId);
    audit(database, workspaceId, user.id, 'share.revoke', shareId, nowIso);
    sendJson(response, 200, { ok: true }, requestId);
    return true;
  }

  return false;
}
