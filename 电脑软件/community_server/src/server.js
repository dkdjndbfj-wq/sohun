import { createServer } from 'node:http';
import {
  createHash,
  createHmac,
  randomBytes,
  randomInt,
  randomUUID,
  scryptSync,
  timingSafeEqual,
} from 'node:crypto';
import { existsSync, mkdirSync, statSync } from 'node:fs';
import { isIP } from 'node:net';
import { homedir } from 'node:os';
import { dirname, isAbsolute, parse, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';

import { createBackupManager, validateBackupConfiguration } from './backup_manager.js';
import {
  createSmtpEmailSender,
  smtpConfigurationFromEnvironment,
  validateSmtpConfiguration,
} from './email_service.js';
import { runMigrations, contentHashOf } from './migrations.js';
import { createPolicyStore } from './policy_store.js';
import { handleStudioRequest } from './studio_routes.js';
import { handlePrinterFaultRequest } from './printer_fault_routes.js';
import { handleDeviceWorkbenchRequest } from './device_workbench_routes.js';

const ACCESS_TOKEN_TTL_MS = 15 * 60 * 1000;
const REFRESH_TOKEN_TTL_MS = 30 * 24 * 60 * 60 * 1000;
const MAX_BODY_BYTES = 2 * 1024 * 1024;
const MAX_PERSONAL_INVENTORY_RECORDS = 2_000;
const MAX_PERSONAL_INVENTORY_EVENTS = 10_000;
const MAX_PERSONAL_MATERIAL_CATALOG = 5_000;
const PERSONAL_INVENTORY_RECORD_KEYS = new Set([
  'uid',
  'manufacturer',
  'model',
  'materialType',
  'colorHex',
  'colorName',
  'totalGrams',
  'remainingGrams',
  'batchNo',
  'purchaseDate',
  'note',
  'createdAt',
  'updatedAt',
  'density',
  'recommendedNozzleTemp',
  'hygroscopicity',
  'trayUuid',
  'rfidSyncedAt',
  'rfidTagUid',
  'rfidTagType',
  'rfidTagCycle',
  'lifecycleStatus',
  'previousConsumableUid',
  'rfidTagHistory',
  'sourceRfidTagUid',
  'sourceRfidTagType',
  'stockReceiptUid',
  'stockReceiptIndex',
  'stockReceiptQuantity',
]);
const PERSONAL_INVENTORY_SNAPSHOT_KEYS = new Set([
  'revision', 'records', 'materialCatalog', 'deletedUids', 'events',
]);
const DEFAULT_LIMIT = 30;
const MAX_LIMIT = 100;
const API_VERSION = 1;
const DEFAULT_TERMS_VERSION = '2026-07-29';
const DEFAULT_PRIVACY_VERSION = '2026-07-29';
const ACCOUNT_CODE_TTL_MINUTES = 15;
const ACCOUNT_CODE_MAX_ATTEMPTS = 5;
const DEFAULT_RATE_LIMIT_MAX_BUCKETS = 10_000;
const DEFAULT_RATE_LIMIT_SWEEP_INTERVAL_MS = 60_000;
const DEFAULT_MAX_PRESETS_PER_USER = 100;
const DEFAULT_MAX_PRESET_BYTES_PER_USER = 50 * 1024 * 1024;
// 本机开发服务没有部署密钥管理，因此使用固定的本地 pepper，确保本地测试
// 账号在重启开发服务后仍可登录。生产模式必须显式提供 COMMUNITY_PASSWORD_PEPPER。
const LOCAL_DEMO_PASSWORD_PEPPER =
  'sohun-local-demo-pepper-2026-08-05-keep-stable';
const LOCAL_INSPECTION_ACCOUNT = Object.freeze({
  email: 'farm.admin.permanent@sohun.local',
  handle: 'farm.admin.permanent',
  displayName: '管理员',
  organizationId: 'sohun-farm-permanent',
  organizationCode: 'FEA0704924B',
  organizationName: 'sohun 常驻农场',
});
const DEFAULT_READINESS_CACHE_MS = 30_000;
const IS_DIRECT_ENTRYPOINT = process.argv[1] === fileURLToPath(import.meta.url);

// Phase E 常量：社区可信体系相关限流和门槛。
// 任务书 10.2：限制同一用户、参数、时间窗口内的异常高频结果；具体限制写成常量并测试。
const PRINT_RESULTS_PER_USER_PER_PRESET_PER_HOUR = 10;
const PRINT_RESULTS_MAX_PER_BATCH = 5;
// 任务书 10.3：社区实打最低门槛 = 至少 3 条有效结果且来自至少 2 个非作者账号；
// "高可信"至少 10 条、5 个非作者账号，并使用 Wilson 下界。
const COMMUNITY_TRUST_MIN_SAMPLES = 3;
const COMMUNITY_TRUST_MIN_USERS = 2;
const COMMUNITY_TRUST_HIGH_SAMPLES = 10;
const COMMUNITY_TRUST_HIGH_USERS = 5;
// 任务书 10.2：评分只能绑定已存在的打印结果；一个账号对同一结果不能重复贡献评分权重。
const REPORTS_PER_USER_PER_PRESET_ACTIVE = 1;
// 任务书 11.4：单批 20-50 条，未发送队列最多 1000 条或 7 天。
const TELEMETRY_BATCH_MAX = 50;
const TELEMETRY_BATCH_PER_ADDRESS_PER_MINUTE = 6;
// 任务书 11.4：上传自身失败不得再次生成同类遥测，避免递归和重试风暴。
// 任务书 11.6：远程配置只能控制社区增强、实验、诊断上传和非安全网络功能；
// 永远不能远程关闭数据完整性校验、库存结算、LAN 监控、故障安全告警或凭据保护。
const IMMUTABLE_FEATURE_FLAGS = new Set([
  'data_integrity_check',
  'inventory_settlement',
  'lan_monitoring',
  'fault_safety_alert',
  'credential_protection',
]);
const TELEMETRY_EVENT_WHITELIST = new Set([
  'app.crash',
  'app.upgrade',
  'sync.community_presets',
  'sync.bambu_devices',
  'sync.bambu_presets',
  'http.community_request',
  'printer.connection',
  'printer.compatibility',
  'camera.bridge',
  'onboarding.flow',
  'remote_config.fetch',
]);

export class ApiError extends Error {
  constructor(status, code, message, details = undefined) {
    super(message);
    this.status = status;
    this.code = code;
    this.details = details;
  }
}

function decodePathSegment(value) {
  try {
    return decodeURIComponent(value);
  } catch {
    throw new ApiError(400, 'invalid_path', '请求路径不正确');
  }
}

export function validateAllowedOrigin(value, { production = false } = {}) {
  const configured = String(value ?? (production ? '' : '*')).trim();
  if (!configured) {
    if (production) {
      throw new Error('COMMUNITY_ALLOWED_ORIGIN must be explicitly set in production');
    }
    return '*';
  }
  if (configured === '*') {
    if (production) {
      throw new Error('COMMUNITY_ALLOWED_ORIGIN must be an exact HTTPS origin in production');
    }
    return configured;
  }

  let origin;
  try {
    origin = new URL(configured);
  } catch {
    throw new Error('COMMUNITY_ALLOWED_ORIGIN must be a valid HTTP or HTTPS origin');
  }
  if (
    !['http:', 'https:'].includes(origin.protocol)
    || origin.username
    || origin.password
    || origin.pathname !== '/'
    || origin.search
    || origin.hash
  ) {
    throw new Error('COMMUNITY_ALLOWED_ORIGIN must be a single HTTP or HTTPS origin');
  }
  if (production && origin.protocol !== 'https:') {
    throw new Error('COMMUNITY_ALLOWED_ORIGIN must be an exact HTTPS origin in production');
  }
  return origin.origin;
}

function nonEmptyString(value) {
  const normalized = String(value ?? '').trim();
  return normalized || null;
}

function isGitHubRepository(value) {
  return /^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,38})\/[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/.test(value);
}

function isSafeReleaseSegment(value) {
  return value.length <= 255 &&
    !/[\\/\u0000-\u001f\u007f]/.test(value) &&
    value !== '.' &&
    value !== '..';
}

/// Resolves release metadata exposed through `GET /v1/config`.
///
/// An explicit HTTPS download URL remains the escape hatch for a non-GitHub
/// release host. Otherwise, a GitHub Releases URL is built from repository,
/// tag, and optional installer asset configuration. Invalid optional values
/// are ignored so a malformed deployment setting cannot make the API fail.
export function resolveReleaseMetadata(options = {}) {
  return {
    ...resolvePlatformReleaseMetadata(options, 'desktop'),
    ...resolvePlatformReleaseMetadata(options.android ?? {}, 'android'),
  };
}

function resolvePlatformReleaseMetadata({
  latestVersion,
  minSupportedVersion,
  forceUpdate,
  downloadUrl,
  githubRepository,
  githubReleaseTag,
  installerAsset,
  releaseNotes,
} = {}, platform) {
  const flags = {};
  const latest = nonEmptyString(latestVersion);
  const minimum = nonEmptyString(minSupportedVersion);
  const notes = nonEmptyString(releaseNotes);
  const explicitUrl = nonEmptyString(downloadUrl);
  const versionPattern = /^[vV]?\d+\.\d+\.\d+(?:\+\d+)?$/;
  const validVersion = (value) => versionPattern.test(value) &&
    value.replace(/^[vV]/, '').split(/[.+]/).every((part) => BigInt(part) <= 9223372036854775807n);
  // Broken policy metadata must not silently become an optional update.
  if (!latest || !validVersion(latest)) return flags;
  if (minimum && (!validVersion(minimum) || compareReleaseVersions(minimum, latest) > 0)) {
    return flags;
  }
  const force = configuredUpdateBoolean(forceUpdate);
  if (force === null) return flags;
  flags[`${platform}_latest_version`] = latest;
  if (notes) flags[`${platform}_release_notes`] = notes;

  let resolvedDownloadUrl = null;
  if (explicitUrl) {
    try {
      const url = new URL(explicitUrl);
      if (url.protocol === 'https:' && !url.username && !url.password) {
        resolvedDownloadUrl = url.toString();
      }
    } catch {
      // A malformed address is handled below without publishing a dead gate.
    }
  } else {
    const repository = nonEmptyString(githubRepository);
    const tag = nonEmptyString(githubReleaseTag) ?? latest;
    const asset = nonEmptyString(installerAsset);
    if (repository && tag && isGitHubRepository(repository) && isSafeReleaseSegment(tag)) {
      const encodedTag = encodeURIComponent(tag);
      resolvedDownloadUrl = asset && isSafeReleaseSegment(asset)
        ? `https://github.com/${repository}/releases/download/${encodedTag}/${encodeURIComponent(asset)}`
        : `https://github.com/${repository}/releases/tag/${encodedTag}`;
    }
  }

  const requestsMandatoryUpdate = force === true || minimum !== null;
  if (requestsMandatoryUpdate && !resolvedDownloadUrl) {
    // A bad deployment setting must not lock every client behind a disabled
    // button. Publish an explicit withdrawal so cached mandatory policies can
    // also release after receiving this newer, verified snapshot.
    flags[`${platform}_min_supported_version`] = '';
    flags[`${platform}_force_update`] = false;
    return flags;
  }

  // Missing keys remain compatible with old optional-release configuration.
  // Explicit false/empty values let an operator intentionally withdraw a gate.
  if (minSupportedVersion !== undefined && minSupportedVersion !== null) {
    flags[`${platform}_min_supported_version`] = minimum ?? '';
  }
  if (force !== undefined) flags[`${platform}_force_update`] = force;
  if (resolvedDownloadUrl) {
    flags[`${platform}_download_url`] = resolvedDownloadUrl;
  }
  return flags;
}

function configuredUpdateBoolean(value) {
  if (value === undefined || value === null || value === '') return undefined;
  if (typeof value === 'boolean') return value;
  if (typeof value !== 'string') return null;
  const normalized = value.trim().toLowerCase();
  if (normalized === 'true' || normalized === '1') return true;
  if (normalized === 'false' || normalized === '0') return false;
  return null;
}

function compareReleaseVersions(left, right) {
  const parts = (value) => {
    const [core, build = '0'] = value.replace(/^[vV]/, '').split('+');
    return [...core.split('.'), build].map(BigInt);
  };
  const a = parts(left);
  const b = parts(right);
  for (let index = 0; index < a.length; index += 1) {
    if (a[index] > b[index]) return 1;
    if (a[index] < b[index]) return -1;
  }
  return 0;
}

export function validateProductionConfiguration({
  passwordPepper,
  adminToken,
  databasePath,
  backupDirectory,
  backupRetentionDays = 30,
  backupIntervalHours = 24,
  supportEmail,
  emailVerificationRequired = true,
  smtpConfiguration,
  emailSenderConfigured = false,
}) {
  if (Buffer.byteLength(String(passwordPepper ?? ''), 'utf8') < 32) {
    throw new Error('COMMUNITY_PASSWORD_PEPPER must contain at least 32 bytes in production');
  }
  if (Buffer.byteLength(String(adminToken ?? ''), 'utf8') < 32) {
    throw new Error('COMMUNITY_ADMIN_TOKEN must contain at least 32 bytes in production');
  }
  if (typeof databasePath !== 'string' || databasePath.length === 0) {
    throw new Error('COMMUNITY_DATABASE_PATH must be explicitly set to an absolute file path in production');
  }
  if (databasePath !== databasePath.trim() || !isAbsolute(databasePath)) {
    throw new Error('COMMUNITY_DATABASE_PATH must be an absolute file path in production');
  }
  const parsedPath = parse(resolve(databasePath));
  if (
    databasePath.endsWith('/')
    || databasePath.endsWith('\\')
    || !parsedPath.base
    || parsedPath.base === '.'
    || parsedPath.base === '..'
    || (existsSync(databasePath) && !statSync(databasePath).isFile())
  ) {
    throw new Error('COMMUNITY_DATABASE_PATH must point to a database file in production');
  }
  validateBackupConfiguration({
    databasePath,
    backupDirectory,
    retentionDays: backupRetentionDays,
    intervalHours: backupIntervalHours,
  });
  const normalizedSupportEmail = String(supportEmail ?? '').trim().toLowerCase();
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(normalizedSupportEmail)) {
    throw new Error('COMMUNITY_SUPPORT_EMAIL must be a valid email address in production');
  }
  if (emailVerificationRequired && !emailSenderConfigured) {
    validateSmtpConfiguration(smtpConfiguration);
  }
}

function nowIso() {
  return new Date().toISOString();
}

function normalizeBasePath(value) {
  return value.endsWith('/') ? value.slice(0, -1) : value;
}

function numericConfiguration(value, fallback, name, { integer = false } = {}) {
  if (value == null || value === '') return fallback;
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || (integer && !Number.isInteger(parsed))) {
    throw new Error(`${name} must be a valid number`);
  }
  return parsed;
}

function positiveIntegerConfiguration(value, fallback, name) {
  const parsed = numericConfiguration(value, fallback, name, { integer: true });
  if (parsed <= 0) throw new Error(`${name} must be a positive integer`);
  return parsed;
}

export function configuredServerPort(value) {
  const text = String(value ?? '').trim();
  if (!text) return 27861;
  if (!/^\d+$/.test(text)) {
    throw new Error('PORT must be an integer between 1 and 65535');
  }
  const port = Number(text);
  if (!Number.isSafeInteger(port) || port < 1 || port > 65_535) {
    throw new Error('PORT must be an integer between 1 and 65535');
  }
  return port;
}

export function resolveTencentLiveConfiguration(value = {}) {
  const raw = {
    pushDomain: String(value.pushDomain ?? '').trim().toLowerCase(),
    playbackDomain: String(value.playbackDomain ?? '').trim().toLowerCase(),
    pushKey: String(value.pushKey ?? '').trim(),
    playbackKey: String(value.playbackKey ?? '').trim(),
    licenseUrl: String(value.licenseUrl ?? '').trim(),
    appName: String(value.appName ?? 'live').trim(),
  };
  const configured = Object.entries(raw)
    .filter(([key]) => key !== 'appName')
    .some(([, item]) => item !== '');
  if (!configured) return null;
  for (const key of [
    'pushDomain',
    'playbackDomain',
    'pushKey',
    'playbackKey',
    'licenseUrl',
  ]) {
    if (!raw[key]) throw new Error(`STUDIO_TENCENT_LIVE_${key} is required`);
  }
  for (const [name, host] of [
    ['pushDomain', raw.pushDomain],
    ['playbackDomain', raw.playbackDomain],
  ]) {
    if (
      host.length > 253
      || host.includes('/')
      || host.includes(':')
      || !/^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/.test(host)
      || !host.includes('.')
    ) {
      throw new Error(`STUDIO_TENCENT_LIVE_${name} must be a DNS hostname`);
    }
  }
  if (raw.pushDomain === raw.playbackDomain) {
    throw new Error('Tencent live push and playback domains must be different');
  }
  if (raw.pushKey.length < 8 || raw.playbackKey.length < 8) {
    throw new Error('Tencent live authentication keys must contain at least 8 characters');
  }
  if (!/^[A-Za-z0-9_-]{1,32}$/.test(raw.appName)) {
    throw new Error('STUDIO_TENCENT_LIVE_APP_NAME contains unsupported characters');
  }
  let licenseUrl;
  try {
    licenseUrl = new URL(raw.licenseUrl);
  } catch {
    throw new Error('STUDIO_TENCENT_PLAYER_LICENSE_URL must be a valid HTTPS URL');
  }
  if (licenseUrl.protocol !== 'https:' || licenseUrl.username || licenseUrl.password) {
    throw new Error('STUDIO_TENCENT_PLAYER_LICENSE_URL must be a valid HTTPS URL');
  }
  return { ...raw, licenseUrl: licenseUrl.toString() };
}

export function resolveOpenStreamConfiguration(value = {}) {
  const raw = {
    enabled: String(value.enabled ?? '').trim().toLowerCase(),
    rtmpBaseUrl: String(value.rtmpBaseUrl ?? '').trim(),
    hlsBaseUrl: String(value.hlsBaseUrl ?? '').trim(),
  };
  const configured = raw.enabled === 'true'
    || raw.rtmpBaseUrl !== ''
    || raw.hlsBaseUrl !== '';
  if (!configured || raw.enabled === 'false') return null;
  if (!raw.rtmpBaseUrl || !raw.hlsBaseUrl) {
    throw new Error(
      'STUDIO_OPEN_STREAM_RTMP_BASE_URL and STUDIO_OPEN_STREAM_HLS_BASE_URL are required',
    );
  }
  let rtmpBaseUrl;
  let hlsBaseUrl;
  try {
    rtmpBaseUrl = new URL(raw.rtmpBaseUrl);
    hlsBaseUrl = new URL(raw.hlsBaseUrl);
  } catch {
    throw new Error('STUDIO_OPEN_STREAM_*_BASE_URL must be valid URLs');
  }
  if (
    !['rtmp:', 'rtmps:'].includes(rtmpBaseUrl.protocol)
    || rtmpBaseUrl.username
    || rtmpBaseUrl.password
    || !rtmpBaseUrl.hostname
  ) {
    throw new Error('STUDIO_OPEN_STREAM_RTMP_BASE_URL must use rtmp or rtmps');
  }
  if (
    hlsBaseUrl.protocol !== 'https:'
    || hlsBaseUrl.username
    || hlsBaseUrl.password
    || !hlsBaseUrl.hostname
  ) {
    throw new Error('STUDIO_OPEN_STREAM_HLS_BASE_URL must use HTTPS');
  }
  if (!rtmpBaseUrl.pathname.endsWith('/')) rtmpBaseUrl.pathname += '/';
  if (!hlsBaseUrl.pathname.endsWith('/')) hlsBaseUrl.pathname += '/';
  return {
    rtmpBaseUrl: rtmpBaseUrl.toString(),
    hlsBaseUrl: hlsBaseUrl.toString(),
  };
}

export function createCachedReadinessCheck(
  check,
  { now = () => Date.now(), ttlMs = DEFAULT_READINESS_CACHE_MS } = {},
) {
  if (typeof check !== 'function') throw new TypeError('check must be a function');
  if (!Number.isFinite(ttlMs) || ttlMs <= 0) {
    throw new TypeError('ttlMs must be positive');
  }
  let cached;
  let checkedAt = Number.NEGATIVE_INFINITY;
  return () => {
    const timestamp = now();
    if (cached !== undefined
        && timestamp >= checkedAt
        && timestamp - checkedAt < ttlMs) {
      return cached;
    }
    cached = check();
    checkedAt = timestamp;
    return cached;
  };
}

function tokenHash(token) {
  return createHash('sha256').update(token).digest('hex');
}

function privateValueHash(value, pepper) {
  return createHmac('sha256', pepper).update(String(value)).digest('hex');
}

function createToken() {
  return randomBytes(32).toString('base64url');
}

function createAccountCode() {
  return String(randomInt(0, 100_000_000)).padStart(8, '0');
}

function passwordHash(password, pepper = '') {
  const salt = randomBytes(16);
  const result = scryptSync(`${password}${pepper}`, salt, 64, {
    N: 16384,
    r: 8,
    p: 1,
    maxmem: 64 * 1024 * 1024,
  });
  return `scrypt$16384$8$1$${salt.toString('base64url')}$${result.toString('base64url')}`;
}

function passwordMatches(password, encoded, pepper = '') {
  if (typeof password !== 'string' || typeof encoded !== 'string') return false;
  const parts = encoded.split('$');
  if (parts.length !== 6 || parts[0] !== 'scrypt') return false;
  const [, nText, rText, pText, saltText, hashText] = parts;
  // Password hashes are persisted data.  Validate all cost parameters before
  // passing them to Node's scrypt implementation; malformed rows must result
  // in a normal authentication failure, not an exception/CPU or memory DoS.
  if (!/^\d+$/.test(nText) || !/^\d+$/.test(rText) || !/^\d+$/.test(pText)) {
    return false;
  }
  const N = Number(nText);
  const r = Number(rText);
  const p = Number(pText);
  if (!Number.isSafeInteger(N) || N < 1024 || N > 1_048_576 || (N & (N - 1)) !== 0
      || !Number.isSafeInteger(r) || r < 1 || r > 32
      || !Number.isSafeInteger(p) || p < 1 || p > 16) {
    return false;
  }
  if (!/^[A-Za-z0-9_-]+$/.test(saltText) || !/^[A-Za-z0-9_-]+$/.test(hashText)) {
    return false;
  }
  let salt;
  let expected;
  try {
    salt = Buffer.from(saltText, 'base64url');
    expected = Buffer.from(hashText, 'base64url');
  } catch {
    return false;
  }
  if (salt.length < 8 || salt.length > 64 || expected.length < 16 || expected.length > 128) {
    return false;
  }
  try {
    const actual = scryptSync(
      `${password}${pepper}`,
      salt,
      expected.length,
      {
        N,
        r,
        p,
        maxmem: 64 * 1024 * 1024,
      },
    );
    return expected.length === actual.length && timingSafeEqual(expected, actual);
  } catch {
    return false;
  }
}

function publicUser(row, allowedImageHosts) {
  return {
    id: row.id,
    email: row.email,
    handle: row.handle,
    displayName: row.display_name,
    avatarUrl: safeStoredPublicImageUrl(row.avatar_url, allowedImageHosts),
    bio: row.bio,
    emailVerified: Boolean(row.email_verified),
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function publicOwner(row, allowedImageHosts) {
  return {
    handle: row.owner_handle,
    displayName: row.owner_display_name,
    avatarUrl: safeStoredPublicImageUrl(row.owner_avatar_url, allowedImageHosts),
  };
}

function publicSupportEntry(row, allowedImageHosts) {
  return {
    id: row.id,
    displayName: row.display_name,
    handle: row.handle,
    avatarUrl: safeStoredPublicImageUrl(row.avatar_url, allowedImageHosts),
    note: row.note || null,
    tier: row.tier || '同行支持',
    redeemedAt: row.redeemed_at,
  };
}

function parseJson(value, fallback) {
  try {
    return JSON.parse(value);
  } catch {
    return fallback;
  }
}

function sanitizedStoredPreset(row, allowedImageHosts) {
  const preset = parseJson(row.preset_json, {});
  const root = preset?.preset && typeof preset.preset === 'object'
    ? preset.preset
    : preset;
  if (root && typeof root === 'object' && root.previewImageUrl != null) {
    root.previewImageUrl = safeStoredPublicImageUrl(
      root.previewImageUrl,
      allowedImageHosts,
    );
  }
  return preset;
}

function publicPreset(row, allowedImageHosts) {
  return {
    id: row.id,
    owner: publicOwner(row, allowedImageHosts),
    ownedByMe: Boolean(row.owned_by_me),
    preset: sanitizedStoredPreset(row, allowedImageHosts),
    visibility: row.visibility,
    moderationStatus: row.moderation_status,
    revision: row.revision,
    versionId: row.content_hash ?? null,
    contentHash: row.content_hash ?? null,
    likes: row.likes,
    downloads: row.downloads,
    applicationCount: Number(row.application_count ?? 0),
    likedByMe: Boolean(row.liked_by_me),
    publishedAt: row.published_at,
    updatedAt: row.updated_at,
  };
}

function stringField(value, name, { min = 1, max = 200, optional = false } = {}) {
  if (value == null && optional) return null;
  if (typeof value !== 'string') {
    throw new ApiError(400, 'invalid_request', `${name} 格式不正确`);
  }
  const result = value.trim();
  if ((!optional || result.length > 0) && (result.length < min || result.length > max)) {
    throw new ApiError(400, 'invalid_request', `${name} 长度需为 ${min}-${max} 个字符`);
  }
  return result;
}

function isBlockedIpv4Literal(address) {
  const parts = address.split('.').map(Number);
  if (parts.length !== 4 || parts.some((part) => !Number.isInteger(part))) {
    return true;
  }
  const [a, b] = parts;
  return a === 0
    || a === 10
    || a === 127
    || (a === 100 && b >= 64 && b <= 127)
    || (a === 169 && b === 254)
    || (a === 172 && b >= 16 && b <= 31)
    || (a === 192 && b === 0)
    || (a === 192 && b === 168)
    || (a === 198 && (b === 18 || b === 19))
    || a >= 224;
}

function mappedIpv4FromIpv6(address) {
  const match = address.match(/^::ffff:([0-9a-f]{1,4}):([0-9a-f]{1,4})$/i);
  if (!match) return null;
  const high = Number.parseInt(match[1], 16);
  const low = Number.parseInt(match[2], 16);
  return `${high >> 8}.${high & 0xff}.${low >> 8}.${low & 0xff}`;
}

function isBlockedIpv6Literal(address) {
  const value = address.toLowerCase();
  if (value === '::' || value === '::1') return true;
  const mappedIpv4 = mappedIpv4FromIpv6(value);
  if (mappedIpv4 != null) return isBlockedIpv4Literal(mappedIpv4);
  const first = Number.parseInt(value.split(':', 1)[0] || '0', 16);
  return (first & 0xfe00) === 0xfc00 // unique-local fc00::/7
    || (first & 0xffc0) === 0xfe80 // link-local fe80::/10
    || (first & 0xff00) === 0xff00 // multicast ff00::/8
    || value.startsWith('2001:db8:')
    || value === '2001:db8::';
}

function isBlockedImageHostname(hostname) {
  const value = hostname.toLowerCase().replace(/\.$/, '');
  const literal = value.startsWith('[') && value.endsWith(']')
    ? value.slice(1, -1)
    : value;
  const ipVersion = isIP(literal);
  if (ipVersion === 4) return isBlockedIpv4Literal(literal);
  if (ipVersion === 6) return isBlockedIpv6Literal(literal);
  if (value === 'localhost' || value.endsWith('.localhost')) return true;
  if (['.local', '.lan', '.internal', '.home', '.arpa']
      .some((suffix) => value.endsWith(suffix))) {
    return true;
  }
  // Public DNS names contain at least one dot. Rejecting single-label names
  // prevents accidental requests to local search-domain hosts.
  if (!value.includes('.')) return true;
  return value.length > 253 || value.split('.').some((label) => (
    label.length === 0
    || label.length > 63
    || !/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/i.test(label)
  ));
}

function configuredPublicImageHosts(value) {
  const entries = Array.isArray(value)
    ? value
    : String(value ?? '').split(',');
  const hosts = new Set();
  for (const entry of entries) {
    const host = String(entry).trim().toLowerCase().replace(/\.$/, '');
    if (!host) continue;
    if (host.includes('/') || host.includes(':') || isBlockedImageHostname(host)) {
      throw new Error('COMMUNITY_PUBLIC_IMAGE_HOSTS must contain public hostnames only');
    }
    hosts.add(host);
  }
  return hosts;
}

export function validatePublicImageUrl(
  value,
  name = '图片地址',
  allowedImageHosts = new Set(),
) {
  const text = stringField(value, name, { max: 1000, optional: true });
  if (!text) return '';
  let url;
  try {
    url = new URL(text);
  } catch {
    throw new ApiError(400, 'invalid_image_url', `${name}格式不正确`);
  }
  if (url.protocol !== 'https:'
      || url.username
      || url.password
      || url.hash
      || isBlockedImageHostname(url.hostname)
      || !allowedImageHosts.has(url.hostname.toLowerCase().replace(/\.$/, ''))) {
    throw new ApiError(
      400,
      'invalid_image_url',
      `${name}必须是无凭据、无片段的公网 HTTPS 地址`,
    );
  }
  return url.href;
}

function safeStoredPublicImageUrl(value, allowedImageHosts) {
  if (!value) return null;
  try {
    return validatePublicImageUrl(value, '图片地址', allowedImageHosts);
  } catch {
    return null;
  }
}

function passwordField(value, { min }) {
  if (typeof value !== 'string') {
    throw new ApiError(400, 'invalid_request', '密码格式不正确');
  }
  if (value.length < min || value.length > 128) {
    throw new ApiError(400, 'invalid_request', `密码长度需为 ${min}-128 个字符`);
  }
  return value;
}

function assertOnlyKeys(body, allowedKeys) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    throw new ApiError(400, 'invalid_request', '请求体必须是 JSON 对象');
  }
  for (const key of Object.keys(body)) {
    if (!allowedKeys.has(key)) {
      throw new ApiError(400, 'forbidden_field', `字段 ${key} 不允许客户端指定`);
    }
  }
}

function assertPersonalInventoryRecordKeys(record) {
  for (const key of Object.keys(record)) {
    if (PERSONAL_INVENTORY_RECORD_KEYS.has(key)) continue;
    // This endpoint stores the inventory contract only. In particular, raw
    // RFID blocks, MIFARE keys, signatures, and other credentials are never
    // accepted as an "extra" record field.
    if (/(?:rfid|mifare|nfc|sector|block|key|secret|signature|dump|credential|raw)/i.test(key)) {
      throw new ApiError(
        400,
        'forbidden_field',
        '个人库存同步不接受 RFID 原始数据、密钥或签名',
      );
    }
    throw new ApiError(400, 'forbidden_field', `个人库存记录字段 ${key} 不允许`);
  }
}

function personalInventoryText(value, name, { required = false, max = 128 } = {}) {
  if (value == null) {
    if (required) throw new ApiError(400, 'invalid_inventory_record', `${name}不能为空`);
    return null;
  }
  if (typeof value !== 'string') {
    throw new ApiError(400, 'invalid_inventory_record', `${name}格式不正确`);
  }
  const normalized = value.trim();
  if (/[\u0000-\u001f\u007f]/.test(normalized)) {
    throw new ApiError(400, 'invalid_inventory_record', `${name}包含不支持的字符`);
  }
  if (normalized.length === 0) {
    if (required) throw new ApiError(400, 'invalid_inventory_record', `${name}不能为空`);
    return null;
  }
  if (normalized.length > max) {
    throw new ApiError(400, 'invalid_inventory_record', `${name}长度不能超过${max}个字符`);
  }
  return normalized;
}

function personalInventoryNumber(value, name, { required = false, min = -Infinity, max = Infinity } = {}) {
  if (value == null) {
    if (required) throw new ApiError(400, 'invalid_inventory_record', `${name}不能为空`);
    return null;
  }
  if (typeof value !== 'number' || !Number.isFinite(value) || value < min || value > max) {
    throw new ApiError(400, 'invalid_inventory_record', `${name}数值不正确`);
  }
  return value;
}

function personalInventoryInteger(value, name, { required = false, min = 0, max = Number.MAX_SAFE_INTEGER } = {}) {
  if (value == null) {
    if (required) throw new ApiError(400, 'invalid_inventory_record', `${name}不能为空`);
    return null;
  }
  if (!Number.isSafeInteger(value) || value < min || value > max) {
    throw new ApiError(400, 'invalid_inventory_record', `${name}必须是有效整数`);
  }
  return value;
}

function personalInventoryDate(value, name, { required = false } = {}) {
  if (value == null) {
    if (required) throw new ApiError(400, 'invalid_inventory_record', `${name}不能为空`);
    return null;
  }
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new ApiError(400, 'invalid_inventory_record', `${name}格式不正确`);
  }
  const timestamp = Date.parse(value);
  if (!Number.isFinite(timestamp)) {
    throw new ApiError(400, 'invalid_inventory_record', `${name}格式不正确`);
  }
  return new Date(timestamp).toISOString();
}

// CUID/FUID readers disagree on separators and case. Store one compact
// identity so snapshots from Android and Windows can be compared directly.
function normalizePersonalInventoryRfidTag(value) {
  const text = personalInventoryText(value, 'rfidTagUid', { max: 128 });
  if (text == null) return null;
  // Remove only reader formatting separators. Stripping every non-hex
  // character would turn an opaque ID such as `CUID-OWNER-1` into a
  // different, colliding value.
  const compact = text.replace(/[\s:._-]/g, '');
  if (compact.length >= 4 && compact.length % 2 === 0 && /^[0-9a-f]+$/i.test(compact)) {
    return compact.toUpperCase();
  }
  return text.replace(/\s+/g, ' ');
}

function normalizePersonalInventoryColor(value) {
  const text = personalInventoryText(value, 'colorHex', { required: true, max: 9 });
  if (!/^#[0-9a-f]{3}(?:[0-9a-f]{3}|[0-9a-f]{5})?$/i.test(text)) {
    throw new ApiError(400, 'invalid_inventory_record', 'colorHex必须是 #RGB、#RRGGBB 或 #RRGGBBAA');
  }
  let hex = text.slice(1).toUpperCase();
  if (hex.length === 3) {
    hex = hex.split('').map((value) => `${value}${value}`).join('');
  }
  return `#${hex}`;
}

function normalizePersonalInventoryTagHistory(value) {
  if (value == null) return [];
  if (!Array.isArray(value) || value.length > 32) {
    throw new ApiError(400, 'invalid_inventory_tag_history', '标签换绑历史最多保留 32 次');
  }
  const keys = new Set(['tagUid', 'tagType', 'cycle', 'previousInventoryUid']);
  return value.map((entry) => {
    if (!entry || typeof entry !== 'object' || Array.isArray(entry)
        || Object.keys(entry).some((key) => !keys.has(key))) {
      throw new ApiError(400, 'invalid_inventory_tag_history', '标签换绑历史字段不正确');
    }
    const tagUid = normalizePersonalInventoryRfidTag(entry.tagUid);
    const cycle = personalInventoryInteger(entry.cycle, 'cycle', { min: 1, max: 1_000_000 });
    if (!tagUid || cycle == null) throw new ApiError(400, 'invalid_inventory_tag_history', '标签历史缺少 UID 或周期');
    return {
      tagUid,
      tagType: personalInventoryText(entry.tagType, 'tagType', { max: 32 }),
      cycle,
      previousInventoryUid: personalInventoryText(entry.previousInventoryUid, 'previousInventoryUid', { max: 128 }),
    };
  });
}

function personalInventoryBindings(record) {
  return [record, ...(record.rfidTagHistory ?? []).map((old) => ({
    uid: record.uid, rfidTagUid: old.tagUid, rfidTagType: old.tagType,
    rfidTagCycle: old.cycle, previousConsumableUid: old.previousInventoryUid,
    lifecycleStatus: 'replaced', archivedBinding: true,
  }))];
}

function samePersonalInventoryBinding(left, right) {
  return normalizePersonalInventoryRfidTag(left.rfidTagUid)?.toLowerCase()
      === normalizePersonalInventoryRfidTag(right.rfidTagUid)?.toLowerCase()
    && Number(left.rfidTagCycle ?? 1) === Number(right.rfidTagCycle ?? 1)
    && String(left.previousConsumableUid ?? '').toLowerCase()
      === String(right.previousConsumableUid ?? '').toLowerCase();
}

const STOCK_SOURCE_KEYS = [
  'sourceRfidTagUid', 'sourceRfidTagType', 'stockReceiptUid',
  'stockReceiptIndex', 'stockReceiptQuantity',
];

// Business invariant: one physical spool is always 1 kg. Aggregate rows may
// contain N spools; the threshold below governs reusing a physical remainder.
const PERSONAL_SPOOL_CAPACITY_GRAMS = 1000;
const MINIMUM_REUSABLE_SPOOL_GRAMS = 30;

function isStandardPersonalSpool(record) {
  return record.totalGrams === PERSONAL_SPOOL_CAPACITY_GRAMS
    && Number.isFinite(record.remainingGrams)
    && record.remainingGrams >= 0
    && record.remainingGrams <= PERSONAL_SPOOL_CAPACITY_GRAMS;
}

function canReusePersonalSpool(record) {
  return isStandardPersonalSpool(record)
    && record.remainingGrams > MINIMUM_REUSABLE_SPOOL_GRAMS;
}

function assertPersonalSpoolCapacity(records, currentRecords) {
  const current = personalInventoryRecordMap(currentRecords);
  for (const record of records) {
    const stored = current.get(uidForRecord(record));
    const individual = record.rfidTagUid != null || record.stockReceiptUid != null
      || stored?.rfidTagUid != null || stored?.stockReceiptUid != null;
    if (!individual || isStandardPersonalSpool(record)) continue;
    // Preserve existing non-standard historical balances verbatim. They may
    // be archived, but cannot become new stock, be refilled or be reactivated.
    const preservingHistory = stored && !isStandardPersonalSpool(stored)
      && record.totalGrams === stored.totalGrams
      && record.remainingGrams === stored.remainingGrams
      && samePersonalInventoryBinding(stored, record)
      && JSON.stringify(record.rfidTagHistory ?? []) === JSON.stringify(stored.rfidTagHistory ?? [])
      && STOCK_SOURCE_KEYS.every((key) => record[key] === stored[key])
      && (record.lifecycleStatus === stored.lifecycleStatus || record.lifecycleStatus === 'retired');
    if (!preservingHistory) {
      throw new ApiError(409, 'inventory_spool_capacity_conflict',
        '每卷规格固定为 1000 g，余量须在 0 至 1000 g；历史异常重量已保留，请先核对');
    }
  }
}

function normalizePersonalStockSource(record) {
  if (STOCK_SOURCE_KEYS.every((key) => record[key] == null)) return {};
  const tag = normalizePersonalInventoryRfidTag(record.sourceRfidTagUid);
  const manual = record.sourceRfidTagUid == null && record.sourceRfidTagType == null;
  const type = manual ? null : personalInventoryText(record.sourceRfidTagType, 'sourceRfidTagType', { required: true, max: 32 }).toUpperCase();
  const receipt = personalInventoryText(record.stockReceiptUid, 'stockReceiptUid', { required: true, max: 36 }).toLowerCase();
  const quantity = personalInventoryInteger(record.stockReceiptQuantity, 'stockReceiptQuantity', { required: true, min: 1, max: 100 });
  const index = personalInventoryInteger(record.stockReceiptIndex, 'stockReceiptIndex', { required: true, min: 0, max: quantity - 1 });
  if (!manual && (!['CUID', 'FUID'].includes(type) || !/^[0-9A-F]{8}$/.test(tag ?? ''))) {
    throw new ApiError(400, 'unsupported_inventory_tag_type', '耗材来源卡只支持 4 字节 CUID/FUID，NTAG213 用于设备工作台');
  }
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(receipt)) {
    throw new ApiError(400, 'invalid_stock_receipt', '每次明确入库需要独立操作 UUID');
  }
  return { sourceRfidTagUid: tag, sourceRfidTagType: type,
    stockReceiptUid: receipt, stockReceiptIndex: index, stockReceiptQuantity: quantity };
}

function normalizePersonalInventoryRecord(record) {
  if (!record || typeof record !== 'object' || Array.isArray(record)) {
    throw new ApiError(400, 'invalid_inventory_record', '个人库存记录必须是对象');
  }
  assertPersonalInventoryRecordKeys(record);
  const totalGrams = personalInventoryNumber(
    record.totalGrams,
    'totalGrams',
    { required: true, min: Number.EPSILON, max: 100_000 },
  );
  const remainingGrams = personalInventoryNumber(
    record.remainingGrams,
    'remainingGrams',
    { required: true, min: 0, max: 100_000 },
  );
  // Untagged personal rows are aggregate stock and may legitimately contain
  // several 1000 g rolls after a replenishment. Physical spools are validated
  // against the fixed capacity after existing historical rows are available.
  const hygroscopicity = personalInventoryText(
    record.hygroscopicity,
    'hygroscopicity',
    { max: 16 },
  );
  if (hygroscopicity != null && !['high', 'medium', 'low'].includes(hygroscopicity)) {
    throw new ApiError(400, 'invalid_inventory_record', 'hygroscopicity取值不正确');
  }
  const rawTagUid = normalizePersonalInventoryRfidTag(record.rfidTagUid);
  const stockSource = normalizePersonalStockSource(record);
  const rfidTagHistory = normalizePersonalInventoryTagHistory(record.rfidTagHistory);
  if (rfidTagHistory.length && !rawTagUid) {
    throw new ApiError(400, 'invalid_inventory_tag_history', '保留标签关联历史的卷必须有当前标签');
  }
  const rawTagType = personalInventoryText(record.rfidTagType, 'rfidTagType', { max: 32 });
  if (rawTagUid == null && rawTagType != null) {
    throw new ApiError(400, 'invalid_inventory_record', '没有 rfidTagUid 时不能填写 rfidTagType');
  }
  const lifecycleStatus = personalInventoryText(record.lifecycleStatus, 'lifecycleStatus', { max: 16 })
    ?? (remainingGrams <= 0 ? 'depleted' : 'active');
  if (!['active', 'depleted', 'replaced', 'retired'].includes(lifecycleStatus)) {
    throw new ApiError(400, 'invalid_inventory_record', 'lifecycleStatus取值不正确');
  }
  const rfidTagCycle = personalInventoryInteger(record.rfidTagCycle, 'rfidTagCycle', {
    min: 1,
    max: 1_000_000,
  }) ?? 1;
  // A reusable card may return to the same physical remnant after serving
  // another roll. The immutable identity is (card, cycle), not the card alone.
  // Keep that roll's associations in chronological order; the complete graph
  // below still requires every intervening predecessor and successor.
  const latestHistoryCycle = new Map();
  for (const old of rfidTagHistory) {
    const key = old.tagUid.toLowerCase();
    if (!/^[0-9A-F]{8}$/.test(old.tagUid)
        || !['CUID', 'FUID'].includes(old.tagType?.toUpperCase())
        || old.cycle <= (latestHistoryCycle.get(key) ?? 0)) {
      throw new ApiError(400, 'invalid_inventory_tag_history', '标签历史必须保留有效且依次递增的 CUID/FUID 关联周期');
    }
    latestHistoryCycle.set(key, old.cycle);
  }
  if (rawTagUid && rfidTagCycle <= (latestHistoryCycle.get(rawTagUid.toLowerCase()) ?? 0)) {
    throw new ApiError(400, 'invalid_inventory_tag_history', '再次使用同一标签必须建立后续关联周期');
  }
  const previousConsumableUid = personalInventoryText(
    record.previousConsumableUid,
    'previousConsumableUid',
    { max: 128 },
  );
  if (rawTagUid == null && (rfidTagCycle !== 1 || previousConsumableUid != null)) {
    throw new ApiError(
      400,
      'invalid_inventory_record',
      '没有 RFID 标签的库存记录只能使用周期 1 且不能填写前驱卷',
    );
  }
  if ((rawTagUid != null || stockSource.stockReceiptUid) && remainingGrams > totalGrams) {
    throw new ApiError(400, 'invalid_inventory_record', '带 RFID 标签的单卷余量不能大于初始净重');
  }
  if (lifecycleStatus === 'active' && remainingGrams <= 0) {
    throw new ApiError(400, 'invalid_inventory_record', 'active 耗材必须仍有可用余量');
  }
  if (lifecycleStatus === 'depleted' && remainingGrams > 0) {
    throw new ApiError(400, 'invalid_inventory_record', 'depleted 耗材余量必须为 0');
  }
  return {
    uid: personalInventoryText(record.uid, 'uid', { required: true, max: 128 }),
    manufacturer: personalInventoryText(record.manufacturer, 'manufacturer', { required: true, max: 64 }),
    model: personalInventoryText(record.model, 'model', { required: true, max: 64 }),
    materialType: personalInventoryText(record.materialType, 'materialType', { required: true, max: 64 }),
    colorHex: normalizePersonalInventoryColor(record.colorHex),
    colorName: personalInventoryText(record.colorName, 'colorName', { max: 80 }),
    totalGrams,
    remainingGrams,
    batchNo: personalInventoryText(record.batchNo, 'batchNo', { max: 128 }),
    purchaseDate: personalInventoryDate(record.purchaseDate, 'purchaseDate'),
    note: personalInventoryText(record.note, 'note', { max: 1000 }),
    createdAt: personalInventoryDate(record.createdAt, 'createdAt', { required: true }),
    updatedAt: personalInventoryDate(record.updatedAt, 'updatedAt', { required: true }),
    density: personalInventoryNumber(record.density, 'density', { min: Number.EPSILON, max: 20 }),
    recommendedNozzleTemp: personalInventoryNumber(
      record.recommendedNozzleTemp,
      'recommendedNozzleTemp',
      { min: 0, max: 500 },
    ),
    hygroscopicity,
    trayUuid: personalInventoryText(record.trayUuid, 'trayUuid', { max: 128 }),
    rfidSyncedAt: personalInventoryInteger(record.rfidSyncedAt, 'rfidSyncedAt'),
    rfidTagUid: rawTagUid,
    // Keep the spelling supplied by the reader for display, but comparisons
    // below are case-insensitive. Unknown future reader types remain valid.
    rfidTagType: rawTagUid == null ? null : rawTagType,
    rfidTagCycle: rawTagUid == null ? 1 : rfidTagCycle,
    lifecycleStatus,
    previousConsumableUid: rawTagUid == null ? null : previousConsumableUid,
    ...(rfidTagHistory.length ? { rfidTagHistory } : {}),
    ...stockSource,
  };
}

function normalizePersonalInventoryRecords(records) {
  if (!Array.isArray(records)) {
    throw new ApiError(400, 'invalid_inventory_snapshot', 'records必须是数组');
  }
  if (records.length > MAX_PERSONAL_INVENTORY_RECORDS) {
    throw new ApiError(
      413,
      'inventory_snapshot_too_large',
      `个人库存最多同步${MAX_PERSONAL_INVENTORY_RECORDS}卷耗材`,
    );
  }
  const seenUids = new Set();
  const seenTagCycles = new Set();
  const activeTags = new Set();
  const tagTypes = new Map();
  const normalizedRecords = records.map((record) => {
    const normalized = normalizePersonalInventoryRecord(record);
    const uidKey = normalized.uid.toLowerCase();
    if (seenUids.has(uidKey)) {
      throw new ApiError(400, 'duplicate_inventory_uid', '个人库存中不能有重复的 uid');
    }
    seenUids.add(uidKey);
    for (const binding of personalInventoryBindings(normalized)) {
      if (binding.rfidTagUid == null) continue;
      const normalized = binding;
      const tagKey = normalized.rfidTagUid.toLowerCase();
      const cycleKey = `${tagKey}\u0000${normalized.rfidTagCycle}`;
      if (normalized.lifecycleStatus !== 'retired' && seenTagCycles.has(cycleKey)) {
        throw new ApiError(
          409,
          'inventory_tag_cycle_conflict',
          '同一 RFID 标签的同一周期只能对应一卷耗材',
          { tagUid: normalized.rfidTagUid, cycle: normalized.rfidTagCycle },
        );
      }
      if (normalized.lifecycleStatus !== 'retired') seenTagCycles.add(cycleKey);
      if (normalized.lifecycleStatus === 'active') {
        if (activeTags.has(tagKey)) {
          throw new ApiError(
            409,
            'inventory_tag_active_conflict',
            '同一 RFID 标签不能同时存在多卷 active 耗材',
            { tagUid: normalized.rfidTagUid },
          );
        }
        activeTags.add(tagKey);
      }
      const existingType = tagTypes.get(tagKey);
      const knownType = normalized.rfidTagType?.toLowerCase();
      if (existingType != null && knownType != null && knownType !== 'unknown' && existingType !== knownType) {
        throw new ApiError(
          400,
          'inventory_tag_type_conflict',
          '同一 RFID 标签不能在不同周期使用不同标签类型',
          { tagUid: normalized.rfidTagUid },
        );
      }
      if (knownType != null && knownType !== 'unknown') tagTypes.set(tagKey, knownType);
    }
    return normalized;
  });
  return normalizedRecords;
}

function personalInventoryRecordMap(records) {
  const map = new Map();
  for (const record of Array.isArray(records) ? records : []) {
    if (!record || typeof record !== 'object') continue;
    const uid = typeof record.uid === 'string' ? record.uid.trim().toLowerCase() : '';
    if (uid) map.set(uid, record);
  }
  return map;
}

/**
 * Validate the graph formed by reusable RFID cycles. The current server
 * snapshot is included so a client may update only the newest row while still
 * referencing a predecessor that is already stored remotely.
 */
function assertPersonalInventoryLifecycleGraph(records, currentRecords = []) {
  const incoming = personalInventoryRecordMap(records);
  const current = personalInventoryRecordMap(currentRecords);
  const all = new Map(current);
  for (const [uid, record] of incoming) all.set(uid, record);

  const activeByTag = new Map();
  for (const record of incoming.values()) {
    const tag = record.rfidTagUid;
    if (tag == null) continue;
    const tagKey = tag.toLowerCase();
    const stored = current.get(uidForRecord(record));
    const type = record.rfidTagType?.trim().toUpperCase() ?? '';
    const storedType = stored?.rfidTagType?.trim().toUpperCase() ?? '';
    const consumableType = ['CUID', 'FUID'].includes(type);
    const legacyUnconfirmed = ['', 'CLASSIC', 'MIFARE_CLASSIC', 'MIFARE_CLASSIC_1K', 'MIFARE CLASSIC', 'MIFARE CLASSIC 1K'].includes(storedType);
    const supportedType = consumableType || type === 'AMS';
    const sameStoredBinding = stored?.rfidTagUid && samePersonalInventoryBinding(stored, record)
      && JSON.stringify(stored.rfidTagHistory ?? []) === JSON.stringify(record.rfidTagHistory ?? []);
    const activating = !sameStoredBinding || (stored?.lifecycleStatus !== 'active' && record.lifecycleStatus === 'active');
    if (record.lifecycleStatus === 'active' && activating && !canReusePersonalSpool(record)) {
      throw new ApiError(409, 'inventory_spool_not_reusable',
        '每卷规格固定为 1000 g，余量必须大于 30 g 才能装入或继续使用');
    }
    if (!stored?.rfidTagUid && !supportedType) {
      throw new ApiError(400, 'unsupported_inventory_tag_type', '自定义耗材标签只支持已确认的 CUID/FUID，NTAG213 用于设备工作台');
    }
    if (stored?.rfidTagUid && !['CUID', 'FUID', 'AMS'].includes(storedType)) {
      const confirmingLegacy = legacyUnconfirmed && consumableType && sameStoredBinding
        && record.remainingGrams === stored.remainingGrams && record.totalGrams === stored.totalGrams
        && record.lifecycleStatus === stored.lifecycleStatus;
      const preservingHistory = type === storedType && sameStoredBinding
        && record.remainingGrams === stored.remainingGrams && record.totalGrams === stored.totalGrams
        && ['manufacturer', 'model', 'materialType', 'colorHex', 'colorName', 'batchNo',
          'purchaseDate', 'note', 'density', 'recommendedNozzleTemp', 'hygroscopicity', 'trayUuid']
          .every((field) => JSON.stringify(record[field] ?? null) === JSON.stringify(stored[field] ?? null))
        && (record.lifecycleStatus === stored.lifecycleStatus || record.lifecycleStatus === 'retired');
      if (!confirmingLegacy && !preservingHistory) {
        throw new ApiError(409, 'unsupported_inventory_tag_type', '未确认卡型或 NTAG 历史只能保留核对，不能继续标签耗材操作');
      }
    } else if (stored?.rfidTagUid && !supportedType) {
      throw new ApiError(409, 'unsupported_inventory_tag_type', '不能把耗材标签改为 NTAG213 或未确认卡型');
    }
    if (!stored?.rfidTagUid && consumableType && [...current.values()].some((previous) =>
      previous.rfidTagUid?.toLowerCase() === tagKey
      && !['CUID', 'FUID'].includes(previous.rfidTagType?.trim().toUpperCase()))) {
      throw new ApiError(409, 'unsupported_inventory_tag_type', '该标签已有其他用途或未确认的历史，不能创建新耗材周期');
    }
    if (stored?.rfidTagUid) {
      const oldHistory = stored.rfidTagHistory ?? [];
      const history = record.rfidTagHistory ?? [];
      const prefixRetained = history.length >= oldHistory.length
        && oldHistory.every((old, index) => JSON.stringify(old) === JSON.stringify(history[index]));
      const rebound = history.length > oldHistory.length;
      const prior = rebound ? personalInventoryBindings(record)[oldHistory.length + 1] : null;
      if (!prefixRetained || (rebound ? !samePersonalInventoryBinding(stored, prior) : !samePersonalInventoryBinding(stored, record))) {
        throw new ApiError(409, 'inventory_spool_identity_conflict', '已登记卷的标签、周期和前驱不能被改写，请创建新卷');
      }
      if (rebound && (!['CUID', 'FUID'].includes(storedType) || stored.lifecycleStatus === 'retired' || !canReusePersonalSpool(stored)
          || !canReusePersonalSpool(record)
          || record.totalGrams !== stored.totalGrams || record.remainingGrams > stored.remainingGrams
          || !/^[0-9A-F]{8}$/.test(record.rfidTagUid) || !['CUID', 'FUID'].includes(record.rfidTagType?.toUpperCase()))) {
        throw new ApiError(409, 'inventory_rebind_conflict', '只有余量大于 30 g 的 1000 g 未归档卷可以换绑，余量不能因此增加');
      }
      if (!rebound && ['replaced', 'retired'].includes(stored.lifecycleStatus)
          && !['replaced', 'retired'].includes(record.lifecycleStatus)) {
        throw new ApiError(409, 'inventory_history_reactivation', '已结束标签关联的历史卷不能重新参与自动扣料');
      }
    }
  }
  const bindings = [...all.values()].flatMap(personalInventoryBindings);
  const successorKeys = new Set(bindings.filter((binding) => binding.previousConsumableUid != null)
    .map((binding) => JSON.stringify([binding.rfidTagUid?.toLowerCase(), binding.rfidTagCycle - 1, binding.previousConsumableUid.toLowerCase()])));
  for (const record of bindings) {
    const tag = record.rfidTagUid;
    if (tag == null) continue;
    const tagKey = tag.toLowerCase();
    if (record.archivedBinding && !successorKeys.has(JSON.stringify([tagKey, record.rfidTagCycle, uidForRecord(record)]))) {
      throw new ApiError(409, 'inventory_rebind_successor_missing', '旧标签尚未转移到下一卷，不能换绑余料');
    }
    if (record.lifecycleStatus === 'active') {
      const previous = activeByTag.get(tagKey);
      if (previous != null && previous !== uidForRecord(record)) {
        throw new ApiError(409, 'inventory_tag_active_conflict', '同一 RFID 标签不能同时存在多卷 active 耗材', { tagUid: tag });
      }
      activeByTag.set(tagKey, uidForRecord(record));
    }
    const cycle = Number(record.rfidTagCycle);
    const previousUid = record.previousConsumableUid;
    if (cycle === 1) {
      if (previousUid != null) {
        throw new ApiError(400, 'invalid_inventory_lifecycle', 'RFID 第 1 周期不能有前驱卷');
      }
      continue;
    }
    if (previousUid == null) {
      throw new ApiError(400, 'invalid_inventory_lifecycle', 'RFID 后续周期必须记录 previousConsumableUid');
    }
    const previousRecord = all.get(previousUid.toLowerCase());
    if (previousRecord == null) {
      throw new ApiError(409, 'inventory_predecessor_missing', 'RFID 周期前驱卷不在服务器历史中', { uid: previousUid });
    }
    const previous = personalInventoryBindings(previousRecord).find((binding) =>
      binding.rfidTagUid?.toLowerCase() === tagKey && Number(binding.rfidTagCycle) === cycle - 1)
      ?? previousRecord;
    if (previous.uid.toLowerCase() === record.uid.toLowerCase()) {
      throw new ApiError(400, 'invalid_inventory_lifecycle', '耗材卷不能以前驱自身作为下一周期');
    }
    if (previous.rfidTagUid == null || previous.rfidTagUid.toLowerCase() !== tagKey) {
      throw new ApiError(400, 'invalid_inventory_lifecycle', '前驱卷必须使用同一 RFID 标签');
    }
    if (Number(previous.rfidTagCycle) !== cycle - 1) {
      throw new ApiError(400, 'invalid_inventory_lifecycle', 'RFID 周期必须连续递增');
    }
    if (previous.lifecycleStatus === 'active') {
      throw new ApiError(400, 'invalid_inventory_lifecycle', '创建下一周期前必须先结束前一卷耗材');
    }
  }
}

function uidForRecord(record) {
  return String(record?.uid ?? '').trim().toLowerCase();
}

/** Source cards are reusable. Only a receipt item, not a card UID, is unique.
 * Receipt identities survive deletion of the inventory snapshot row so an
 * old confirmation can never create a fresh batch after a retry/restore. */
function retainAndRecordPersonalStockReceipts(database, userId, records, currentRecords, timestamp) {
  const current = personalInventoryRecordMap(currentRecords);
  const find = database.prepare(`SELECT * FROM personal_stock_receipt_items
    WHERE user_id = ? AND receipt_uid = ? AND item_index = ?`);
  const findInventory = database.prepare(`SELECT * FROM personal_stock_receipt_items
    WHERE user_id = ? AND inventory_uid = ?`);
  const findBatch = database.prepare(`SELECT source_tag_uid, source_tag_type, quantity
    FROM personal_stock_receipt_items WHERE user_id = ? AND receipt_uid = ? LIMIT 1`);
  const insert = database.prepare(`INSERT OR IGNORE INTO personal_stock_receipt_items
    (user_id, receipt_uid, item_index, inventory_uid, source_tag_uid, source_tag_type, quantity, created_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)`);
  for (const record of records) {
    const previous = current.get(uidForRecord(record));
    if (previous?.stockReceiptUid) {
      if (!record.stockReceiptUid) {
        // An older client may omit provenance but must never clear it.
        for (const key of STOCK_SOURCE_KEYS) record[key] = previous[key];
      } else if (STOCK_SOURCE_KEYS.some((key) => record[key] !== previous[key])) {
        throw new ApiError(409, 'inventory_stock_receipt_conflict', '库存来源卡和入库批次不可改写');
      }
    }
    const source = normalizePersonalStockSource(record);
    const knownInventory = findInventory.get(userId, uidForRecord(record));
    if (!source.stockReceiptUid) {
      if (knownInventory) throw new ApiError(409, 'inventory_stock_receipt_conflict', '已登记卷不能清除入库来源');
      continue;
    }
    if (record.remainingGrams > record.totalGrams) {
      throw new ApiError(400, 'invalid_inventory_record', '逐卷入库余量不能超过本卷净重');
    }
    const entry = find.get(userId, source.stockReceiptUid, source.stockReceiptIndex);
    if (entry && !previous) {
      throw new ApiError(409, 'inventory_stock_receipt_consumed', '该批次库存已移除，旧入库请求不能恢复或再建库存');
    }
    const batch = findBatch.get(userId, source.stockReceiptUid);
    // Schema 27 stores a manual receipt's absent card as empty strings.
    // The public contract retains null: no synthetic tag enters RFID identity.
    const sameSource = (item) => item.source_tag_uid === (source.sourceRfidTagUid ?? '')
      && item.source_tag_type === (source.sourceRfidTagType ?? '') && item.quantity === source.stockReceiptQuantity;
    if ((entry && (entry.inventory_uid !== uidForRecord(record) || !sameSource(entry)))
        || (knownInventory && (knownInventory.receipt_uid !== source.stockReceiptUid
          || knownInventory.item_index !== source.stockReceiptIndex || !sameSource(knownInventory)))
        || (batch && !sameSource(batch))) {
      throw new ApiError(409, 'inventory_stock_receipt_conflict', '同一次入库重试不能创建另一卷或改变批次数量');
    }
    insert.run(userId, source.stockReceiptUid, source.stockReceiptIndex, uidForRecord(record),
      source.sourceRfidTagUid ?? '', source.sourceRfidTagType ?? '', source.stockReceiptQuantity, timestamp);
  }
}

function assertPersonalInventoryHistoryRetained(currentRecords, incomingRecords, deletedUids) {
  const incoming = personalInventoryRecordMap(incomingRecords);
  const deleted = new Set(Object.keys(deletedUids ?? {}).map((uid) => uid.toLowerCase()));
  for (const record of Array.isArray(currentRecords) ? currentRecords : []) {
    const tag = typeof record?.rfidTagUid === 'string' ? record.rfidTagUid.trim() : '';
    const uid = typeof record?.uid === 'string' ? record.uid.trim() : '';
    if (!tag || !uid) continue;
    const replacement = incoming.get(uid.toLowerCase());
    if (replacement) {
      if (!replacement.rfidTagUid) {
        throw new ApiError(409, 'inventory_spool_identity_conflict', '历史卷的 RFID 标签身份不能被清除');
      }
      continue;
    }
    // A tagged row is a spool-instance ledger entry. Removing it would make
    // later consumption and predecessor references unverifiable, even if the
    // client supplied a tombstone.
    throw new ApiError(
      409,
      'inventory_history_required',
      '带 RFID 标签的历史耗材不能从云端快照删除，请保留整条生命周期链',
      { uid, deleted: deleted.has(uid.toLowerCase()) },
    );
  }
}

function assertPersonalInventoryEventsReferenceInventory(
  events,
  currentRecords,
  incomingRecords,
  deletedUids,
) {
  const known = new Map();
  for (const record of [...(Array.isArray(currentRecords) ? currentRecords : []), ...(Array.isArray(incomingRecords) ? incomingRecords : [])]) {
    const uid = typeof record?.uid === 'string' ? record.uid.trim().toLowerCase() : '';
    if (uid) known.set(uid, record);
  }
  for (const uid of Object.keys(deletedUids ?? {})) {
    if (uid.trim()) known.set(uid.trim().toLowerCase(), null);
  }
  for (const event of events) {
    const uid = event.inventoryUid.trim().toLowerCase();
    if (!known.has(uid)) {
      throw new ApiError(
        400,
        'inventory_event_reference_missing',
        '个人耗材事件必须引用同一快照中的库存卷',
        { inventoryUid: event.inventoryUid },
      );
    }
    const record = known.get(uid);
    if (record == null || event.rfidTagUid == null) continue;
    const identities = personalInventoryBindings(record).filter((binding) =>
      normalizePersonalInventoryRfidTag(binding.rfidTagUid)?.toLowerCase() === event.rfidTagUid.toLowerCase());
    if (identities.length === 0) {
      throw new ApiError(
        400,
        'inventory_event_tag_conflict',
        '事件标签与库存卷标签不一致',
        { inventoryUid: event.inventoryUid },
      );
    }
    if (event.rfidTagCycle != null && !identities.some((binding) => Number(binding.rfidTagCycle ?? 1) === event.rfidTagCycle)) {
      throw new ApiError(
        400,
        'inventory_event_cycle_conflict',
        '事件周期与库存卷周期不一致',
        { inventoryUid: event.inventoryUid },
      );
    }
  }
}

function normalizePersonalInventoryDeletions(value) {
  if (value == null) return {};
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new ApiError(400, 'invalid_inventory_snapshot', 'deletedUids必须是对象');
  }
  const entries = Object.entries(value);
  if (entries.length > MAX_PERSONAL_INVENTORY_RECORDS) {
    throw new ApiError(
      413,
      'inventory_snapshot_too_large',
      `个人库存删除记录最多${MAX_PERSONAL_INVENTORY_RECORDS}项`,
    );
  }
  const result = {};
  const seen = new Set();
  for (const [uid, deletedAt] of entries) {
    const normalizedUid = personalInventoryText(uid, 'uid', { required: true, max: 128 });
    const uidKey = normalizedUid.toLowerCase();
    if (seen.has(uidKey)) {
      throw new ApiError(400, 'duplicate_inventory_uid', '个人库存删除记录中不能有重复的 uid');
    }
    seen.add(uidKey);
    result[normalizedUid] = personalInventoryDate(deletedAt, 'deletedAt', { required: true });
  }
  return result;
}

const PERSONAL_INVENTORY_EVENT_KEYS = new Set([
  'printerUid', 'printerName', 'channelIndex', 'taskUid',
  'eventUid',
  'inventoryUid',
  'rfidTagUid',
  'rfidTagCycle',
  'eventType',
  'beforeGrams',
  'afterGrams',
  'deltaGrams',
  'occurredAt',
  'source',
  'note',
]);

function normalizePersonalInventoryEvent(event) {
  if (!event || typeof event !== 'object' || Array.isArray(event)) {
    throw new ApiError(400, 'invalid_inventory_event', '个人耗材事件必须是对象');
  }
  for (const key of Object.keys(event)) {
    if (!PERSONAL_INVENTORY_EVENT_KEYS.has(key)) {
      if (/(?:rfid|mifare|nfc|sector|block|key|secret|signature|dump|credential|raw)/i.test(key)) {
        throw new ApiError(400, 'forbidden_field', '个人耗材事件不接受 RFID 原始数据、密钥或签名');
      }
      throw new ApiError(400, 'forbidden_field', `个人耗材事件字段 ${key} 不允许`);
    }
  }
  const eventUid = personalInventoryText(event.eventUid, 'eventUid', { required: true, max: 160 });
  const inventoryUid = personalInventoryText(event.inventoryUid, 'inventoryUid', { required: true, max: 128 });
  const eventType = personalInventoryText(event.eventType, 'eventType', { required: true, max: 48 });
  if (!/^[A-Za-z0-9_.:-]+$/.test(eventType)) {
    throw new ApiError(400, 'invalid_inventory_event', 'eventType包含不支持的字符');
  }
  const source = personalInventoryText(event.source ?? 'remote', 'source', { max: 32 }) ?? 'remote';
  if (!/^[A-Za-z0-9_.:-]+$/.test(source)) {
    throw new ApiError(400, 'invalid_inventory_event', 'source包含不支持的字符');
  }
  const occurredAt = personalInventoryDate(event.occurredAt, 'occurredAt', { required: true });
  const tagUid = normalizePersonalInventoryRfidTag(event.rfidTagUid);
  const tagCycle = personalInventoryInteger(event.rfidTagCycle, 'rfidTagCycle', {
    min: 1,
    max: 1_000_000,
  });
  if (tagUid == null && tagCycle != null && tagCycle !== 1) {
    throw new ApiError(400, 'invalid_inventory_event', '没有 RFID 标签的事件不能使用非 1 周期');
  }
  const number = (value, name) => personalInventoryNumber(value, name, {
    min: -100_000,
    max: 100_000,
  });
  return {
    eventUid,
    inventoryUid,
    rfidTagUid: tagUid,
    rfidTagCycle: tagUid == null ? null : (tagCycle ?? 1),
    eventType,
    beforeGrams: number(event.beforeGrams, 'beforeGrams'),
    afterGrams: number(event.afterGrams, 'afterGrams'),
    deltaGrams: number(event.deltaGrams, 'deltaGrams'),
    occurredAt,
    source,
    note: personalInventoryText(event.note, 'note', { max: 400 }),
    ...(event.printerUid == null ? {} : { printerUid: personalInventoryText(event.printerUid, 'printerUid', { required: true, max: 128 }) }),
    ...(event.printerName == null ? {} : { printerName: personalInventoryText(event.printerName, 'printerName', { required: true, max: 80 }) }),
    ...(event.channelIndex == null ? {} : { channelIndex: personalInventoryInteger(event.channelIndex, 'channelIndex', { min: 0, max: 65535 }) }),
    ...(event.taskUid == null ? {} : { taskUid: personalInventoryText(event.taskUid, 'taskUid', { required: true, max: 128 }) }),
  };
}

function normalizePersonalInventoryEvents(events) {
  if (events == null) return [];
  if (!Array.isArray(events)) {
    throw new ApiError(400, 'invalid_inventory_snapshot', 'events必须是数组');
  }
  if (events.length > MAX_PERSONAL_INVENTORY_EVENTS) {
    throw new ApiError(
      413,
      'inventory_event_log_too_large',
      `个人耗材事件最多同步${MAX_PERSONAL_INVENTORY_EVENTS}条`,
    );
  }
  const seen = new Set();
  return events.map((event) => {
    const normalized = normalizePersonalInventoryEvent(event);
    const key = normalized.eventUid.toLowerCase();
    if (seen.has(key)) {
      throw new ApiError(400, 'duplicate_inventory_event', '个人耗材事件中存在重复 eventUid');
    }
    seen.add(key);
    return normalized;
  });
}

// An append is idempotent and never rewrites an earlier event, even if a
// retry has a newer inventory snapshot revision. The caller owns a transaction.
function appendPersonalInventoryEvents(database, userId, events) {
  const find = database.prepare('SELECT event_json FROM personal_inventory_events WHERE user_id = ? AND event_uid = ?');
  const insert = database.prepare(`INSERT INTO personal_inventory_events
    (user_id, event_uid, inventory_uid, event_json) VALUES (?, ?, ?, ?)`);
  for (const event of events) {
    const existing = find.get(userId, event.eventUid);
    if (existing) {
      if (JSON.stringify(normalizePersonalInventoryEvent(JSON.parse(existing.event_json))) !== JSON.stringify(event)) {
        throw new ApiError(409, 'inventory_event_conflict', '同一耗材事件的内容不可被后续设备改写', { eventUid: event.eventUid });
      }
    } else {
      insert.run(userId, event.eventUid, event.inventoryUid, JSON.stringify(event));
    }
  }
}

function readPersonalInventoryEventPage(database, userId, after = 0, limit = 200) {
  const rows = database.prepare(`SELECT sequence, event_json FROM personal_inventory_events
    WHERE user_id = ? AND sequence > ? ORDER BY sequence LIMIT ?`).all(userId, after, limit + 1);
  const page = rows.slice(0, limit);
  return {
    events: page.map((row) => normalizePersonalInventoryEvent(JSON.parse(row.event_json))),
    nextCursor: page.length ? Number(page[page.length - 1].sequence) : after,
    hasMore: rows.length > limit,
  };
}


function normalizePersonalMaterialCatalog(catalog) {
  if (catalog == null) return [];
  if (!Array.isArray(catalog)) {
    throw new ApiError(400, 'invalid_inventory_snapshot', 'materialCatalog必须是数组');
  }
  if (catalog.length > MAX_PERSONAL_MATERIAL_CATALOG) {
    throw new ApiError(
      413,
      'material_catalog_too_large',
      `个人耗材型号库最多同步${MAX_PERSONAL_MATERIAL_CATALOG}项`,
    );
  }
  const values = new Map();
  for (const item of catalog) {
    if (typeof item !== 'string') {
      throw new ApiError(400, 'invalid_inventory_snapshot', 'materialCatalog包含无效型号');
    }
    const normalized = item.trim();
    if (!normalized) continue;
    if (/[\u0000-\u001f\u007f]/.test(normalized) || normalized.length > 128) {
      throw new ApiError(400, 'invalid_inventory_snapshot', 'materialCatalog包含无效型号');
    }
    values.set(normalized.toLowerCase(), normalized);
  }
  return [...values.values()].sort((a, b) => a.localeCompare(b, 'en', { sensitivity: 'base' }));
}

function validateEmail(value) {
  const email = stringField(value, '邮箱', { max: 254 }).toLowerCase();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    throw new ApiError(400, 'invalid_email', '邮箱格式不正确');
  }
  return email;
}

function validateHandle(value) {
  const handle = stringField(value, '用户名', { min: 3, max: 30 }).toLowerCase();
  if (!/^[a-z0-9][a-z0-9_.-]*$/.test(handle)) {
    throw new ApiError(400, 'invalid_handle', '用户名只能包含小写字母、数字、点、下划线和短横线');
  }
  return handle;
}

function validatePassword(value) {
  const password = passwordField(value, { min: 10 });
  if (!/[a-z]/.test(password) || !/[A-Z]/.test(password) || !/\d/.test(password)) {
    throw new ApiError(400, 'weak_password', '密码至少包含大写字母、小写字母和数字');
  }
  return password;
}

function extractPresetMetadata(presetPayload, allowedImageHosts) {
  if (presetPayload == null || typeof presetPayload !== 'object' || Array.isArray(presetPayload)) {
    throw new ApiError(400, 'invalid_preset', '参数预设格式不正确');
  }
  const root = presetPayload.preset && typeof presetPayload.preset === 'object'
    ? presetPayload.preset
    : presetPayload;
  const name = stringField(root.name, '预设名称', { min: 1, max: 120 });
  const description = stringField(root.description ?? '', '描述', { max: 1000, optional: true });
  const material = stringField(root.material ?? '', '材料', { max: 100, optional: true });
  const scene = stringField(root.scene ?? '', '场景', { max: 100, optional: true });
  const printers = Array.isArray(root.compatiblePrinters)
    ? root.compatiblePrinters.map((item) => String(item).trim()).filter(Boolean).slice(0, 50)
    : [];
  const tags = Array.isArray(root.tags)
    ? root.tags.map((item) => String(item).trim()).filter(Boolean).slice(0, 20)
    : [];
  if (root.previewImageUrl != null && root.previewImageUrl !== '') {
    validatePublicImageUrl(
      root.previewImageUrl,
      '预览图地址',
      allowedImageHosts,
    );
  }
  return {
    name,
    description,
    material,
    scene,
    printers,
    tags,
    presetJson: JSON.stringify(presetPayload),
  };
}

function assertPresetStorageQuota(
  database,
  userId,
  incomingPresetJson,
  { creating, maxPresetCount, maxPresetBytes },
) {
  const usage = database.prepare(`
    SELECT
      COUNT(DISTINCT presets.id) AS preset_count,
      COALESCE(SUM(LENGTH(CAST(versions.preset_json AS BLOB))), 0) AS version_bytes
    FROM presets
    LEFT JOIN preset_versions versions ON versions.preset_id = presets.id
    WHERE presets.owner_id = ?
  `).get(userId);
  if (creating && Number(usage?.preset_count ?? 0) >= maxPresetCount) {
    throw new ApiError(
      409,
      'preset_count_quota_exceeded',
      `每个账号最多发布 ${maxPresetCount} 个参数预设`,
    );
  }
  const incomingBytes = Buffer.byteLength(incomingPresetJson, 'utf8');
  if (Number(usage?.version_bytes ?? 0) + incomingBytes > maxPresetBytes) {
    throw new ApiError(
      413,
      'preset_storage_quota_exceeded',
      '账号的参数预设存储配额已用尽',
    );
  }
}

function encodeCursor(offset) {
  return Buffer.from(String(offset), 'utf8').toString('base64url');
}

function decodeCursor(cursor) {
  if (!cursor) return 0;
  const value = Number(Buffer.from(cursor, 'base64url').toString('utf8'));
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new ApiError(400, 'invalid_cursor', '分页游标无效');
  }
  return value;
}

function initializeDatabase(databasePath) {
  mkdirSync(dirname(databasePath), { recursive: true });
  const database = new DatabaseSync(databasePath);
  database.exec('PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000;');
  database.exec(`
    CREATE TABLE IF NOT EXISTS users (
      id TEXT PRIMARY KEY,
      email TEXT NOT NULL UNIQUE COLLATE NOCASE,
      handle TEXT NOT NULL UNIQUE COLLATE NOCASE,
      display_name TEXT NOT NULL,
      password_hash TEXT NOT NULL,
      avatar_url TEXT,
      bio TEXT,
      email_verified INTEGER NOT NULL DEFAULT 0,
      status TEXT NOT NULL DEFAULT 'active',
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS sessions (
      token_hash TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      kind TEXT NOT NULL CHECK(kind IN ('access', 'refresh')),
      expires_at TEXT NOT NULL,
      created_at TEXT NOT NULL,
      revoked_at TEXT
    );
    CREATE INDEX IF NOT EXISTS sessions_user_idx ON sessions(user_id, kind);
    CREATE TABLE IF NOT EXISTS presets (
      id TEXT PRIMARY KEY,
      owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      name TEXT NOT NULL,
      description TEXT,
      material TEXT,
      scene TEXT,
      printers_json TEXT NOT NULL DEFAULT '[]',
      tags_json TEXT NOT NULL DEFAULT '[]',
      preset_json TEXT NOT NULL,
      visibility TEXT NOT NULL DEFAULT 'public' CHECK(visibility IN ('public', 'unlisted', 'private')),
      moderation_status TEXT NOT NULL DEFAULT 'published',
      revision INTEGER NOT NULL DEFAULT 1,
      likes INTEGER NOT NULL DEFAULT 0,
      downloads INTEGER NOT NULL DEFAULT 0,
      published_at TEXT NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS presets_public_idx
      ON presets(visibility, moderation_status, updated_at DESC);
    CREATE INDEX IF NOT EXISTS presets_owner_idx ON presets(owner_id, updated_at DESC);
    CREATE TABLE IF NOT EXISTS preset_likes (
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      preset_id TEXT NOT NULL REFERENCES presets(id) ON DELETE CASCADE,
      created_at TEXT NOT NULL,
      PRIMARY KEY(user_id, preset_id)
    );
  `);
  // 任务书 Phase E：执行事务化迁移，建立 preset_versions / preset_print_results /
  // preset_applications / preset_reports / moderation_actions / telemetry_events /
  // feature_flags 等新表。迁移幂等，已应用跳过。
  runMigrations(database);
  return database;
}

/**
 * Seed one-time support codes without ever persisting the plaintext code.
 * Production deployments can pass `supportCodes` to createCommunityServer or
 * use the authenticated admin endpoint; the client only submits the code for
 * a one-time claim after payment on the configured third-party shop.
 */
function seedSupportCodes(database, pepper, rawSeeds) {
  if (!Array.isArray(rawSeeds)) return 0;
  let inserted = 0;
  const insert = database.prepare(`
    INSERT OR IGNORE INTO support_codes(
      code_hash, tier, display_label, created_at
    ) VALUES (?, ?, ?, ?)
  `);
  for (const raw of rawSeeds) {
    const source = typeof raw === 'string' ? { code: raw } : raw;
    if (!source || typeof source !== 'object') continue;
    const code = String(source.code ?? '').trim();
    if (code.length < 8 || code.length > 200) continue;
    const tier = String(source.tier ?? '同行支持').trim().slice(0, 40) || '同行支持';
    const label = String(source.displayLabel ?? source.label ?? '').trim().slice(0, 80) || null;
    const result = insert.run(
      privateValueHash(code, pepper),
      tier,
      label,
      nowIso(),
    );
    if (Number(result?.changes ?? 0) > 0) inserted += 1;
  }
  return inserted;
}

function ensureLocalInspectionAccount(database, pepper, password) {
  const account = LOCAL_INSPECTION_ACCOUNT;
  const timestamp = nowIso();
  const existingUser = database.prepare(`
    SELECT * FROM users WHERE lower(email) = lower(?) LIMIT 1
  `).get(account.email);
  const userId = existingUser?.id ?? 'sohun-local-inspection-admin';
  const encodedPassword = existingUser
      && passwordMatches(password, existingUser.password_hash, pepper)
    ? existingUser.password_hash
    : passwordHash(password, pepper);

  database.exec('BEGIN IMMEDIATE');
  try {
    if (existingUser) {
      database.prepare(`
        UPDATE users SET
          handle = ?, display_name = ?, password_hash = ?, email_verified = 1,
          status = 'active', terms_version = ?, privacy_version = ?,
          terms_accepted_at = COALESCE(terms_accepted_at, ?), updated_at = ?
        WHERE id = ?
      `).run(
        account.handle,
        account.displayName,
        encodedPassword,
        DEFAULT_TERMS_VERSION,
        DEFAULT_PRIVACY_VERSION,
        timestamp,
        timestamp,
        userId,
      );
    } else {
      database.prepare(`
        INSERT INTO users(
          id, email, handle, display_name, password_hash, email_verified,
          status, created_at, updated_at, terms_version, privacy_version,
          terms_accepted_at
        ) VALUES (?, ?, ?, ?, ?, 1, 'active', ?, ?, ?, ?, ?)
      `).run(
        userId,
        account.email,
        account.handle,
        account.displayName,
        encodedPassword,
        timestamp,
        timestamp,
        DEFAULT_TERMS_VERSION,
        DEFAULT_PRIVACY_VERSION,
        timestamp,
      );
    }

    database.prepare(`
      INSERT INTO studio_workspaces(id, owner_user_id, name, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET owner_user_id = excluded.owner_user_id
    `).run(
      account.organizationId,
      userId,
      account.organizationName,
      timestamp,
      timestamp,
    );
    database.prepare(`
      INSERT INTO farm_organizations(
        id, organization_code, owner_user_id, display_name, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET owner_user_id = excluded.owner_user_id
    `).run(
      account.organizationId,
      account.organizationCode,
      userId,
      account.organizationName,
      timestamp,
      timestamp,
    );
    database.prepare(`
      INSERT OR IGNORE INTO studio_snapshots(
        workspace_id, revision, payload_json, updated_by, updated_at
      ) VALUES (?, 0, '{}', ?, ?)
    `).run(account.organizationId, userId, timestamp);
    database.prepare(`
      INSERT INTO auth_identity_realms(
        user_id, realm, organization_id, created_at
      )
      SELECT ?, 'personal', NULL, ?
      WHERE NOT EXISTS (
        SELECT 1 FROM auth_identity_realms
        WHERE user_id = ? AND realm = 'personal' AND organization_id IS NULL
      )
    `).run(userId, timestamp, userId);
    database.prepare(`
      INSERT OR IGNORE INTO auth_identity_realms(
        user_id, realm, organization_id, created_at
      ) VALUES (?, 'farm_owner', ?, ?)
    `).run(userId, account.organizationId, timestamp);
    database.prepare(`
      INSERT OR IGNORE INTO farm_security_policies(
        organization_id, updated_by, updated_at
      ) VALUES (?, ?, ?)
    `).run(account.organizationId, userId, timestamp);

    const ownerMember = database.prepare(`
      SELECT * FROM studio_members
      WHERE workspace_id = ? AND role = 'owner'
      ORDER BY created_at ASC LIMIT 1
    `).get(account.organizationId);
    const ownerMemberId = ownerMember?.id ?? 'sohun-local-inspection-owner-member';
    if (ownerMember) {
      database.prepare(`
        UPDATE studio_members SET
          user_id = ?, email = ?, display_name = ?, active = 1,
          account_status = 'active', primary_role_code = 'owner',
          must_change_password = 0, deactivated_at = NULL
        WHERE id = ?
      `).run(
        userId,
        account.email,
        account.displayName,
        ownerMemberId,
      );
    } else {
      database.prepare(`
        INSERT INTO studio_members(
          id, workspace_id, user_id, email, display_name, role, active,
          created_at, account_status, primary_role_code, must_change_password
        ) VALUES (?, ?, ?, ?, ?, 'owner', 1, ?, 'active', 'owner', 0)
      `).run(
        ownerMemberId,
        account.organizationId,
        userId,
        account.email,
        account.displayName,
        timestamp,
      );
    }

    const ownerRoleId = `system:${account.organizationId}:owner`;
    const memberRoleId = `system:${account.organizationId}:member`;
    database.prepare(`
      INSERT INTO farm_roles(
        id, organization_id, code, display_name, description,
        system_role, active, created_at, updated_at
      ) VALUES (?, ?, 'owner', '管理员', '管理成员并使用全部农场功能', 1, 1, ?, ?)
      ON CONFLICT(organization_id, code) DO UPDATE SET
        display_name = excluded.display_name, description = excluded.description,
        system_role = 1, active = 1, updated_at = excluded.updated_at
    `).run(ownerRoleId, account.organizationId, timestamp, timestamp);
    database.prepare(`
      INSERT INTO farm_roles(
        id, organization_id, code, display_name, description,
        system_role, active, created_at, updated_at
      ) VALUES (?, ?, 'member', '成员', '共享农场数据并使用全部农场功能', 1, 1, ?, ?)
      ON CONFLICT(organization_id, code) DO UPDATE SET
        display_name = excluded.display_name, description = excluded.description,
        system_role = 1, active = 1, updated_at = excluded.updated_at
    `).run(memberRoleId, account.organizationId, timestamp, timestamp);
    database.prepare(`
      INSERT OR IGNORE INTO farm_role_permissions(role_id, permission_code)
      SELECT ?, code FROM farm_permissions
      WHERE code != 'organization.transfer_ownership'
    `).run(memberRoleId);
    database.prepare(`
      INSERT OR IGNORE INTO farm_member_role_assignments(
        member_id, role_id, assigned_by, assigned_at
      ) VALUES (?, ?, ?, ?)
    `).run(ownerMemberId, ownerRoleId, userId, timestamp);
    database.prepare(`
      INSERT OR IGNORE INTO farm_member_scopes(
        id, member_id, scope_type, scope_id, created_at
      ) VALUES (?, ?, 'organization', NULL, ?)
    `).run(`scope:${ownerMemberId}:organization`, ownerMemberId, timestamp);
    database.exec('COMMIT');
  } catch (error) {
    database.exec('ROLLBACK');
    throw error;
  }
}

/**
 * 在发布或更新参数时，于同一事务写入不可变 preset_versions 行。
 * 任务书 10.1：发布/更新参数时，在同一事务写入不可变 preset_versions；
 * 启动迁移对现有参数当前 revision 做幂等回填。旧 revision 的结果必须永久留在旧版本统计中。
 */
function recordPresetVersion(database, { presetId, revision, presetJson, createdAt }) {
  const hash = contentHashOf(presetJson);
  database.prepare(`
    INSERT OR IGNORE INTO preset_versions(preset_id, revision, content_hash, preset_json, created_at)
    VALUES (?, ?, ?, ?, ?)
  `).run(presetId, revision, hash, presetJson, createdAt);
}

/**
 * Wilson score interval lower bound for a Bernoulli proportion.
 * 任务书 10.3：高可信使用 Wilson 下界而不是裸成功率。
 * 公式：(p + z²/(2n) - z·sqrt(p(1-p)/n + z²/(4n²))) / (1 + z²/n)
 * 默认 z=1.96 (95% confidence)。
 */
function wilsonLowerBound(successes, total, z = 1.96) {
  if (total <= 0) return 0;
  const p = successes / total;
  const z2 = z * z;
  const denom = 1 + z2 / total;
  const center = p + z2 / (2 * total);
  const spread = z * Math.sqrt((p * (1 - p)) / total + z2 / (4 * total * total));
  return Math.max(0, (center - spread) / denom);
}

/**
 * 简单语义版本比较，仅支持 x.y.z 三段数字。
 * 返回 -1 / 0 / 1。非数字段视为 0。
 * 用于 feature_flags 的版本范围筛选。
 */
function compareSemver(a, b) {
  const pa = String(a).split('.').map((x) => Number(x) || 0);
  const pb = String(b).split('.').map((x) => Number(x) || 0);
  for (let i = 0; i < 3; i++) {
    const da = pa[i] ?? 0;
    const db = pb[i] ?? 0;
    if (da < db) return -1;
    if (da > db) return 1;
  }
  return 0;
}

function issueSession(database, userId) {
  const accessToken = createToken();
  const refreshToken = createToken();
  const createdAt = nowIso();
  const accessExpiresAt = new Date(Date.now() + ACCESS_TOKEN_TTL_MS).toISOString();
  const refreshExpiresAt = new Date(Date.now() + REFRESH_TOKEN_TTL_MS).toISOString();
  const insert = database.prepare(`
    INSERT INTO sessions(token_hash, user_id, kind, expires_at, created_at)
    VALUES (?, ?, ?, ?, ?)
  `);
  database.exec('BEGIN IMMEDIATE');
  try {
    insert.run(tokenHash(accessToken), userId, 'access', accessExpiresAt, createdAt);
    insert.run(tokenHash(refreshToken), userId, 'refresh', refreshExpiresAt, createdAt);
    database.exec('COMMIT');
  } catch (error) {
    database.exec('ROLLBACK');
    throw error;
  }
  return {
    accessToken,
    refreshToken,
    expiresAt: accessExpiresAt,
    refreshExpiresAt,
  };
}

function bearerToken(request) {
  const header = request.headers.authorization;
  if (!header?.startsWith('Bearer ')) return null;
  const token = header.slice(7).trim();
  return token || null;
}

function secretMatches(candidate, expected) {
  if (typeof candidate !== 'string' || typeof expected !== 'string') return false;
  const candidateBytes = Buffer.from(candidate, 'utf8');
  const expectedBytes = Buffer.from(expected, 'utf8');
  return candidateBytes.length === expectedBytes.length
    && timingSafeEqual(candidateBytes, expectedBytes);
}

function requireAdmin(request, adminToken) {
  if (!secretMatches(bearerToken(request), adminToken)) {
    throw new ApiError(403, 'forbidden', '需要管理员令牌');
  }
}

function normalizedIpLiteral(rawAddress) {
  if (typeof rawAddress !== 'string') return null;
  let value = rawAddress.trim();
  const scopeIndex = value.indexOf('%');
  if (scopeIndex >= 0) value = value.slice(0, scopeIndex);
  if (value.toLowerCase().startsWith('::ffff:')) {
    const mapped = value.slice(7);
    if (isIP(mapped) === 4) return mapped;
  }
  return isIP(value) === 0 ? null : value.toLowerCase();
}

function isLoopbackIpLiteral(rawAddress) {
  const address = normalizedIpLiteral(rawAddress);
  if (address == null) return false;
  if (isIP(address) === 4) return address.split('.')[0] === '127';
  return address === '::1' || /^(?:0{1,4}:){7}0{0,3}1$/i.test(address);
}

// Resolve the address used by in-memory rate limiting. Forwarded data is
// accepted only from a direct loopback proxy and only when that proxy
// overwrites X-Forwarded-For with one unambiguous IP literal.
export function resolveRateLimitAddress(request, { trustLoopbackProxy = false } = {}) {
  const directAddress = normalizedIpLiteral(request.socket?.remoteAddress) ?? 'unknown';
  if (!trustLoopbackProxy || !isLoopbackIpLiteral(directAddress)) return directAddress;
  const forwarded = request.headers?.['x-forwarded-for'];
  if (typeof forwarded !== 'string' || forwarded.includes(',')) return directAddress;
  return normalizedIpLiteral(forwarded) ?? directAddress;
}

export function createRateLimiter({
  now = () => Date.now(),
  maxBuckets = DEFAULT_RATE_LIMIT_MAX_BUCKETS,
  sweepIntervalMs = DEFAULT_RATE_LIMIT_SWEEP_INTERVAL_MS,
} = {}) {
  if (!Number.isInteger(maxBuckets) || maxBuckets <= 0) {
    throw new Error('rate limiter maxBuckets must be a positive integer');
  }
  if (!Number.isFinite(sweepIntervalMs) || sweepIntervalMs <= 0) {
    throw new Error('rate limiter sweepIntervalMs must be positive');
  }
  const buckets = new Map();
  let nextSweepAt = 0;

  function sweepExpired(timestamp, { force = false } = {}) {
    if (!force && timestamp < nextSweepAt && buckets.size < maxBuckets) return;
    for (const [bucketKey, bucket] of buckets) {
      if (bucket.resetAt <= timestamp) buckets.delete(bucketKey);
    }
    nextSweepAt = timestamp + sweepIntervalMs;
  }

  return {
    check(request, key, limit, windowMs, { trustLoopbackProxy = false } = {}) {
      const address = resolveRateLimitAddress(request, { trustLoopbackProxy });
      const bucketKey = `${address}:${key}`;
      const timestamp = now();
      sweepExpired(timestamp);
      const existing = buckets.get(bucketKey);
      if (existing && existing.resetAt > timestamp) {
        existing.count += 1;
        if (existing.count > limit) {
          throw new ApiError(429, 'rate_limited', '操作过于频繁，请稍后再试');
        }
        return;
      }
      if (existing) buckets.delete(bucketKey);
      if (buckets.size >= maxBuckets) {
        // 不驱逐仍生效的桶，否则攻击者可以通过制造唯一 key 绕过限流。
        throw new ApiError(429, 'rate_limiter_capacity', '请求来源过多，请稍后再试');
      }
      buckets.set(bucketKey, { count: 1, resetAt: timestamp + windowMs });
    },
    cleanup() {
      sweepExpired(now(), { force: true });
    },
    clear() {
      buckets.clear();
    },
    get size() {
      return buckets.size;
    },
  };
}

function authenticatedUser(database, request, { required = true } = {}) {
  const token = bearerToken(request);
  if (!token) {
    if (!required) return null;
    throw new ApiError(401, 'authentication_required', '请先登录');
  }
  const row = database.prepare(`
    SELECT users.*
    FROM sessions
    JOIN users ON users.id = sessions.user_id
    WHERE sessions.token_hash = ? AND sessions.kind = 'access'
      AND sessions.revoked_at IS NULL AND sessions.expires_at > ?
      AND users.status = 'active'
  `).get(tokenHash(token), nowIso());
  if (!row) {
    if (!required) return null;
    throw new ApiError(401, 'invalid_session', '登录已失效，请重新登录');
  }
  const staffRealm = database.prepare(`
    SELECT 1 FROM auth_identity_realms
    WHERE user_id = ? AND realm = 'farm_staff' LIMIT 1
  `).get(row.id);
  if (staffRealm) {
    const pathname = new URL(request.url ?? '/', 'http://localhost').pathname;
    const allowed = pathname.startsWith('/v1/farm/')
      || pathname.startsWith('/v1/studio/')
      || pathname.startsWith('/v1/auth/')
      || pathname === '/v1/me';
    if (!allowed) {
      throw new ApiError(
        403,
        'farm_staff_realm_forbidden',
        '农场成员账号不能访问个人社区与个人工作区功能',
      );
    }
  }
  return row;
}

function verifiedAuthenticatedUser(database, request) {
  const user = authenticatedUser(database, request);
  if (!user.email_verified) {
    throw new ApiError(
      403,
      'email_verification_required',
      '请先完成邮箱验证',
    );
  }
  return user;
}

async function readJson(request) {
  const chunks = [];
  let total = 0;
  for await (const chunk of request) {
    total += chunk.length;
    if (total > MAX_BODY_BYTES) {
      throw new ApiError(413, 'payload_too_large', '请求内容过大');
    }
    chunks.push(chunk);
  }
  if (chunks.length === 0) return {};
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    throw new ApiError(400, 'invalid_json', '请求 JSON 格式不正确');
  }
}

function sendJson(response, status, payload, requestId) {
  const data = Buffer.from(JSON.stringify(payload));
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': data.length,
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY',
    'Referrer-Policy': 'no-referrer',
    'X-Request-Id': requestId,
  });
  response.end(data);
}

function presetSelectSql(currentUserId) {
  return `
    SELECT presets.*,
      users.id AS owner_id,
      users.handle AS owner_handle,
      users.display_name AS owner_display_name,
      users.avatar_url AS owner_avatar_url,
      ${currentUserId ? 'presets.owner_id = @viewer_id' : '0'} AS owned_by_me,
      ${currentUserId ? 'EXISTS(SELECT 1 FROM preset_likes l WHERE l.preset_id = presets.id AND l.user_id = @viewer_id)' : '0'} AS liked_by_me,
      (SELECT v.content_hash FROM preset_versions v
        WHERE v.preset_id = presets.id AND v.revision = presets.revision) AS content_hash,
      (SELECT COUNT(DISTINCT a.user_id) FROM preset_applications a
        WHERE a.preset_id = presets.id) AS application_count
    FROM presets JOIN users ON users.id = presets.owner_id
  `;
}

export function createCommunityServer(options = {}) {
  const moduleRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
  const configuredDatabasePath = options.databasePath ?? process.env.COMMUNITY_DATABASE_PATH;
  const production = options.production ?? process.env.NODE_ENV === 'production';
  const localPersistentDatabasePath = resolve(
    homedir(),
    'Documents',
    'sohun_demo_server',
    'community.sqlite',
  );
  const databasePath = resolve(
    configuredDatabasePath
      ?? (!production && IS_DIRECT_ENTRYPOINT
        ? localPersistentDatabasePath
        : resolve(moduleRoot, 'data', 'community.sqlite')),
  );
  const pepper = options.passwordPepper
    ?? process.env.COMMUNITY_PASSWORD_PEPPER
    ?? (production ? '' : LOCAL_DEMO_PASSWORD_PEPPER);
  const adminToken = options.adminToken ?? process.env.COMMUNITY_ADMIN_TOKEN ?? null;
  const verificationEnvironment = process.env.COMMUNITY_REQUIRE_EMAIL_VERIFICATION;
  if (verificationEnvironment != null
      && !['true', 'false'].includes(verificationEnvironment)) {
    throw new Error('COMMUNITY_REQUIRE_EMAIL_VERIFICATION must be true or false');
  }
  const emailVerificationRequired = options.emailVerificationRequired
    ?? (options.autoVerifyEmail == null ? null : !options.autoVerifyEmail)
    ?? (verificationEnvironment == null
      ? production
      : verificationEnvironment === 'true');
  const autoVerifyEmail = !emailVerificationRequired;
  const registrationEnabled = options.registrationEnabled
    ?? process.env.COMMUNITY_REGISTRATION_ENABLED !== 'false';
  const termsVersion = options.termsVersion
    ?? process.env.COMMUNITY_TERMS_VERSION
    ?? DEFAULT_TERMS_VERSION;
  const privacyVersion = options.privacyVersion
    ?? process.env.COMMUNITY_PRIVACY_VERSION
    ?? DEFAULT_PRIVACY_VERSION;
  const supportEmail = String(
    options.supportEmail
      ?? process.env.COMMUNITY_SUPPORT_EMAIL
      ?? 'support@localhost.invalid',
  ).trim().toLowerCase();
  const releaseMetadata = {
    latestVersion: options.releaseMetadata?.latestVersion
      ?? process.env.COMMUNITY_APP_LATEST_VERSION,
    minSupportedVersion: options.releaseMetadata?.minSupportedVersion
      ?? process.env.COMMUNITY_APP_MIN_SUPPORTED_VERSION,
    forceUpdate: options.releaseMetadata?.forceUpdate
      ?? process.env.COMMUNITY_APP_FORCE_UPDATE,
    downloadUrl: options.releaseMetadata?.downloadUrl
      ?? process.env.COMMUNITY_APP_DOWNLOAD_URL,
    githubRepository: options.releaseMetadata?.githubRepository
      ?? process.env.COMMUNITY_APP_GITHUB_REPOSITORY,
    githubReleaseTag: options.releaseMetadata?.githubReleaseTag
      ?? process.env.COMMUNITY_APP_GITHUB_RELEASE_TAG,
    installerAsset: options.releaseMetadata?.installerAsset
      ?? process.env.COMMUNITY_APP_INSTALLER_ASSET,
    releaseNotes: options.releaseMetadata?.releaseNotes
      ?? process.env.COMMUNITY_APP_RELEASE_NOTES,
    android: {
      latestVersion: options.releaseMetadata?.android?.latestVersion
        ?? process.env.COMMUNITY_ANDROID_LATEST_VERSION,
      minSupportedVersion: options.releaseMetadata?.android?.minSupportedVersion
        ?? process.env.COMMUNITY_ANDROID_MIN_SUPPORTED_VERSION,
      forceUpdate: options.releaseMetadata?.android?.forceUpdate
        ?? process.env.COMMUNITY_ANDROID_FORCE_UPDATE,
      downloadUrl: options.releaseMetadata?.android?.downloadUrl
        ?? process.env.COMMUNITY_ANDROID_DOWNLOAD_URL,
      githubRepository: options.releaseMetadata?.android?.githubRepository
        ?? process.env.COMMUNITY_ANDROID_GITHUB_REPOSITORY,
      githubReleaseTag: options.releaseMetadata?.android?.githubReleaseTag
        ?? process.env.COMMUNITY_ANDROID_GITHUB_RELEASE_TAG,
      installerAsset: options.releaseMetadata?.android?.installerAsset
        ?? process.env.COMMUNITY_ANDROID_INSTALLER_ASSET,
      releaseNotes: options.releaseMetadata?.android?.releaseNotes
        ?? process.env.COMMUNITY_ANDROID_RELEASE_NOTES,
    },
  };
  const studioLive = resolveTencentLiveConfiguration(
    options.studioLive ?? {
      pushDomain: process.env.STUDIO_TENCENT_LIVE_PUSH_DOMAIN,
      playbackDomain: process.env.STUDIO_TENCENT_LIVE_PLAYBACK_DOMAIN,
      pushKey: process.env.STUDIO_TENCENT_LIVE_PUSH_KEY,
      playbackKey: process.env.STUDIO_TENCENT_LIVE_PLAYBACK_KEY,
      licenseUrl: process.env.STUDIO_TENCENT_PLAYER_LICENSE_URL,
      appName: process.env.STUDIO_TENCENT_LIVE_APP_NAME,
    },
  );
  const studioOpenStream = resolveOpenStreamConfiguration(
    options.openStream ?? {
      enabled: process.env.STUDIO_OPEN_STREAM_ENABLED,
      rtmpBaseUrl: process.env.STUDIO_OPEN_STREAM_RTMP_BASE_URL,
      hlsBaseUrl: process.env.STUDIO_OPEN_STREAM_HLS_BASE_URL,
    },
  );
  if (studioLive && studioOpenStream) {
    throw new Error('Tencent live and self-hosted open stream cannot be enabled together');
  }
  const publicImageHosts = configuredPublicImageHosts(
    options.publicImageHosts ?? process.env.COMMUNITY_PUBLIC_IMAGE_HOSTS,
  );
  const maxPresetsPerUser = positiveIntegerConfiguration(
    options.maxPresetsPerUser ?? process.env.COMMUNITY_MAX_PRESETS_PER_USER,
    DEFAULT_MAX_PRESETS_PER_USER,
    'COMMUNITY_MAX_PRESETS_PER_USER',
  );
  const maxPresetBytesPerUser = positiveIntegerConfiguration(
    options.maxPresetBytesPerUser ?? process.env.COMMUNITY_MAX_PRESET_BYTES_PER_USER,
    DEFAULT_MAX_PRESET_BYTES_PER_USER,
    'COMMUNITY_MAX_PRESET_BYTES_PER_USER',
  );
  const maxPrinterFaultsPerUser = positiveIntegerConfiguration(
    options.maxPrinterFaultsPerUser ?? process.env.COMMUNITY_MAX_PRINTER_FAULTS_PER_USER,
    10_000,
    'COMMUNITY_MAX_PRINTER_FAULTS_PER_USER',
  );
  const maxPrinterFaultBytesPerUser = positiveIntegerConfiguration(
    options.maxPrinterFaultBytesPerUser ?? process.env.COMMUNITY_MAX_PRINTER_FAULT_BYTES_PER_USER,
    50 * 1024 * 1024,
    'COMMUNITY_MAX_PRINTER_FAULT_BYTES_PER_USER',
  );
  const backupRetentionDays = numericConfiguration(
    options.backupRetentionDays ?? process.env.COMMUNITY_BACKUP_RETENTION_DAYS,
    30,
    'COMMUNITY_BACKUP_RETENTION_DAYS',
    { integer: true },
  );
  const backupIntervalHours = numericConfiguration(
    options.backupIntervalHours ?? process.env.COMMUNITY_BACKUP_INTERVAL_HOURS,
    24,
    'COMMUNITY_BACKUP_INTERVAL_HOURS',
  );
  const configuredBackupDirectory = options.backupDirectory
    ?? process.env.COMMUNITY_BACKUP_DIRECTORY;
  const backupEnabled = options.backupEnabled
    ?? (production || configuredBackupDirectory != null);
  const localInspectionAccountEnabled = !production && (
    options.localInspectionAccountEnabled
      ?? process.env.COMMUNITY_LOCAL_INSPECTION_ACCOUNT === 'true'
  );
  const localInspectionPassword = options.localInspectionAccountPassword
    ?? process.env.COMMUNITY_LOCAL_INSPECTION_ACCOUNT_PASSWORD;
  if (localInspectionAccountEnabled &&
      (typeof localInspectionPassword !== 'string' || localInspectionPassword.length < 12)) {
    throw new Error(
      'COMMUNITY_LOCAL_INSPECTION_ACCOUNT_PASSWORD must contain at least 12 characters when the local inspection account is enabled',
    );
  }
  const smtpConfiguration = options.smtpConfiguration
    ?? smtpConfigurationFromEnvironment();
  const trustProxyMode = options.trustProxyMode
    ?? process.env.COMMUNITY_TRUST_PROXY
    ?? '';
  if (!['', 'loopback'].includes(trustProxyMode)) {
    throw new Error('COMMUNITY_TRUST_PROXY must be empty or loopback');
  }
  const trustLoopbackProxy = trustProxyMode === 'loopback';
  if (production) {
    validateProductionConfiguration({
      passwordPepper: pepper,
      adminToken,
      databasePath: configuredDatabasePath,
      backupDirectory: configuredBackupDirectory,
      backupRetentionDays,
      backupIntervalHours,
      supportEmail,
      emailVerificationRequired,
      smtpConfiguration,
      emailSenderConfigured: options.emailSender != null,
    });
  }
  const allowedOrigin = validateAllowedOrigin(
    options.allowedOrigin ?? process.env.COMMUNITY_ALLOWED_ORIGIN,
    { production },
  );
  if (backupEnabled && !production) {
    validateBackupConfiguration({
      databasePath,
      backupDirectory: configuredBackupDirectory,
      retentionDays: backupRetentionDays,
      intervalHours: backupIntervalHours,
    });
  }
  const emailSender = options.emailSender
    ?? (emailVerificationRequired
      ? createSmtpEmailSender(smtpConfiguration)
      : null);
  const policyStore = createPolicyStore({
    policyRoot: options.policyRoot ?? resolve(moduleRoot, 'policies'),
    termsVersion,
    privacyVersion,
    supportEmail,
  });
  const database = initializeDatabase(databasePath);
  const configuredSupportCodes = options.supportCodes
    ?? (process.env.COMMUNITY_SUPPORT_CODES
      ? process.env.COMMUNITY_SUPPORT_CODES.split(',').map((code) => ({ code }))
      : []);
  seedSupportCodes(database, pepper, configuredSupportCodes);
  if (localInspectionAccountEnabled) {
    ensureLocalInspectionAccount(database, pepper, localInspectionPassword);
  }
  const runMaintenance = () => {
    const tokenCutoff = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000)
      .toISOString();
    const auditCutoff = new Date(Date.now() - 90 * 24 * 60 * 60 * 1000)
      .toISOString();
    database.prepare(`
      DELETE FROM account_action_tokens
      WHERE expires_at < ? AND (consumed_at IS NOT NULL OR expires_at < ?)
    `).run(tokenCutoff, tokenCutoff);
    database.prepare(`
      DELETE FROM sessions
      WHERE expires_at < ? OR (revoked_at IS NOT NULL AND revoked_at < ?)
    `).run(auditCutoff, auditCutoff);
    database.prepare(`
      DELETE FROM email_delivery_events WHERE created_at < ?
    `).run(auditCutoff);
  };
  runMaintenance();
  const maintenanceInterval = setInterval(
    runMaintenance,
    24 * 60 * 60 * 1000,
  );
  maintenanceInterval.unref?.();
  const backupManager = backupEnabled
    ? createBackupManager({
        database,
        databasePath,
        backupDirectory: resolve(configuredBackupDirectory),
        retentionDays: backupRetentionDays,
        intervalHours: backupIntervalHours,
        now: options.now,
      })
    : null;
  const rateLimiter = createRateLimiter({
    now: options.rateLimitNow ?? (() => Date.now()),
    maxBuckets: options.rateLimitMaxBuckets ?? DEFAULT_RATE_LIMIT_MAX_BUCKETS,
    sweepIntervalMs: options.rateLimitSweepIntervalMs
      ?? DEFAULT_RATE_LIMIT_SWEEP_INTERVAL_MS,
  });
  const startedAt = Date.now();
  const emailStatus = {
    configured: emailSender != null,
    healthy: emailSender == null ? !emailVerificationRequired : false,
    lastVerifiedAt: null,
    lastSentAt: null,
    lastFailureAt: null,
    sent: 0,
    failed: 0,
  };
  let databaseReadiness = { healthy: true, checkedAt: null, error: null };

  const emailReady = emailSender == null
    ? Promise.resolve()
    : Promise.resolve(emailSender.verify()).then(() => {
        emailStatus.healthy = true;
        emailStatus.lastVerifiedAt = nowIso();
      }).catch((error) => {
        emailStatus.healthy = false;
        emailStatus.lastFailureAt = nowIso();
        throw error;
      });
  const backupReady = backupManager == null
    ? Promise.resolve()
    : backupManager.runBackup('startup').then(() => {
        backupManager.start();
      });
  const operationalReady = Promise.all([emailReady, backupReady]);

  function checkRateLimit(request, key, limit, windowMs) {
    rateLimiter.check(request, key, limit, windowMs, { trustLoopbackProxy });
  }

  function issueAccountCode(userId, purpose) {
    const createdAt = nowIso();
    const expiresAt = new Date(
      Date.now() + ACCOUNT_CODE_TTL_MINUTES * 60 * 1000,
    ).toISOString();
    database.prepare(`
      UPDATE account_action_tokens
      SET consumed_at = ?
      WHERE user_id = ? AND purpose = ? AND consumed_at IS NULL
    `).run(createdAt, userId, purpose);

    for (let attempt = 0; attempt < 5; attempt += 1) {
      const code = createAccountCode();
      const hash = privateValueHash(`${purpose}:${userId}:${code}`, pepper);
      try {
        database.prepare(`
          INSERT INTO account_action_tokens(
            id, user_id, purpose, token_hash, expires_at,
            attempt_count, max_attempts, created_at
          ) VALUES (?, ?, ?, ?, ?, 0, ?, ?)
        `).run(
          randomUUID(),
          userId,
          purpose,
          hash,
          expiresAt,
          ACCOUNT_CODE_MAX_ATTEMPTS,
          createdAt,
        );
        return { code, expiresAt };
      } catch (error) {
        if (!String(error).includes('token_hash')) throw error;
      }
    }
    throw new Error('unable to allocate a unique account action code');
  }

  function requireValidAccountCode(userId, purpose, rawCode) {
    const code = stringField(rawCode, '验证码', { min: 8, max: 8 });
    if (!/^\d{8}$/.test(code)) {
      throw new ApiError(400, 'invalid_code', '验证码不正确或已过期');
    }
    const token = database.prepare(`
      SELECT *
      FROM account_action_tokens
      WHERE user_id = ? AND purpose = ? AND consumed_at IS NULL
      ORDER BY created_at DESC
      LIMIT 1
    `).get(userId, purpose);
    const expectedHash = privateValueHash(
      `${purpose}:${userId}:${code}`,
      pepper,
    );
    const valid = token != null
      && token.expires_at > nowIso()
      && token.attempt_count < token.max_attempts
      && secretMatches(expectedHash, token.token_hash);
    if (!valid) {
      if (token != null) {
        const nextAttempts = token.attempt_count + 1;
        database.prepare(`
          UPDATE account_action_tokens
          SET attempt_count = ?,
              consumed_at = CASE WHEN ? >= max_attempts THEN ? ELSE consumed_at END
          WHERE id = ?
        `).run(nextAttempts, nextAttempts, nowIso(), token.id);
      }
      throw new ApiError(400, 'invalid_code', '验证码不正确或已过期');
    }
    return token;
  }

  async function deliverAccountCode(user, purpose, issued) {
    if (emailSender == null) return false;
    const eventId = randomUUID();
    try {
      const result = purpose === 'verify_email'
        ? await emailSender.sendVerification({
            to: user.email,
            code: issued.code,
            expiresMinutes: ACCOUNT_CODE_TTL_MINUTES,
          })
        : await emailSender.sendPasswordReset({
            to: user.email,
            code: issued.code,
            expiresMinutes: ACCOUNT_CODE_TTL_MINUTES,
          });
      const timestamp = nowIso();
      database.prepare(`
        INSERT INTO email_delivery_events(
          id, user_id, purpose, status, provider_message_id, created_at
        ) VALUES (?, ?, ?, 'sent', ?, ?)
      `).run(eventId, user.id, purpose, result?.messageId ?? null, timestamp);
      emailStatus.sent += 1;
      emailStatus.lastSentAt = timestamp;
      emailStatus.healthy = true;
      return true;
    } catch (error) {
      const timestamp = nowIso();
      const category = error?.code ? String(error.code) : 'email_delivery_failed';
      database.prepare(`
        INSERT INTO email_delivery_events(
          id, user_id, purpose, status, error_category, created_at
        ) VALUES (?, ?, ?, 'failed', ?, ?)
      `).run(eventId, user.id, purpose, category, timestamp);
      emailStatus.failed += 1;
      emailStatus.lastFailureAt = timestamp;
      emailStatus.healthy = false;
      console.error(`[email:${purpose}]`, category);
      return false;
    }
  }

  function performDatabaseReadinessCheck() {
    try {
      const result = database.prepare('PRAGMA quick_check').all();
      const healthy = result.length === 1 && result[0].quick_check === 'ok';
      databaseReadiness = {
        healthy,
        checkedAt: nowIso(),
        error: healthy ? null : 'quick_check_failed',
      };
    } catch {
      databaseReadiness = {
        healthy: false,
        checkedAt: nowIso(),
        error: 'database_unavailable',
      };
    }
    return databaseReadiness;
  }

  const checkDatabaseReadiness = createCachedReadinessCheck(
    performDatabaseReadinessCheck,
    {
      now: options.readinessNow ?? (() => Date.now()),
      ttlMs: options.readinessCacheMs ?? DEFAULT_READINESS_CACHE_MS,
    },
  );

  const server = createServer(async (request, response) => {
    const requestId = randomUUID();
    response.setHeader('Access-Control-Allow-Origin', allowedOrigin);
    response.setHeader('Access-Control-Allow-Headers', 'Authorization, Content-Type');
    response.setHeader('Access-Control-Allow-Methods', 'GET, POST, PATCH, PUT, DELETE, OPTIONS');
    if (request.method === 'OPTIONS') {
      response.writeHead(204);
      response.end();
      return;
    }

    try {
      const url = new URL(request.url ?? '/', 'http://localhost');
      const path = normalizeBasePath(url.pathname);
      const method = request.method ?? 'GET';
      if (path.startsWith('/v1/auth/') || path === '/v1/me' || path.startsWith('/v1/me/') || path.startsWith('/v1/admin/') || path.startsWith('/v1/studio/') || path.startsWith('/v1/notifications/')) {
        response.setHeader('Cache-Control', 'no-store');
        response.setHeader('Pragma', 'no-cache');
      }

      if (method === 'GET' && path === '/health') {
        sendJson(response, 200, {
          ok: true,
          service: 'sohun-community',
          apiVersion: API_VERSION,
          registrationEnabled,
          emailVerificationRequired: !autoVerifyEmail,
          termsVersion,
          privacyVersion,
        }, requestId);
        return;
      }

      if (method === 'GET' && path === '/ready') {
        const databaseState = checkDatabaseReadiness();
        const backupState = backupManager?.status() ?? { configured: false };
        const latestBackup = backupState.lastSuccess
          ?? (backupState.latestPersisted?.status === 'succeeded'
            ? backupState.latestPersisted
            : null);
        const latestBackupTime = Date.parse(latestBackup?.completedAt ?? '');
        const backupFresh = backupManager == null
          || (Number.isFinite(latestBackupTime)
            && Date.now() - latestBackupTime
              <= backupIntervalHours * 3 * 60 * 60 * 1000);
        const emailHealthy = !emailVerificationRequired || emailStatus.healthy;
        const ready = databaseState.healthy && backupFresh;
        sendJson(response, ready ? 200 : 503, {
          ok: ready,
          degraded: !emailHealthy,
          service: 'sohun-community',
          checks: {
            database: databaseState.healthy ? 'ok' : 'failed',
            backup: backupManager == null
              ? 'disabled'
              : backupFresh ? 'ok' : 'stale',
            email: emailVerificationRequired
              ? emailHealthy ? 'ok' : 'failed'
              : 'not_required',
          },
        }, requestId);
        return;
      }

      const policyMatch = path.match(
        /^\/v1\/policies\/(terms|privacy)\/(current|\d{4}-\d{2}-\d{2})$/,
      );
      if (method === 'GET' && policyMatch) {
        const document = policyStore.read(policyMatch[1], policyMatch[2]);
        if (document == null) {
          throw new ApiError(404, 'policy_not_found', '未找到该版本政策正文');
        }
        sendJson(response, 200, { policy: document }, requestId);
        return;
      }

      if (method === 'POST' && path === '/v1/auth/register') {
        if (!registrationEnabled) {
          throw new ApiError(403, 'registration_disabled', '账号服务器当前暂停新用户注册');
        }
        checkRateLimit(request, 'register', 10, 60_000);
        const body = await readJson(request);
        assertOnlyKeys(body, new Set([
          'email', 'handle', 'displayName', 'password', 'acceptTerms',
          'termsVersion', 'privacyVersion',
        ]));
        if (body.acceptTerms !== true) {
          throw new ApiError(400, 'terms_required', '请先同意服务条款和隐私政策');
        }
        const acceptedTermsVersion = stringField(body.termsVersion, '服务条款版本', { max: 40 });
        const acceptedPrivacyVersion = stringField(body.privacyVersion, '隐私政策版本', { max: 40 });
        if (acceptedTermsVersion !== termsVersion || acceptedPrivacyVersion !== privacyVersion) {
          throw new ApiError(
            409,
            'account_policy_updated',
            '服务条款或隐私政策已有更新，请刷新后重新确认',
            { termsVersion, privacyVersion },
          );
        }
        const email = validateEmail(body.email);
        const handle = validateHandle(body.handle);
        const displayName = stringField(body.displayName, '显示名称', { min: 1, max: 50 });
        const password = validatePassword(body.password);
        const timestamp = nowIso();
        const userId = randomUUID();
        database.exec('BEGIN IMMEDIATE');
        try {
          database.prepare(`
            INSERT INTO users(
              id, email, handle, display_name, password_hash, email_verified,
              terms_version, privacy_version, terms_accepted_at, last_login_at,
              created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          `).run(
            userId,
            email,
            handle,
            displayName,
            passwordHash(password, pepper),
            autoVerifyEmail ? 1 : 0,
            acceptedTermsVersion,
            acceptedPrivacyVersion,
            timestamp,
            timestamp,
            timestamp,
            timestamp,
          );
          database.prepare(`
            INSERT OR IGNORE INTO auth_identity_realms(
              user_id, realm, organization_id, created_at
            ) VALUES (?, 'personal', NULL, ?)
          `).run(userId, timestamp);
          database.prepare(`
            INSERT INTO account_policy_acceptances(
              user_id, terms_version, privacy_version, accepted_at
            ) VALUES (?, ?, ?, ?)
          `).run(
            userId,
            acceptedTermsVersion,
            acceptedPrivacyVersion,
            timestamp,
          );
          database.exec('COMMIT');
        } catch (error) {
          database.exec('ROLLBACK');
          if (String(error).includes('users.email')) {
            throw new ApiError(409, 'email_exists', '该邮箱已注册');
          }
          if (String(error).includes('users.handle')) {
            throw new ApiError(409, 'handle_exists', '该用户名已被使用');
          }
          throw error;
        }
        const user = database.prepare('SELECT * FROM users WHERE id = ?').get(userId);
        let verificationEmailSent = false;
        if (emailVerificationRequired) {
          const issued = issueAccountCode(user.id, 'verify_email');
          verificationEmailSent = await deliverAccountCode(
            user,
            'verify_email',
            issued,
          );
        }
        sendJson(response, 201, {
          user: publicUser(user, publicImageHosts),
          ...issueSession(database, userId),
          verificationEmailSent,
        }, requestId);
        return;
      }

      if (method === 'POST' && path === '/v1/auth/login') {
        checkRateLimit(request, 'login', 20, 60_000);
        const body = await readJson(request);
        const email = validateEmail(body.email);
        const password = passwordField(body.password, { min: 1 });
        const user = database.prepare('SELECT * FROM users WHERE email = ?').get(email);
        if (!user || !passwordMatches(password, user.password_hash, pepper)) {
          throw new ApiError(401, 'invalid_credentials', '邮箱或密码不正确');
        }
        const farmStaffRealm = database.prepare(`
          SELECT 1 FROM auth_identity_realms
          WHERE user_id = ? AND realm = 'farm_staff' LIMIT 1
        `).get(user.id);
        if (farmStaffRealm) {
          throw new ApiError(
            403,
            'farm_staff_login_required',
            '农场成员请使用“农场编号 + 成员账号 + 密码”登录',
          );
        }
        if (user.status !== 'active') {
          throw new ApiError(403, 'account_disabled', '账号当前不可用');
        }
        database.prepare('UPDATE users SET last_login_at = ? WHERE id = ?')
          .run(nowIso(), user.id);
        const updated = database.prepare('SELECT * FROM users WHERE id = ?').get(user.id);
        sendJson(response, 200, { user: publicUser(updated, publicImageHosts), ...issueSession(database, user.id) }, requestId);
        return;
      }

      if (method === 'POST' && path === '/v1/auth/password-reset/request') {
        checkRateLimit(request, 'password-reset-request', 5, 60 * 60_000);
        const body = await readJson(request);
        assertOnlyKeys(body, new Set(['email']));
        const email = validateEmail(body.email);
        // This is deployment-wide, so it must not depend on account existence.
        // Do not claim that a reset email was sent when SMTP is not enabled.
        if (emailSender == null) {
          throw new ApiError(
            503,
            'email_service_unavailable',
            '邮件找回密码尚未启用，请保留当前密码',
          );
        }
        checkRateLimit(
          request,
          `password-reset:${privateValueHash(email, pepper)}`,
          3,
          60 * 60_000,
        );
        const user = database.prepare(
          "SELECT * FROM users WHERE email = ? AND status = 'active'",
        ).get(email);
        if (user != null && emailSender != null) {
          const issued = issueAccountCode(user.id, 'reset_password');
          deliverAccountCode(user, 'reset_password', issued).catch((error) => {
            console.error('[email:reset_password:background]', error);
          });
        }
        sendJson(response, 202, {
          ok: true,
          message: '如果该邮箱已注册，验证码将发送到邮箱',
        }, requestId);
        return;
      }

      if (method === 'POST' && path === '/v1/auth/password-reset/confirm') {
        checkRateLimit(request, 'password-reset-confirm', 10, 15 * 60_000);
        const body = await readJson(request);
        assertOnlyKeys(body, new Set(['email', 'code', 'newPassword']));
        const email = validateEmail(body.email);
        const newPassword = validatePassword(body.newPassword);
        const user = database.prepare(
          "SELECT * FROM users WHERE email = ? AND status = 'active'",
        ).get(email);
        if (user == null) {
          throw new ApiError(400, 'invalid_code', '验证码不正确或已过期');
        }
        const token = requireValidAccountCode(
          user.id,
          'reset_password',
          body.code,
        );
        const timestamp = nowIso();
        database.exec('BEGIN IMMEDIATE');
        try {
          database.prepare(`
            UPDATE users
            SET password_hash = ?, updated_at = ?
            WHERE id = ?
          `).run(passwordHash(newPassword, pepper), timestamp, user.id);
          database.prepare(`
            UPDATE sessions SET revoked_at = ?
            WHERE user_id = ? AND revoked_at IS NULL
          `).run(timestamp, user.id);
          database.prepare('DELETE FROM printer_fault_monitor_leases WHERE user_id = ?')
            .run(user.id);
          database.prepare(`
            UPDATE account_action_tokens SET consumed_at = ?
            WHERE user_id = ? AND purpose = 'reset_password'
              AND consumed_at IS NULL
          `).run(timestamp, user.id);
          database.exec('COMMIT');
        } catch (error) {
          database.exec('ROLLBACK');
          throw error;
        }
        if (token == null) throw new Error('password reset token disappeared');
        sendJson(response, 200, { ok: true }, requestId);
        return;
      }

      if (method === 'POST' && path === '/v1/auth/refresh') {
        checkRateLimit(request, 'refresh', 30, 60_000);
        const body = await readJson(request);
        const refreshToken = stringField(body.refreshToken, '刷新凭据', { min: 20, max: 200 });
        const session = database.prepare(`
          SELECT sessions.*, users.status
          FROM sessions JOIN users ON users.id = sessions.user_id
          WHERE token_hash = ? AND kind = 'refresh' AND revoked_at IS NULL AND expires_at > ?
        `).get(tokenHash(refreshToken), nowIso());
        if (!session || session.status !== 'active') {
          throw new ApiError(401, 'invalid_refresh_token', '登录已失效，请重新登录');
        }
        database.prepare('UPDATE sessions SET revoked_at = ? WHERE token_hash = ?')
          .run(nowIso(), tokenHash(refreshToken));
        const user = database.prepare('SELECT * FROM users WHERE id = ?').get(session.user_id);
        sendJson(response, 200, { user: publicUser(user, publicImageHosts), ...issueSession(database, user.id) }, requestId);
        return;
      }

      if (method === 'POST' && path === '/v1/auth/logout') {
        const user = authenticatedUser(database, request);
        const body = await readJson(request);
        database.prepare('UPDATE sessions SET revoked_at = ? WHERE token_hash = ?')
          .run(nowIso(), tokenHash(bearerToken(request)));
        if (typeof body.refreshToken === 'string' && body.refreshToken.length > 0) {
          database.prepare('UPDATE sessions SET revoked_at = ? WHERE token_hash = ? AND user_id = ?')
            .run(nowIso(), tokenHash(body.refreshToken), user.id);
        }
        sendJson(response, 200, { ok: true }, requestId);
        return;
      }

      if (method === 'GET' && path === '/v1/me') {
        sendJson(response, 200, { user: publicUser(authenticatedUser(database, request), publicImageHosts) }, requestId);
        return;
      }

      if (await handlePrinterFaultRequest({ database, request, response, path, method, url, requestId,
        authenticatedUser, readJson, sendJson, ApiError, checkRateLimit,
        maxPrinterFaultsPerUser, maxPrinterFaultBytesPerUser })) return;

      if (await handleDeviceWorkbenchRequest({ database, request, response, path, method, url, requestId,
        authenticatedUser, readJson, sendJson, ApiError, checkRateLimit })) return;

      if (path === '/v1/me/inventory/events') {
        const user = authenticatedUser(database, request);
        if (method === 'GET') {
          const after = Number(url.searchParams.get('after') ?? '0');
          const limit = Number(url.searchParams.get('limit') ?? '200');
          if (!Number.isSafeInteger(after) || after < 0 || !Number.isInteger(limit) || limit < 1 || limit > 200) {
            throw new ApiError(400, 'invalid_event_cursor', '耗材账本分页参数不正确');
          }
          sendJson(response, 200, readPersonalInventoryEventPage(database, user.id, after, limit), requestId);
          return;
        }
        if (method === 'POST') {
          const body = await readJson(request);
          assertOnlyKeys(body, new Set(['events']));
          if (!Array.isArray(body.events) || body.events.length > 200) {
            throw new ApiError(400, 'invalid_event_batch', '每批耗材事件必须是数组且不超过 200 条');
          }
          const events = normalizePersonalInventoryEvents(body.events);
          database.exec('BEGIN IMMEDIATE');
          try {
            const snapshot = database.prepare('SELECT records_json, deleted_json FROM personal_inventory_snapshots WHERE user_id = ?').get(user.id);
            assertPersonalInventoryEventsReferenceInventory(events, [],
              snapshot ? JSON.parse(snapshot.records_json) : [], snapshot ? JSON.parse(snapshot.deleted_json) : {});
            appendPersonalInventoryEvents(database, user.id, events);
            database.exec('COMMIT');
          } catch (error) {
            database.exec('ROLLBACK');
            throw error;
          }
          sendJson(response, 200, { accepted: events.length }, requestId);
          return;
        }
      }

      if (path === '/v1/me/inventory/snapshot') {
        const user = authenticatedUser(database, request);
        if (method === 'GET') {
          const row = database.prepare(`
            SELECT revision, records_json, catalog_json, deleted_json, events_json, updated_at
            FROM personal_inventory_snapshots
            WHERE user_id = ?
          `).get(user.id);
          const records = row == null ? [] : parseJson(row.records_json, null);
          const materialCatalog = row == null ? [] : parseJson(row.catalog_json, null);
          const deletedUids = row == null ? {} : parseJson(row.deleted_json || '{}', null);
          const events = readPersonalInventoryEventPage(database, user.id).events;
          if (!Array.isArray(records) || !Array.isArray(materialCatalog)
              || !deletedUids || typeof deletedUids !== 'object' || Array.isArray(deletedUids)
              || !Array.isArray(events)) {
            throw new Error('personal inventory snapshot is corrupted');
          }
          sendJson(response, 200, {
            revision: Number(row?.revision ?? 0),
            updatedAt: row?.updated_at ?? null,
            records,
            materialCatalog,
            deletedUids,
            events,
            eventSyncVersion: 1,
          }, requestId);
          return;
        }

        if (method === 'PUT') {
          const body = await readJson(request);
          assertOnlyKeys(body, PERSONAL_INVENTORY_SNAPSHOT_KEYS);
          const revision = personalInventoryInteger(body.revision, 'revision', {
            required: true,
          });
          const records = normalizePersonalInventoryRecords(body.records);
          const materialCatalog = normalizePersonalMaterialCatalog(body.materialCatalog);
          const deletedUids = normalizePersonalInventoryDeletions(body.deletedUids);
          const incomingEvents = normalizePersonalInventoryEvents(body.events);
          const timestamp = nowIso();

          database.exec('BEGIN IMMEDIATE');
          try {
            const current = database.prepare(`
              SELECT revision, records_json, deleted_json, events_json
              FROM personal_inventory_snapshots
              WHERE user_id = ?
            `).get(user.id);
            const currentRevision = Number(current?.revision ?? 0);
            if (revision !== currentRevision) {
              throw new ApiError(
                409,
                'revision_conflict',
                '个人库存已在其他设备更新',
                { currentRevision },
              );
            }
            const currentRecords = current == null
              ? []
              : parseJson(current.records_json, []);
            if (!Array.isArray(currentRecords)) {
              throw new Error('personal inventory snapshot is corrupted');
            }
            retainAndRecordPersonalStockReceipts(database, user.id, records, currentRecords, timestamp);
            assertPersonalSpoolCapacity(records, currentRecords);
            assertPersonalInventoryHistoryRetained(
              currentRecords,
              records,
              deletedUids,
            );
            assertPersonalInventoryLifecycleGraph(records, currentRecords);
            // A UID cannot be both present and tombstoned in one snapshot;
            // accepting that combination makes merge order nondeterministic.
            const incomingUidKeys = new Set(records.map((record) => record.uid.toLowerCase()));
            for (const uid of Object.keys(deletedUids)) {
              if (incomingUidKeys.has(uid.toLowerCase())) {
                throw new ApiError(
                  400,
                  'invalid_inventory_snapshot',
                  '同一 uid 不能同时出现在 records 和 deletedUids',
                );
              }
            }
            assertPersonalInventoryEventsReferenceInventory(
              incomingEvents,
              currentRecords,
              records,
              deletedUids,
            );
            appendPersonalInventoryEvents(database, user.id, incomingEvents);
            const events = readPersonalInventoryEventPage(database, user.id).events;
            const recordsJson = JSON.stringify(records);
            const catalogJson = JSON.stringify(materialCatalog);
            const deletedJson = JSON.stringify(deletedUids);
            const eventsJson = '[]'; // History lives in the paged append-only table.
            const nextRevision = currentRevision + 1;
            if (current == null) {
              database.prepare(`
                INSERT INTO personal_inventory_snapshots(
                  user_id, revision, records_json, catalog_json, deleted_json, events_json, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
              `).run(user.id, nextRevision, recordsJson, catalogJson, deletedJson, eventsJson, timestamp);
            } else {
              database.prepare(`
                UPDATE personal_inventory_snapshots
                SET revision = ?, records_json = ?, catalog_json = ?, deleted_json = ?, events_json = ?, updated_at = ?
                WHERE user_id = ? AND revision = ?
              `).run(nextRevision, recordsJson, catalogJson, deletedJson, eventsJson, timestamp, user.id, currentRevision);
            }
            database.exec('COMMIT');
            sendJson(response, 200, {
              revision: nextRevision,
              updatedAt: timestamp,
              records,
              materialCatalog,
              deletedUids,
              events,
              eventSyncVersion: 1,
            }, requestId);
          } catch (error) {
            database.exec('ROLLBACK');
            throw error;
          }
          return;
        }
      }

      if (method === 'PATCH' && path === '/v1/me') {
        const user = authenticatedUser(database, request);
        const body = await readJson(request);
        assertOnlyKeys(body, new Set(['handle', 'displayName', 'bio', 'avatarUrl']));
        const handle = body.handle == null
          ? user.handle
          : validateHandle(body.handle);
        const displayName = body.displayName == null
          ? user.display_name
          : stringField(body.displayName, '显示名称', { min: 1, max: 50 });
        const bio = body.bio == null
          ? user.bio
          : stringField(body.bio, '个人简介', { max: 300, optional: true });
        const avatarUrl = body.avatarUrl == null
          ? user.avatar_url
          : validatePublicImageUrl(
              body.avatarUrl,
              '头像地址',
              publicImageHosts,
            );
        try {
          database.prepare(`
            UPDATE users
            SET handle = ?, display_name = ?, bio = ?, avatar_url = ?, updated_at = ?
            WHERE id = ?
          `).run(handle, displayName, bio || null, avatarUrl || null, nowIso(), user.id);
        } catch (error) {
          if (String(error).includes('users.handle')) {
            throw new ApiError(409, 'handle_exists', '该用户名已被使用');
          }
          throw error;
        }
        const updated = database.prepare('SELECT * FROM users WHERE id = ?').get(user.id);
        sendJson(response, 200, { user: publicUser(updated, publicImageHosts) }, requestId);
        return;
      }

      if (method === 'POST' && path === '/v1/me/email-verification/request') {
        const user = authenticatedUser(database, request);
        checkRateLimit(
          request,
          `email-verification:${user.id}`,
          3,
          60 * 60_000,
        );
        if (user.email_verified) {
          sendJson(response, 200, { ok: true, alreadyVerified: true }, requestId);
          return;
        }
        if (emailSender == null) {
          throw new ApiError(
            503,
            'email_service_unavailable',
            '邮件服务暂不可用，请稍后再试',
          );
        }
        const issued = issueAccountCode(user.id, 'verify_email');
        const sent = await deliverAccountCode(user, 'verify_email', issued);
        if (!sent) {
          throw new ApiError(
            503,
            'email_delivery_failed',
            '验证码发送失败，请稍后再试',
          );
        }
        sendJson(response, 202, { ok: true }, requestId);
        return;
      }

      if (method === 'POST' && path === '/v1/me/email-verification/confirm') {
        const user = authenticatedUser(database, request);
        checkRateLimit(
          request,
          `email-verification-confirm:${user.id}`,
          10,
          15 * 60_000,
        );
        if (user.email_verified) {
          sendJson(response, 200, { user: publicUser(user, publicImageHosts) }, requestId);
          return;
        }
        const body = await readJson(request);
        assertOnlyKeys(body, new Set(['code']));
        const token = requireValidAccountCode(
          user.id,
          'verify_email',
          body.code,
        );
        const timestamp = nowIso();
        database.exec('BEGIN IMMEDIATE');
        try {
          database.prepare(`
            UPDATE users
            SET email_verified = 1, updated_at = ?
            WHERE id = ?
          `).run(timestamp, user.id);
          database.prepare(`
            UPDATE account_action_tokens SET consumed_at = ?
            WHERE id = ?
          `).run(timestamp, token.id);
          database.exec('COMMIT');
        } catch (error) {
          database.exec('ROLLBACK');
          throw error;
        }
        const updated = database.prepare('SELECT * FROM users WHERE id = ?')
          .get(user.id);
        sendJson(response, 200, { user: publicUser(updated, publicImageHosts) }, requestId);
        return;
      }

      if (method === 'DELETE' && path === '/v1/me') {
        const user = authenticatedUser(database, request);
        const managedFarmStaff = database.prepare(`
          SELECT organizations.id, organizations.display_name
          FROM farm_staff_credentials credentials
          JOIN farm_organizations organizations
            ON organizations.id = credentials.organization_id
          WHERE credentials.user_id = ? LIMIT 1
        `).get(user.id);
        if (managedFarmStaff) {
          throw new ApiError(
            403,
            'farm_staff_account_managed',
            '农场成员账号由所属农场管理；停用请联系管理员',
            {
              organizationId: managedFarmStaff.id,
              organizationName: managedFarmStaff.display_name,
            },
          );
        }
        const body = await readJson(request);
        assertOnlyKeys(body, new Set(['password', 'confirmation']));
        const password = passwordField(body.password, { min: 1 });
        if (body.confirmation !== 'DELETE') {
          throw new ApiError(
            400,
            'deletion_confirmation_required',
            '请输入 DELETE 确认注销账号',
          );
        }
        if (!passwordMatches(password, user.password_hash, pepper)) {
          throw new ApiError(400, 'invalid_password', '密码不正确');
        }
        const ownedFarm = database.prepare(`
          SELECT id, display_name FROM farm_organizations
          WHERE owner_user_id = ? LIMIT 1
        `).get(user.id);
        if (ownedFarm) {
          throw new ApiError(
            409,
            'farm_ownership_transfer_required',
            '请先转移或依法关闭名下农场，再注销主账号',
            { organizationId: ownedFarm.id, organizationName: ownedFarm.display_name },
          );
        }
        const timestamp = nowIso();
        const idHash = privateValueHash(`deleted-user:${user.id}`, pepper);
        const emailHash = privateValueHash(`deleted-email:${user.email}`, pepper);
        database.exec('BEGIN IMMEDIATE');
        try {
          database.prepare(`
            INSERT OR REPLACE INTO deleted_account_tombstones(
              id_hash, email_hash, deleted_at
            ) VALUES (?, ?, ?)
          `).run(idHash, emailHash, timestamp);
          database.prepare('DELETE FROM users WHERE id = ?').run(user.id);
          database.exec('COMMIT');
        } catch (error) {
          database.exec('ROLLBACK');
          throw error;
        }
        sendJson(response, 200, { ok: true }, requestId);
        return;
      }

      // Public co-creation thank-you wall. Listing is intentionally anonymous;
      // redeeming a one-time code requires a verified personal account so the
      // support record stays linked to the same identity used by the app.
      if (method === 'GET' && path === '/v1/supporters') {
        const limit = Math.min(
          MAX_LIMIT,
          Math.max(1, Number(url.searchParams.get('limit')) || DEFAULT_LIMIT),
        );
        const offset = decodeCursor(url.searchParams.get('cursor'));
        const rows = database.prepare(`
          SELECT id, display_name, handle, avatar_url, note, tier, redeemed_at
          FROM support_wall_entries
          WHERE redeemed_at IS NOT NULL
          ORDER BY redeemed_at DESC, id DESC
          LIMIT ? OFFSET ?
        `).all(limit + 1, offset);
        const hasMore = rows.length > limit;
        sendJson(response, 200, {
          items: rows.slice(0, limit).map((row) =>
            publicSupportEntry(row, publicImageHosts)),
          nextCursor: hasMore ? encodeCursor(offset + limit) : null,
        }, requestId);
        return;
      }

      if (method === 'POST' && path === '/v1/supporters/redeem') {
        // A supporter can bind the code to a verified sohun account, or claim
        // it anonymously. The latter keeps the wall useful for one-off
        // supporters who do not want to create an account.
        const user = authenticatedUser(database, request, { required: false });
        if (user && !user.email_verified) {
          throw new ApiError(
            403,
            'email_verification_required',
            '请先完成邮箱验证，或选择匿名加入致谢墙',
          );
        }
        checkRateLimit(
          request,
          user ? `support-redeem:${user.id}` : 'support-redeem:anonymous',
          10,
          60 * 60_000,
        );
        const body = await readJson(request);
        assertOnlyKeys(body, new Set(['code', 'note']));
        const code = stringField(body.code, '支持卡密', { min: 8, max: 200 });
        const note = body.note == null
          ? null
          : stringField(body.note, '支持留言', { max: 30, optional: true });
        const codeHash = privateValueHash(code, pepper);
        const supportCode = database.prepare(
          'SELECT * FROM support_codes WHERE code_hash = ?',
        ).get(codeHash);
        if (!supportCode) {
          throw new ApiError(400, 'support_code_invalid', '卡密无效或尚未同步，请确认粘贴的是支付后收到的完整卡密');
        }
        const redeemedEntry = database.prepare(`
          SELECT * FROM support_wall_entries WHERE code_hash = ? LIMIT 1
        `).get(codeHash);
        if (redeemedEntry) {
          if (user && redeemedEntry.user_id === user.id) {
            sendJson(response, 200, {
              entry: publicSupportEntry(redeemedEntry, publicImageHosts),
              alreadyRedeemed: true,
            }, requestId);
            return;
          }
          throw new ApiError(409, 'support_code_redeemed', '这枚卡密已经登记过了');
        }

        const timestamp = nowIso();
        const entryId = randomUUID();
        database.exec('BEGIN IMMEDIATE');
        try {
          const locked = database.prepare(`
            SELECT * FROM support_codes WHERE code_hash = ? LIMIT 1
          `).get(codeHash);
          if (!locked || locked.redeemed_at != null) {
            database.exec('ROLLBACK');
            throw new ApiError(409, 'support_code_redeemed', '这枚卡密已经登记过了');
          }
          database.prepare(`
            UPDATE support_codes SET redeemed_by = ?, redeemed_at = ?
            WHERE code_hash = ? AND redeemed_at IS NULL
          `).run(user?.id ?? null, timestamp, codeHash);
          database.prepare(`
            INSERT INTO support_wall_entries(
            id, code_hash, user_id, display_name, handle, avatar_url,
            note, tier, redeemed_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          `).run(
            entryId,
            codeHash,
            user?.id ?? null,
            user?.display_name ?? '匿名同行者',
            user?.handle ?? '',
            user == null
              ? null
              : safeStoredPublicImageUrl(user.avatar_url, publicImageHosts),
            note || null,
            locked.tier || '同行支持',
            timestamp,
          );
          database.exec('COMMIT');
        } catch (error) {
          try { database.exec('ROLLBACK'); } catch (_) { /* already rolled back */ }
          throw error;
        }
        const entry = database.prepare(
          'SELECT * FROM support_wall_entries WHERE id = ?',
        ).get(entryId);
        sendJson(response, 201, {
          entry: publicSupportEntry(entry, publicImageHosts),
          alreadyRedeemed: false,
        }, requestId);
        return;
      }

      if (method === 'GET' && path === '/v1/presets') {
        const viewer = authenticatedUser(database, request, { required: false });
        const limit = Math.min(MAX_LIMIT, Math.max(1, Number(url.searchParams.get('limit')) || DEFAULT_LIMIT));
        const offset = decodeCursor(url.searchParams.get('cursor'));
        const conditions = [];
        const params = { limit: limit + 1, offset };
        const owner = url.searchParams.get('owner');
        if (owner === 'me') {
          if (!viewer) throw new ApiError(401, 'authentication_required', '请先登录');
          conditions.push('presets.owner_id = @owner_id');
          params.owner_id = viewer.id;
        } else {
          conditions.push("presets.visibility = 'public'");
          conditions.push("presets.moderation_status = 'published'");
        }
        for (const [queryKey, column] of [['material', 'material'], ['scene', 'scene']]) {
          const value = url.searchParams.get(queryKey)?.trim();
          if (value) {
            conditions.push(`presets.${column} = @${queryKey} COLLATE NOCASE`);
            params[queryKey] = value;
          }
        }
        const printer = url.searchParams.get('printer')?.trim();
        if (printer) {
          conditions.push('presets.printers_json LIKE @printer');
          params.printer = `%${printer.replaceAll('%', '\\%').replaceAll('_', '\\_')}%`;
        }
        const query = url.searchParams.get('q')?.trim();
        if (query) {
          conditions.push(`(
            presets.name LIKE @query OR presets.description LIKE @query OR presets.material LIKE @query
            OR presets.scene LIKE @query OR presets.tags_json LIKE @query
            OR users.handle LIKE @query OR users.display_name LIKE @query
          )`);
          params.query = `%${query.replaceAll('%', '\\%').replaceAll('_', '\\_')}%`;
        }
        const sort = url.searchParams.get('sort');
        // Anonymous /download is a compatibility display counter only. Ranking
        // uses server-owned, de-duplicated application records and a bounded
        // trust contribution; the client must preserve this cursor order.
        const applicationCountSql = `(
          SELECT COUNT(DISTINCT applications.user_id) FROM preset_applications applications
          WHERE applications.preset_id = presets.id
        )`;
        const validOutcomeCountSql = `(
          SELECT COUNT(*) FROM preset_print_results results
          WHERE results.preset_id = presets.id
            AND results.audit_status = 'active'
            AND results.user_id != presets.owner_id
            AND results.user_outcome IN ('success', 'usable', 'quality_failed')
        )`;
        const validOutcomeUsersSql = `(
          SELECT COUNT(DISTINCT results.user_id) FROM preset_print_results results
          WHERE results.preset_id = presets.id
            AND results.audit_status = 'active'
            AND results.user_id != presets.owner_id
            AND results.user_outcome IN ('success', 'usable', 'quality_failed')
        )`;
        const usableOutcomeCountSql = `(
          SELECT COUNT(*) FROM preset_print_results results
          WHERE results.preset_id = presets.id
            AND results.audit_status = 'active'
            AND results.user_id != presets.owner_id
            AND results.user_outcome IN ('success', 'usable')
        )`;
        const boundedTrustSql = `(
          CASE WHEN ${validOutcomeCountSql} >= ${COMMUNITY_TRUST_MIN_SAMPLES}
                 AND ${validOutcomeUsersSql} >= ${COMMUNITY_TRUST_MIN_USERS}
            THEN 20.0 * ${usableOutcomeCountSql} / ${validOutcomeCountSql}
            ELSE 0
          END
        )`;
        const orderBy = sort === 'newest'
          ? 'presets.published_at DESC, presets.id ASC'
          : sort === 'popular'
            ? `${applicationCountSql} DESC, presets.likes DESC, presets.updated_at DESC, presets.id ASC`
            : sort === 'mostLiked'
              ? 'presets.likes DESC, presets.updated_at DESC, presets.id ASC'
              : sort === 'name'
                ? 'presets.name COLLATE NOCASE ASC, presets.id ASC'
                : `${boundedTrustSql}
                    + MIN(5, ${applicationCountSql})
                    + MIN(5, presets.likes) DESC,
                   presets.updated_at DESC, presets.id ASC`;
        if (viewer) params.viewer_id = viewer.id;
        const rows = database.prepare(`
          ${presetSelectSql(viewer?.id)}
          WHERE ${conditions.join(' AND ')}
          ORDER BY ${orderBy}
          LIMIT @limit OFFSET @offset
        `).all(params);
        const hasMore = rows.length > limit;
        const items = rows
          .slice(0, limit)
          .map((row) => publicPreset(row, publicImageHosts));
        sendJson(response, 200, {
          items,
          nextCursor: hasMore ? encodeCursor(offset + limit) : null,
        }, requestId);
        return;
      }

      if (method === 'POST' && path === '/v1/presets') {
        const user = verifiedAuthenticatedUser(database, request);
        const body = await readJson(request);
        const metadata = extractPresetMetadata(body.preset, publicImageHosts);
        const visibility = ['public', 'unlisted', 'private'].includes(body.visibility)
          ? body.visibility
          : 'public';
        const id = randomUUID();
        const timestamp = nowIso();
        database.exec('BEGIN IMMEDIATE');
        try {
          assertPresetStorageQuota(database, user.id, metadata.presetJson, {
            creating: true,
            maxPresetCount: maxPresetsPerUser,
            maxPresetBytes: maxPresetBytesPerUser,
          });
          database.prepare(`
            INSERT INTO presets(
              id, owner_id, name, description, material, scene, printers_json, tags_json,
              preset_json, visibility, published_at, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          `).run(
            id,
            user.id,
            metadata.name,
            metadata.description || null,
            metadata.material || null,
            metadata.scene || null,
            JSON.stringify(metadata.printers),
            JSON.stringify(metadata.tags),
            metadata.presetJson,
            visibility,
            timestamp,
            timestamp,
            timestamp,
          );
          // Phase E：同一事务写入不可变 preset_versions 行（revision=1）。
          recordPresetVersion(database, {
            presetId: id,
            revision: 1,
            presetJson: metadata.presetJson,
            createdAt: timestamp,
          });
          database.exec('COMMIT');
        } catch (error) {
          database.exec('ROLLBACK');
          throw error;
        }
        const row = database.prepare(`${presetSelectSql(user.id)} WHERE presets.id = @id`)
          .get({ id, viewer_id: user.id });
        sendJson(response, 201, publicPreset(row, publicImageHosts), requestId);
        return;
      }

      const presetMatch = path.match(/^\/v1\/presets\/([^/]+)$/);
      if (presetMatch && method === 'GET') {
        const viewer = authenticatedUser(database, request, { required: false });
        const params = viewer ? { id: presetMatch[1], viewer_id: viewer.id } : { id: presetMatch[1] };
        const row = database.prepare(`${presetSelectSql(viewer?.id)} WHERE presets.id = @id`).get(params);
        const owned = row?.owner_id === viewer?.id;
        if (!row || (!owned && (row.visibility !== 'public' || row.moderation_status !== 'published'))) {
          throw new ApiError(404, 'preset_not_found', '参数预设不存在');
        }
        sendJson(response, 200, publicPreset(row, publicImageHosts), requestId);
        return;
      }

      if (presetMatch && method === 'PATCH') {
        const user = verifiedAuthenticatedUser(database, request);
        const existing = database.prepare('SELECT * FROM presets WHERE id = ?').get(presetMatch[1]);
        if (!existing) throw new ApiError(404, 'preset_not_found', '参数预设不存在');
        if (existing.owner_id !== user.id) throw new ApiError(403, 'not_owner', '只能修改自己发布的参数');
        const body = await readJson(request);
        if (!Number.isInteger(body.revision) || body.revision !== existing.revision) {
          throw new ApiError(409, 'revision_conflict', '云端参数已更新，请刷新后再保存', {
            currentRevision: existing.revision,
          });
        }
        const metadata = extractPresetMetadata(body.preset, publicImageHosts);
        const visibility = ['public', 'unlisted', 'private'].includes(body.visibility)
          ? body.visibility
          : existing.visibility;
        const newRevision = existing.revision + 1;
        const updatedAt = nowIso();
        database.exec('BEGIN IMMEDIATE');
        try {
          assertPresetStorageQuota(database, user.id, metadata.presetJson, {
            creating: false,
            maxPresetCount: maxPresetsPerUser,
            maxPresetBytes: maxPresetBytesPerUser,
          });
          const updateResult = database.prepare(`
            UPDATE presets SET name = ?, description = ?, material = ?, scene = ?,
              printers_json = ?, tags_json = ?, preset_json = ?, visibility = ?,
              revision = ?, updated_at = ?
            WHERE id = ? AND revision = ?
          `).run(
            metadata.name,
            metadata.description || null,
            metadata.material || null,
            metadata.scene || null,
            JSON.stringify(metadata.printers),
            JSON.stringify(metadata.tags),
            metadata.presetJson,
            visibility,
            newRevision,
            updatedAt,
            existing.id,
            body.revision,
          );
          if (updateResult.changes === 0) {
            const current = database.prepare(
              'SELECT revision FROM presets WHERE id = ?',
            ).get(existing.id);
            throw new ApiError(
              409,
              'revision_conflict',
              '云端参数已更新，请刷新后再保存',
              { currentRevision: current?.revision },
            );
          }
          // Phase E：更新时在同一事务写入新的不可变 preset_versions 行。
          recordPresetVersion(database, {
            presetId: existing.id,
            revision: newRevision,
            presetJson: metadata.presetJson,
            createdAt: updatedAt,
          });
          database.exec('COMMIT');
        } catch (error) {
          database.exec('ROLLBACK');
          throw error;
        }
        const row = database.prepare(`${presetSelectSql(user.id)} WHERE presets.id = @id`)
          .get({ id: existing.id, viewer_id: user.id });
        sendJson(response, 200, publicPreset(row, publicImageHosts), requestId);
        return;
      }

      if (presetMatch && method === 'DELETE') {
        const user = verifiedAuthenticatedUser(database, request);
        const existing = database.prepare('SELECT owner_id FROM presets WHERE id = ?').get(presetMatch[1]);
        if (!existing) throw new ApiError(404, 'preset_not_found', '参数预设不存在');
        if (existing.owner_id !== user.id) throw new ApiError(403, 'not_owner', '只能删除自己发布的参数');
        // Soft removal preserves immutable versions and historical reputation
        // facts. The public feed filters removed content immediately.
        database.prepare(`
          UPDATE presets
          SET moderation_status = 'removed', updated_at = ?
          WHERE id = ?
        `).run(nowIso(), presetMatch[1]);
        sendJson(response, 200, { ok: true }, requestId);
        return;
      }

      const likeMatch = path.match(/^\/v1\/presets\/([^/]+)\/like$/);
      if (likeMatch && (method === 'PUT' || method === 'DELETE')) {
        const user = verifiedAuthenticatedUser(database, request);
        const preset = database.prepare(`
          SELECT id FROM presets
          WHERE id = ? AND visibility = 'public' AND moderation_status = 'published'
        `).get(likeMatch[1]);
        if (!preset) throw new ApiError(404, 'preset_not_found', '参数预设不存在');
        database.exec('BEGIN IMMEDIATE');
        try {
          if (method === 'PUT') {
            database.prepare('INSERT OR IGNORE INTO preset_likes(user_id, preset_id, created_at) VALUES (?, ?, ?)')
              .run(user.id, preset.id, nowIso());
          } else {
            database.prepare('DELETE FROM preset_likes WHERE user_id = ? AND preset_id = ?')
              .run(user.id, preset.id);
          }
          database.prepare('UPDATE presets SET likes = (SELECT COUNT(*) FROM preset_likes WHERE preset_id = ?) WHERE id = ?')
            .run(preset.id, preset.id);
          database.exec('COMMIT');
        } catch (error) {
          database.exec('ROLLBACK');
          throw error;
        }
        const row = database.prepare(`${presetSelectSql(user.id)} WHERE presets.id = @id`)
          .get({ id: preset.id, viewer_id: user.id });
        sendJson(response, 200, publicPreset(row, publicImageHosts), requestId);
        return;
      }

      const downloadMatch = path.match(/^\/v1\/presets\/([^/]+)\/download$/);
      if (downloadMatch && method === 'POST') {
        // 任务书 10.2：现有匿名 /download 只保留兼容展示，不得再影响可信度或推荐排名。
        // 登录后的去重应用记录才可作为低权重行为信号（见 /applications 接口）。
        const preset = database.prepare(`
          SELECT id FROM presets
          WHERE id = ? AND visibility = 'public' AND moderation_status = 'published'
        `).get(downloadMatch[1]);
        if (!preset) throw new ApiError(404, 'preset_not_found', '参数预设不存在');
        sendJson(response, 200, { ok: true }, requestId);
        return;
      }

      // ===== Phase E：社区可信体系 =====

      // POST /v1/presets/:id/print-results
      // 任务书 10.2：上传脱敏打印记录。clientResultId + userId 唯一，重复提交返回原结果。
      // 作者自己的记录可以在详情中单列，但不进入公共可信分和作者信誉。
      // 不得包含序列号、trayUuid、本地路径、文件名、备注或账号字段。
      const printResultsCreateMatch = path.match(/^\/v1\/presets\/([^/]+)\/print-results$/);
      if (printResultsCreateMatch && method === 'POST') {
        const user = verifiedAuthenticatedUser(database, request);
        const presetId = printResultsCreateMatch[1];
        const preset = database.prepare(
          "SELECT id, owner_id, revision, visibility, moderation_status FROM presets WHERE id = ?",
        ).get(presetId);
        if (!preset
            || preset.visibility !== 'public'
            || preset.moderation_status !== 'published') {
          throw new ApiError(404, 'preset_not_found', '参数预设不存在或不可公开访问');
        }
        const body = await readJson(request);
        assertOnlyKeys(body, new Set([
          'clientResultId', 'publicationRevision', 'presetFingerprint',
          'technicalStatus', 'userOutcome', 'printerModel', 'nozzleDiameter',
          'materialProfile', 'plateType', 'humidityBucket', 'estimatedSeconds',
          'actualSeconds', 'estimatedGrams', 'actualGrams', 'rating', 'recordedAt',
        ]));

        // 校验白名单字段。任务书 10.2：客户端传入 likes/trustScore/authorId 等字段会被忽略或拒绝。
        const clientResultId = stringField(body.clientResultId, 'clientResultId', { min: 8, max: 64 });
        const publicationRevision = Number(body.publicationRevision);
        if (!Number.isInteger(publicationRevision) || publicationRevision < 1
            || publicationRevision > preset.revision) {
          throw new ApiError(409, 'revision_mismatch',
            `publicationRevision ${publicationRevision} 不存在于参数 ${presetId}（当前 revision=${preset.revision}）`);
        }
        const presetFingerprint = stringField(body.presetFingerprint, 'presetFingerprint', { min: 16, max: 128 });
        // 校验 fingerprint 与服务端版本一致
        const versionRow = database.prepare(
          'SELECT content_hash FROM preset_versions WHERE preset_id = ? AND revision = ?',
        ).get(presetId, publicationRevision);
        if (!versionRow) {
          throw new ApiError(409, 'revision_mismatch', '指定 revision 不存在');
        }
        if (versionRow.content_hash !== presetFingerprint) {
          throw new ApiError(409, 'fingerprint_mismatch',
            'presetFingerprint 与服务器版本内容哈希不匹配',
            { serverContentHash: versionRow.content_hash });
        }
        const technicalStatus = String(body.technicalStatus);
        if (!['finished', 'failed', 'cancelled'].includes(technicalStatus)) {
          throw new ApiError(400, 'invalid_request', 'technicalStatus 必须为 finished/failed/cancelled');
        }
        const userOutcome = body.userOutcome == null
          ? null
          : (['success', 'usable', 'quality_failed'].includes(String(body.userOutcome))
              ? String(body.userOutcome)
              : (() => { throw new ApiError(400, 'invalid_request', 'userOutcome 取值非法'); })());
        const printerModel = body.printerModel == null ? null
          : stringField(body.printerModel, 'printerModel', { max: 60, optional: true });
        const nozzleDiameter = body.nozzleDiameter == null ? null
          : (typeof body.nozzleDiameter === 'number' && body.nozzleDiameter > 0
              ? body.nozzleDiameter
              : (() => { throw new ApiError(400, 'invalid_request', 'nozzleDiameter 必须为正数'); })());
        const materialProfile = body.materialProfile == null ? null
          : stringField(body.materialProfile, 'materialProfile', { max: 120, optional: true });
        const plateType = body.plateType == null ? null
          : stringField(body.plateType, 'plateType', { max: 60, optional: true });
        const humidityBucket = body.humidityBucket == null ? null
          : (['low', 'medium', 'high'].includes(String(body.humidityBucket))
              ? String(body.humidityBucket)
              : (() => { throw new ApiError(400, 'invalid_request', 'humidityBucket 取值非法'); })());
        const estimatedSeconds = body.estimatedSeconds == null ? null
          : (Number.isInteger(body.estimatedSeconds) && body.estimatedSeconds >= 0
              ? body.estimatedSeconds
              : (() => { throw new ApiError(400, 'invalid_request', 'estimatedSeconds 必须为非负整数'); })());
        const actualSeconds = body.actualSeconds == null ? null
          : (Number.isInteger(body.actualSeconds) && body.actualSeconds >= 0
              ? body.actualSeconds
              : (() => { throw new ApiError(400, 'invalid_request', 'actualSeconds 必须为非负整数'); })());
        const estimatedGrams = body.estimatedGrams == null ? null
          : (typeof body.estimatedGrams === 'number' && body.estimatedGrams >= 0
              ? body.estimatedGrams
              : (() => { throw new ApiError(400, 'invalid_request', 'estimatedGrams 必须为非负数'); })());
        const actualGrams = body.actualGrams == null ? null
          : (typeof body.actualGrams === 'number' && body.actualGrams >= 0
              ? body.actualGrams
              : (() => { throw new ApiError(400, 'invalid_request', 'actualGrams 必须为非负数'); })());
        const rating = body.rating == null ? null
          : (Number.isInteger(body.rating) && body.rating >= 1 && body.rating <= 5
              ? body.rating
              : (() => { throw new ApiError(400, 'invalid_request', 'rating 必须为 1-5 的整数'); })());
        // recordedAt 仅作参考，时间以服务端接收时间为准
        const recordedAt = stringField(body.recordedAt, 'recordedAt', { min: 10, max: 64 });
        const existingIdempotent = database.prepare(`
          SELECT * FROM preset_print_results
          WHERE user_id = ? AND client_result_id = ?
        `).get(user.id, clientResultId);
        if (existingIdempotent) {
          const submittedFacts = [
            presetId, publicationRevision, presetFingerprint,
          ];
          const storedFacts = [
            existingIdempotent.preset_id,
            existingIdempotent.publication_revision,
            existingIdempotent.preset_fingerprint,
          ];
          if (JSON.stringify(submittedFacts) !== JSON.stringify(storedFacts)) {
            throw new ApiError(409, 'idempotency_conflict',
              'clientResultId 已绑定到另一个打印结果');
          }
          sendJson(response, 200, {
            ok: true,
            id: existingIdempotent.id,
            clientResultId: existingIdempotent.client_result_id,
            revision: existingIdempotent.revision,
            receivedAt: existingIdempotent.received_at,
            idempotent: true,
          }, requestId);
          return;
        }

        // 只有真正的新建才消耗限流额度；网络重试的幂等请求不计数。
        checkRateLimit(request, `print-results:${user.id}:${presetId}`,
          PRINT_RESULTS_PER_USER_PER_PRESET_PER_HOUR, 60 * 60 * 1000);
        const receivedAt = nowIso();
        const resultId = randomUUID();

        try {
          database.prepare(`
            INSERT INTO preset_print_results(
              id, user_id, preset_id, publication_revision, preset_fingerprint,
              client_result_id, technical_status, user_outcome,
              printer_model, nozzle_diameter, material_profile, plate_type, humidity_bucket,
              estimated_seconds, actual_seconds, estimated_grams, actual_grams,
              rating, recorded_at, received_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          `).run(
            resultId, user.id, presetId, publicationRevision, presetFingerprint,
            clientResultId, technicalStatus, userOutcome,
            printerModel, nozzleDiameter, materialProfile, plateType, humidityBucket,
            estimatedSeconds, actualSeconds, estimatedGrams, actualGrams,
            rating, recordedAt, receivedAt,
          );
        } catch (error) {
          // A concurrent identical request may win between the preflight query
          // and INSERT. Re-read and return it; a different binding is a 409.
          if (String(error).includes('UNIQUE')) {
            const concurrent = database.prepare(`
              SELECT * FROM preset_print_results
              WHERE user_id = ? AND client_result_id = ?
            `).get(user.id, clientResultId);
            if (concurrent?.preset_id !== presetId) {
              throw new ApiError(409, 'idempotency_conflict',
                'clientResultId 已绑定到另一个打印结果');
            }
            sendJson(response, 200, {
              ok: true,
              id: concurrent.id,
              clientResultId: concurrent.client_result_id,
              revision: concurrent.revision,
              receivedAt: concurrent.received_at,
              idempotent: true,
            }, requestId);
            return;
          }
          throw error;
        }
        sendJson(response, 201, {
          ok: true,
          id: resultId,
          clientResultId,
          revision: 1,
          receivedAt,
          idempotent: false,
        }, requestId);
        return;
      }

      // PATCH /v1/presets/:id/print-results/:clientResultId
      // 任务书 10.2：先分享设备技术结果、之后才补充成品结果/评分时，通过 PATCH 同步；
      // 只能本人修改 userOutcome/rating 等主观字段，不能改写 preset 版本、设备事实、耗时或克数。
      // 服务端结果包含递增 revision；PATCH 携带期望 revision，过期更新返回 409。
      const printResultsPatchMatch = path.match(
        /^\/v1\/presets\/([^/]+)\/print-results\/([^/]+)$/,
      );
      if (printResultsPatchMatch && method === 'PATCH') {
        const user = verifiedAuthenticatedUser(database, request);
        const presetId = printResultsPatchMatch[1];
        const clientResultId = decodePathSegment(printResultsPatchMatch[2]);
        const existing = database.prepare(`
          SELECT * FROM preset_print_results
          WHERE preset_id = ? AND user_id = ? AND client_result_id = ?
        `).get(presetId, user.id, clientResultId);
        if (!existing) throw new ApiError(404, 'result_not_found', '打印结果不存在或不属于当前用户');
        const body = await readJson(request);
        assertOnlyKeys(body, new Set(['expectedRevision', 'userOutcome', 'rating']));
        if (!Number.isInteger(body.expectedRevision) || body.expectedRevision !== existing.revision) {
          throw new ApiError(409, 'revision_conflict', '结果已被另一设备更新，请刷新后决定', {
            currentRevision: existing.revision,
          });
        }
        // 只允许修改主观字段
        const userOutcome = body.userOutcome == null ? existing.user_outcome
          : (['success', 'usable', 'quality_failed'].includes(String(body.userOutcome))
              ? String(body.userOutcome)
              : (() => { throw new ApiError(400, 'invalid_request', 'userOutcome 取值非法'); })());
        const rating = body.rating == null ? existing.rating
          : (Number.isInteger(body.rating) && body.rating >= 1 && body.rating <= 5
              ? body.rating
              : (() => { throw new ApiError(400, 'invalid_request', 'rating 必须为 1-5 的整数'); })());
        const newRevision = existing.revision + 1;
        const updatedAt = nowIso();
        const update = database.prepare(`
          UPDATE preset_print_results
          SET user_outcome = ?, rating = ?, revision = ?, received_at = ?
          WHERE id = ? AND revision = ?
        `).run(userOutcome, rating, newRevision, updatedAt, existing.id, existing.revision);
        if (update.changes === 0) {
          const current = database.prepare(
            'SELECT revision FROM preset_print_results WHERE id = ?',
          ).get(existing.id);
          throw new ApiError(409, 'revision_conflict', '结果已被另一设备更新，请刷新后决定', {
            currentRevision: current?.revision,
          });
        }
        sendJson(response, 200, {
          ok: true,
          id: existing.id,
          clientResultId: existing.client_result_id,
          revision: newRevision,
          receivedAt: updatedAt,
        }, requestId);
        return;
      }

      // DELETE /v1/presets/:id/print-results/:clientResultId
      // 任务书 10.2：用户可撤回自己上传的记录，汇总随之更新。
      if (printResultsPatchMatch && method === 'DELETE') {
        const user = verifiedAuthenticatedUser(database, request);
        const presetId = printResultsPatchMatch[1];
        const clientResultId = decodePathSegment(printResultsPatchMatch[2]);
        const result = database.prepare(`
          DELETE FROM preset_print_results
          WHERE preset_id = ? AND user_id = ? AND client_result_id = ?
        `).run(presetId, user.id, clientResultId);
        if (result.changes === 0) {
          throw new ApiError(404, 'result_not_found', '打印结果不存在或不属于当前用户');
        }
        sendJson(response, 200, { ok: true }, requestId);
        return;
      }

      // GET /v1/presets/:id/print-results/summary
      // 任务书 10.3：服务端必须成为推荐顺序的唯一事实来源；
      // 公共有效样本少于 3 显示"样本不足"，不进入可信度加权排序。
      // 作者自测不进入公共可信分和作者信誉。
      const printResultsSummaryMatch = path.match(
        /^\/v1\/presets\/([^/]+)\/print-results\/summary$/,
      );
      if (printResultsSummaryMatch && method === 'GET') {
        const presetId = printResultsSummaryMatch[1];
        const preset = database.prepare(
          'SELECT id, owner_id, revision, visibility, moderation_status FROM presets WHERE id = ?',
        ).get(presetId);
        if (!preset
            || preset.visibility !== 'public'
            || preset.moderation_status !== 'published') {
          throw new ApiError(404, 'preset_not_found', '参数预设不存在');
        }
        // 公共有效样本：排除作者自测，audit_status=active
        const rows = database.prepare(`
          SELECT user_id, technical_status, user_outcome, rating,
                 printer_model, actual_seconds, actual_grams, received_at
          FROM preset_print_results
          WHERE preset_id = ? AND audit_status = 'active' AND user_id != ?
        `).all(presetId, preset.owner_id);

        const totalCount = rows.length;
        const uniqueUserCount = new Set(rows.map((r) => r.user_id)).size;
        const printerModelSet = new Set(rows.map((r) => r.printer_model).filter(Boolean));

        let finished = 0, failed = 0, cancelled = 0;
        let userSuccess = 0, userUsable = 0, userQualityFailed = 0;
        let ratingCount = 0, ratingSum = 0;
        for (const r of rows) {
          if (r.technical_status === 'finished') finished++;
          else if (r.technical_status === 'failed') failed++;
          else if (r.technical_status === 'cancelled') cancelled++;
          if (r.user_outcome === 'success') userSuccess++;
          else if (r.user_outcome === 'usable') userUsable++;
          else if (r.user_outcome === 'quality_failed') userQualityFailed++;
          if (r.rating != null) {
            ratingCount++;
            ratingSum += r.rating;
          }
        }
        const completionDenom = finished + failed;
        const completionRate = completionDenom > 0 ? finished / completionDenom : null;
        const usableDenom = userSuccess + userUsable + userQualityFailed;
        const outcomeUserCount = new Set(
          rows.filter((row) => row.user_outcome != null).map((row) => row.user_id),
        ).size;
        const usableRate = usableDenom > 0 ? (userSuccess + userUsable) / usableDenom : null;

        // 任务书 10.3：可用率使用带先验的平滑结果，避免 1/1 等于绝对可靠。
        // Beta(1,1) 先验 + 数据，等价于 (success+1) / (total+2)。
        const smoothedUsableRate = usableDenom > 0
          ? (userSuccess + userUsable + 1) / (usableDenom + 2)
          : null;

        // Wilson 下界（高可信门槛时使用）
        const wilsonLower = usableDenom > 0
          ? wilsonLowerBound(userSuccess + userUsable, usableDenom)
          : 0;

        // 任务书 10.3：公共有效样本少于 3 显示"样本不足"；
        // "高可信"至少 10 条、5 个非作者账号。
        const meetsThreshold = usableDenom >= COMMUNITY_TRUST_MIN_SAMPLES
          && outcomeUserCount >= COMMUNITY_TRUST_MIN_USERS;
        const isHighTrust = usableDenom >= COMMUNITY_TRUST_HIGH_SAMPLES
          && outcomeUserCount >= COMMUNITY_TRUST_HIGH_USERS
          && wilsonLower >= 0.70;

        // 作者自测数量（单列展示）
        const authorSelfTestCount = database.prepare(`
          SELECT COUNT(*) AS n FROM preset_print_results
          WHERE preset_id = ? AND user_id = ? AND audit_status = 'active'
        `).get(presetId, preset.owner_id).n;

        // 最近一条记录时间
        const lastRecordedAtRow = database.prepare(`
          SELECT received_at FROM preset_print_results
          WHERE preset_id = ? AND audit_status = 'active' AND user_id != ?
          ORDER BY received_at DESC LIMIT 1
        `).get(presetId, preset.owner_id);

        sendJson(response, 200, {
          presetId,
          revision: preset.revision,
          publicSamples: totalCount,
          uniqueUserCount,
          outcomeSampleCount: usableDenom,
          outcomeUserCount,
          printerModelCoverage: printerModelSet.size,
          meetsThreshold,
          isHighTrust,
          deviceCompletionRate: completionRate,
          deviceFinishedCount: finished,
          deviceFailedCount: failed,
          deviceCancelledCount: cancelled,
          userUsableRate: usableRate,
          smoothedUsableRate,
          wilsonLowerBound: wilsonLower,
          userSuccessCount: userSuccess,
          userUsableCount: userUsable,
          userQualityFailedCount: userQualityFailed,
          ratingAverage: ratingCount > 0 ? ratingSum / ratingCount : null,
          ratingCount,
          authorSelfTestCount,
          lastRecordedAt: lastRecordedAtRow?.received_at ?? null,
          // 任务书 10.3：徽章文案使用"设备记录"或"社区实打记录"，不得写成"官方认证"或"保证成功"。
          badgeLabel: meetsThreshold
            ? (isHighTrust ? '社区实打记录·高可信' : '社区实打记录')
            : null,
        }, requestId);
        return;
      }

      // PUT /v1/presets/:id/applications/:clientApplicationId
      // 任务书 10.2：登录用户去重应用记录；登录后的去重应用记录才可作为低权重行为信号。
      const applicationMatch = path.match(
        /^\/v1\/presets\/([^/]+)\/applications\/([^/]+)$/,
      );
      if (applicationMatch && method === 'PUT') {
        const user = verifiedAuthenticatedUser(database, request);
        const presetId = applicationMatch[1];
        const clientApplicationId = decodePathSegment(applicationMatch[2]);
        const preset = database.prepare(
          "SELECT id, owner_id, revision, visibility, moderation_status FROM presets WHERE id = ?",
        ).get(presetId);
        if (!preset
            || preset.visibility !== 'public'
            || preset.moderation_status !== 'published') {
          throw new ApiError(404, 'preset_not_found', '参数预设不存在');
        }
        if (clientApplicationId.length < 8 || clientApplicationId.length > 64) {
          throw new ApiError(400, 'invalid_request', 'clientApplicationId 长度需为 8-64');
        }
        const now = nowIso();
        const id = randomUUID();
        const existingApplication = database.prepare(`
          SELECT id, preset_id, applied_at FROM preset_applications
          WHERE user_id = ? AND client_application_id = ?
        `).get(user.id, clientApplicationId);
        if (existingApplication) {
          if (existingApplication.preset_id !== presetId) {
            throw new ApiError(409, 'idempotency_conflict',
              'clientApplicationId 已绑定到另一个参数');
          }
          sendJson(response, 200, {
            ok: true,
            id: existingApplication.id,
            appliedAt: existingApplication.applied_at,
            idempotent: true,
          }, requestId);
          return;
        }
        const existingLogicalApplication = database.prepare(`
          SELECT id, preset_id, applied_at FROM preset_applications
          WHERE user_id = ? AND preset_id = ? AND publication_revision = ?
        `).get(user.id, presetId, preset.revision);
        if (existingLogicalApplication) {
          sendJson(response, 200, {
            ok: true,
            id: existingLogicalApplication.id,
            appliedAt: existingLogicalApplication.applied_at,
            idempotent: true,
          }, requestId);
          return;
        }
        database.exec('BEGIN IMMEDIATE');
        try {
          database.prepare(`
            INSERT INTO preset_applications(
              id, user_id, preset_id, publication_revision, client_application_id, applied_at
            ) VALUES (?, ?, ?, ?, ?, ?)
          `).run(id, user.id, presetId, preset.revision, clientApplicationId, now);
          database.prepare(`
            UPDATE presets
            SET downloads = (
              SELECT COUNT(DISTINCT applications.user_id)
              FROM preset_applications applications
              WHERE applications.preset_id = presets.id
            )
            WHERE id = ?
          `).run(presetId);
          database.exec('COMMIT');
        } catch (error) {
          database.exec('ROLLBACK');
          if (String(error).includes('UNIQUE')) {
            const existingByClientId = database.prepare(`
              SELECT id, preset_id, applied_at FROM preset_applications
              WHERE user_id = ? AND client_application_id = ?
            `).get(user.id, clientApplicationId);
            if (existingByClientId && existingByClientId.preset_id !== presetId) {
              throw new ApiError(409, 'idempotency_conflict',
                'clientApplicationId 已绑定到另一个参数');
            }
            const existing = existingByClientId ?? database.prepare(`
              SELECT id, preset_id, applied_at FROM preset_applications
              WHERE user_id = ? AND preset_id = ? AND publication_revision = ?
            `).get(user.id, presetId, preset.revision);
            sendJson(response, 200, {
              ok: true,
              id: existing.id,
              appliedAt: existing.applied_at,
              idempotent: true,
            }, requestId);
            return;
          }
          throw error;
        }
        sendJson(response, 201, {
          ok: true,
          id,
          appliedAt: now,
          idempotent: false,
        }, requestId);
        return;
      }

      // POST /v1/presets/:id/reports
      // 任务书 10.5：举报原因至少包含：危险参数、说明不实、侵权/冒用、垃圾内容、其他。
      // 每个用户对同一参数同一活动举报只能有一条。仅凭举报数量不得自动删除内容。
      const reportMatch = path.match(/^\/v1\/presets\/([^/]+)\/reports$/);
      if (reportMatch && method === 'POST') {
        const user = verifiedAuthenticatedUser(database, request);
        const presetId = reportMatch[1];
        const preset = database.prepare(
          "SELECT id, owner_id, visibility, moderation_status FROM presets WHERE id = ?",
        ).get(presetId);
        if (!preset
            || preset.visibility !== 'public'
            || preset.moderation_status !== 'published') {
          throw new ApiError(404, 'preset_not_found', '参数预设不存在');
        }
        const body = await readJson(request);
        assertOnlyKeys(body, new Set(['reason', 'note']));
        const reason = String(body.reason);
        if (!['dangerous_params', 'misleading_description',
              'infringement_or_impersonation', 'spam', 'other'].includes(reason)) {
          throw new ApiError(400, 'invalid_request', 'reason 取值非法');
        }
        const note = body.note == null ? null
          : stringField(body.note, 'note', { max: 1000, optional: true });
        // 同一用户同一参数仅一条未结举报
        const active = database.prepare(`
          SELECT id FROM preset_reports
          WHERE preset_id = ? AND reporter_id = ? AND status IN ('open', 'reviewing')
        `).get(presetId, user.id);
        if (active) {
          throw new ApiError(409, 'report_exists', '您已对该参数提交过举报，请等待处理');
        }
        const id = randomUUID();
        const now = nowIso();
        database.prepare(`
          INSERT INTO preset_reports(
            id, preset_id, reporter_id, reason, note, status, created_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, 'open', ?, ?)
        `).run(id, presetId, user.id, reason, note, now, now);
        sendJson(response, 201, { ok: true, id, status: 'open', createdAt: now }, requestId);
        return;
      }

      if (method === 'GET' && path === '/v1/admin/metrics') {
        requireAdmin(request, adminToken);
        const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
        const users = database.prepare(`
          SELECT
            COUNT(*) AS total,
            SUM(CASE WHEN status = 'active' THEN 1 ELSE 0 END) AS active,
            SUM(CASE WHEN email_verified = 1 THEN 1 ELSE 0 END) AS verified
          FROM users
        `).get();
        const sessions = database.prepare(`
          SELECT COUNT(*) AS active
          FROM sessions
          WHERE revoked_at IS NULL AND expires_at > ?
        `).get(nowIso());
        const email24h = database.prepare(`
          SELECT
            SUM(CASE WHEN status = 'sent' THEN 1 ELSE 0 END) AS sent,
            SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) AS failed
          FROM email_delivery_events
          WHERE created_at >= ?
        `).get(since);
        const schema = database.prepare(`
          SELECT MAX(version) AS version FROM community_schema_migrations
        `).get();
        sendJson(response, 200, {
          uptimeSeconds: Math.floor((Date.now() - startedAt) / 1000),
          database: {
            healthy: checkDatabaseReadiness().healthy,
            bytes: statSync(databasePath).size,
            schemaVersion: Number(schema?.version ?? 0),
          },
          accounts: {
            total: Number(users?.total ?? 0),
            active: Number(users?.active ?? 0),
            verified: Number(users?.verified ?? 0),
            activeSessions: Number(sessions?.active ?? 0),
          },
          email: {
            ...emailStatus,
            sentLast24Hours: Number(email24h?.sent ?? 0),
            failedLast24Hours: Number(email24h?.failed ?? 0),
          },
          backup: backupManager?.status() ?? { configured: false },
        }, requestId);
        return;
      }

      // Seed one-time codes issued by the external payment shop. Plaintext
      // codes are accepted only over this authenticated admin request and are
      // immediately reduced to HMAC digests in the database.
      if (method === 'POST' && path === '/v1/admin/support-codes') {
        requireAdmin(request, adminToken);
        const body = await readJson(request);
        assertOnlyKeys(body, new Set(['codes']));
        if (!Array.isArray(body.codes) || body.codes.length === 0 || body.codes.length > 500) {
          throw new ApiError(400, 'invalid_request', 'codes 必须是 1-500 项的数组');
        }
        const inserted = seedSupportCodes(database, pepper, body.codes);
        sendJson(response, 201, { ok: true, inserted }, requestId);
        return;
      }

      if (path === '/v1/admin/backups' && method === 'GET') {
        requireAdmin(request, adminToken);
        sendJson(response, 200, {
          backup: backupManager?.status() ?? { configured: false },
        }, requestId);
        return;
      }

      if (path === '/v1/admin/backups' && method === 'POST') {
        requireAdmin(request, adminToken);
        if (backupManager == null) {
          throw new ApiError(409, 'backup_not_configured', '数据库备份尚未配置');
        }
        const result = await backupManager.runBackup('admin');
        sendJson(response, 201, {
          backup: {
            fileName: result.fileName,
            completedAt: result.completedAt,
            bytes: result.bytes,
            sha256: result.sha256,
            schemaVersion: result.schemaVersion,
          },
        }, requestId);
        return;
      }

      // 管理员账号目录：让服务所有者查看实际注册到自己服务器的账号。
      // 只返回业务所需字段，永不返回密码哈希、访问令牌或刷新令牌。
      if (method === 'GET' && path === '/v1/admin/users') {
        requireAdmin(request, adminToken);
        const status = url.searchParams.get('status') || 'all';
        if (!['active', 'disabled', 'all'].includes(status)) {
          throw new ApiError(400, 'invalid_request', 'status 取值非法');
        }
        const query = url.searchParams.get('q')?.trim() ?? '';
        const limit = Math.min(MAX_LIMIT, Math.max(1, Number(url.searchParams.get('limit')) || 50));
        const offset = decodeCursor(url.searchParams.get('cursor'));
        const conditions = [];
        const params = { limit: limit + 1, offset };
        if (status !== 'all') {
          conditions.push('status = @status');
          params.status = status;
        }
        if (query) {
          conditions.push(`(
            instr(lower(email), lower(@query)) > 0
            OR instr(lower(handle), lower(@query)) > 0
            OR instr(lower(display_name), lower(@query)) > 0
          )`);
          params.query = query;
        }
        const where = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : '';
        const rows = database.prepare(`
          SELECT id, email, handle, display_name, email_verified, status,
                 terms_version, privacy_version, terms_accepted_at,
                 last_login_at, created_at, updated_at
          FROM users
          ${where}
          ORDER BY created_at DESC, id ASC
          LIMIT @limit OFFSET @offset
        `).all(params);
        const hasMore = rows.length > limit;
        const items = rows.slice(0, limit).map((row) => ({
          id: row.id,
          email: row.email,
          handle: row.handle,
          displayName: row.display_name,
          emailVerified: Boolean(row.email_verified),
          status: row.status,
          termsVersion: row.terms_version,
          privacyVersion: row.privacy_version,
          termsAcceptedAt: row.terms_accepted_at,
          lastLoginAt: row.last_login_at,
          createdAt: row.created_at,
          updatedAt: row.updated_at,
        }));
        sendJson(response, 200, {
          items,
          nextCursor: hasMore ? encodeCursor(offset + limit) : null,
        }, requestId);
        return;
      }

      // 本地测试用管理接口：查看/处理举报。
      // 任务书 10.5：本轮不要求部署管理后台，但必须有可测试的状态变更入口或管理脚本。
      // 通过 ADMIN_TOKEN 环境变量鉴权，未配置时禁用。
      const reportsListMatch = path.match(/^\/v1\/admin\/reports$/);
      if (reportsListMatch && method === 'GET') {
        requireAdmin(request, adminToken);
        const status = url.searchParams.get('status') || 'open';
        if (!['open', 'reviewing', 'resolved', 'rejected', 'all'].includes(status)) {
          throw new ApiError(400, 'invalid_request', 'status 取值非法');
        }
        const rows = status === 'all'
          ? database.prepare(`
              SELECT r.*, p.name AS preset_name, u.handle AS reporter_handle
              FROM preset_reports r
              JOIN presets p ON p.id = r.preset_id
              JOIN users u ON u.id = r.reporter_id
              ORDER BY r.created_at DESC LIMIT 100
            `).all()
          : database.prepare(`
              SELECT r.*, p.name AS preset_name, u.handle AS reporter_handle
              FROM preset_reports r
              JOIN presets p ON p.id = r.preset_id
              JOIN users u ON u.id = r.reporter_id
              WHERE r.status = ?
              ORDER BY r.created_at DESC LIMIT 100
            `).all(status);
        sendJson(response, 200, { items: rows }, requestId);
        return;
      }

      const reportActionMatch = path.match(/^\/v1\/admin\/reports\/([^/]+)$/);
      if (reportActionMatch && method === 'PATCH') {
        requireAdmin(request, adminToken);
        const reportId = reportActionMatch[1];
        const existing = database.prepare('SELECT * FROM preset_reports WHERE id = ?').get(reportId);
        if (!existing) throw new ApiError(404, 'report_not_found', '举报不存在');
        const body = await readJson(request);
        assertOnlyKeys(body, new Set(['status', 'resolutionNote', 'moderationStatus']));
        const newStatus = String(body.status);
        if (!['reviewing', 'resolved', 'rejected'].includes(newStatus)) {
          throw new ApiError(400, 'invalid_request', 'status 必须为 reviewing/resolved/rejected');
        }
        const note = body.resolutionNote == null ? null
          : stringField(body.resolutionNote, 'resolutionNote', { max: 1000, optional: true });
        const moderationStatus = body.moderationStatus == null
          ? null
          : String(body.moderationStatus);
        if (moderationStatus != null
            && !['published', 'under_review', 'hidden', 'removed'].includes(moderationStatus)) {
          throw new ApiError(400, 'invalid_request',
            'moderationStatus 必须为 published/under_review/hidden/removed');
        }
        const now = nowIso();
        database.exec('BEGIN IMMEDIATE');
        try {
          database.prepare(`
            UPDATE preset_reports
            SET status = ?, resolution_note = ?, updated_at = ?, resolved_at = ?
            WHERE id = ?
          `).run(newStatus, note, now, newStatus === 'resolved' || newStatus === 'rejected' ? now : null, reportId);
          if (moderationStatus != null) {
            database.prepare(`
              UPDATE presets SET moderation_status = ?, updated_at = ? WHERE id = ?
            `).run(moderationStatus, now, existing.preset_id);
          }
          // 审计记录
          database.prepare(`
            INSERT INTO moderation_actions(
              id, moderator_id, target_preset_id, target_report_id, action, reason, created_at
            ) VALUES (?, NULL, ?, ?, ?, ?, ?)
          `).run(
            randomUUID(),
            existing.preset_id,
            reportId,
            moderationStatus == null
              ? `report:${newStatus}`
              : `report:${newStatus};preset:${moderationStatus}`,
            note,
            now,
          );
          database.exec('COMMIT');
        } catch (error) {
          database.exec('ROLLBACK');
          throw error;
        }
        sendJson(response, 200, {
          ok: true,
          id: reportId,
          status: newStatus,
          moderationStatus,
          updatedAt: now,
        }, requestId);
        return;
      }

      // GET /v1/authors/:handle/reputation
      // 任务书 10.4：至少 5 条非作者有效记录、覆盖至少 2 个公开参数后才展示数值信誉。
      // 不公开邮箱、用户 ID 或设备标识。
      const reputationMatch = path.match(/^\/v1\/authors\/([^/]+)\/reputation$/);
      if (reputationMatch && method === 'GET') {
        const handle = decodePathSegment(reputationMatch[1]);
        const author = database.prepare(`
          SELECT id, handle, display_name FROM users WHERE handle = ? COLLATE NOCASE
        `).get(handle);
        if (!author) throw new ApiError(404, 'author_not_found', '作者不存在');
        // Historical public publications remain part of reputation even after
        // the owner removes or moderators hide them. This prevents reputation
        // laundering by deleting poorly performing publications.
        const presetRows = database.prepare(`
          SELECT id, moderation_status FROM presets
          WHERE owner_id = ? AND visibility = 'public'
        `).all(author.id);
        const presetIds = presetRows.map((r) => r.id);
        const activePublicPresets = presetRows.filter(
          (row) => row.moderation_status === 'published',
        ).length;
        if (presetIds.length === 0) {
          sendJson(response, 200, {
            handle: author.handle,
            displayName: author.display_name,
            meetsThreshold: false,
            publicPresets: 0,
            historicalPresetCount: 0,
            nonAuthorSamples: 0,
            uniqueUsers: 0,
            uniquePresetCoverage: 0,
            completionPerformance: null,
            usableRate: null,
            ratingAverage: null,
            ratingCount: 0,
            diversityPerformance: null,
            recencyPerformance: null,
            score: null,
            reputationScore: null,
            badgeLabel: null,
          }, requestId);
          return;
        }
        const placeholders = presetIds.map(() => '?').join(',');
        const rawSamples = database.prepare(`
          SELECT preset_id, user_id, technical_status, user_outcome, rating, received_at
          FROM preset_print_results
          WHERE preset_id IN (${placeholders})
            AND audit_status = 'active'
            AND user_id != ?
          ORDER BY received_at DESC
        `).all(...presetIds, author.id);
        // Cap one user's contribution to three recent records per publication.
        // The raw records remain immutable; only the reputation weight is capped.
        const contributionCounts = new Map();
        const samples = rawSamples.filter((sample) => {
          const key = `${sample.user_id}:${sample.preset_id}`;
          const count = contributionCounts.get(key) ?? 0;
          contributionCounts.set(key, count + 1);
          return count < 3;
        });
        const outcomeSamples = samples.filter((sample) => sample.user_outcome != null);
        const totalSamples = outcomeSamples.length;
        const uniquePresets = new Set(outcomeSamples.map((s) => s.preset_id)).size;
        const uniqueUsers = new Set(outcomeSamples.map((s) => s.user_id)).size;

        let success = 0, usable = 0, qualityFailed = 0;
        let finished = 0, failed = 0;
        let ratingCount = 0, ratingSum = 0;
        for (const s of samples) {
          if (s.technical_status === 'finished') finished++;
          else if (s.technical_status === 'failed') failed++;
          if (s.user_outcome === 'success') success++;
          else if (s.user_outcome === 'usable') usable++;
          else if (s.user_outcome === 'quality_failed') qualityFailed++;
          if (s.rating != null) {
            ratingCount++;
            ratingSum += s.rating;
          }
        }
        const usableDenom = success + usable + qualityFailed;
        const usableRate = usableDenom > 0 ? (success + usable) / usableDenom : null;
        const meetsThreshold = totalSamples >= 5 && uniquePresets >= 2;
        const completionDenom = finished + failed;
        const completionPerformance = completionDenom > 0 ? finished / completionDenom : null;
        const avgRating = ratingCount > 0 ? ratingSum / ratingCount : null;
        const diversityPerformance = Math.min(1, uniquePresets / 5);
        const latestAt = samples[0]?.received_at ? Date.parse(samples[0].received_at) : Number.NaN;
        const ageDays = Number.isFinite(latestAt)
          ? Math.max(0, (Date.now() - latestAt) / (24 * 60 * 60 * 1000))
          : Number.POSITIVE_INFINITY;
        const recencyPerformance = ageDays <= 90
          ? 1
          : ageDays <= 180
            ? 0.75
            : ageDays <= 365
              ? 0.5
              : 0.25;
        const ratingPerformance = avgRating == null ? 0 : avgRating / 5;
        const repScore = meetsThreshold
          ? Math.round(
              ((completionPerformance ?? 0) * 0.20
                + (usableRate ?? 0) * 0.35
                + ratingPerformance * 0.20
                + diversityPerformance * 0.15
                + recencyPerformance * 0.10) * 100,
            )
          : null;
        const badgeLabel = repScore == null
          ? null
          : repScore >= 85
            ? '信誉优秀'
            : repScore >= 70
              ? '信誉良好'
              : '信誉已建立';
        sendJson(response, 200, {
          handle: author.handle,
          displayName: author.display_name,
          meetsThreshold,
          publicPresets: activePublicPresets,
          historicalPresetCount: presetIds.length,
          nonAuthorSamples: totalSamples,
          uniqueUsers,
          uniquePresetCoverage: uniquePresets,
          completionPerformance,
          usableRate,
          ratingAverage: avgRating,
          ratingCount,
          diversityPerformance,
          recencyPerformance,
          score: repScore,
          reputationScore: repScore,
          badgeLabel,
        }, requestId);
        return;
      }

      // ===== Phase F：可观测性与远程配置 =====

      // POST /v1/telemetry/batch
      // 任务书 11.4：事件 ID 幂等、字段白名单、批量大小和限流。
      // 服务端不得保存客户端未允许的属性；本轮只运行临时本地实例，不部署。
      if (method === 'POST' && path === '/v1/telemetry/batch') {
        const installIdHash = (() => {
          const header = request.headers['x-install-id-hash'];
          if (typeof header !== 'string' || !/^[a-f0-9]{64}$/.test(header)) {
            throw new ApiError(400, 'invalid_request', 'X-Install-Id-Hash 头缺失或非法');
          }
          return header;
        })();
        checkRateLimit(request, 'telemetry',
          TELEMETRY_BATCH_PER_ADDRESS_PER_MINUTE, 60 * 1000);
        const body = await readJson(request);
        if (!Array.isArray(body.events) || body.events.length === 0) {
          throw new ApiError(400, 'invalid_request', 'events 必须为非空数组');
        }
        if (body.events.length > TELEMETRY_BATCH_MAX) {
          throw new ApiError(413, 'payload_too_large',
            `单批最多 ${TELEMETRY_BATCH_MAX} 条事件，请拆批上传`);
        }
        const receivedAt = nowIso();
        const insertEvent = database.prepare(`
          INSERT OR IGNORE INTO telemetry_events(
            id, install_id_hash, event_name, result_category, duration_ms,
            attributes_json, received_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?)
        `);
        const inserted = [];
        const skipped = [];
        for (const event of body.events) {
          const eventName = String(event?.eventName);
          if (!TELEMETRY_EVENT_WHITELIST.has(eventName)) {
            // 不在白名单中的事件直接跳过，不返回错误
            skipped.push({ id: event?.id, reason: 'not_whitelisted' });
            continue;
          }
          const eventId = String(event?.id);
          if (eventId.length < 8 || eventId.length > 128) {
            skipped.push({ id: event?.id, reason: 'invalid_id' });
            continue;
          }
          const resultCategory = event.resultCategory == null ? null
            : String(event.resultCategory).slice(0, 32);
          const durationMs = Number.isInteger(event.durationMs) && event.durationMs >= 0
            ? event.durationMs
            : null;
          // 任务书 11.3：禁止把错误全文、文件名、邮箱、序列号作为标签
          // 服务端只接受有限属性，且只保留白名单键
          const allowedAttributes = {};
          const ALLOWED_ATTR_KEYS = new Set([
            'result', 'stage', 'platform', 'app_version', 'endpoint_template',
            'status_class', 'error_type', 'connection_kind', 'retry_count',
            'originSource', 'originLibrary', 'appVersion',
            'fromSchema', 'toSchema', 'backupCreated', 'phase',
            'previousAppVersion', 'currentAppVersion',
            'connectionMode', 'printerModel', 'firmwareVersion',
            'studioVersion', 'amsSummary', 'errorCategory', 'fallbackUsed',
            // 2026-09-03 所有者策略：设备诊断上传（默认关闭）允许携带设备标识；
            // 凭据类（token/access code/TTCode 等）仍由客户端脱敏、不入白名单。
            'printerSerial', 'dllSha256', 'cameraStage', 'bridgeTail',
            'stepIndex', 'visitedSteps', 'cloudConnected', 'printerCount',
            'slicerConfigured', 'costConfigured', 'action',
          ]);
          if (event.attributes && typeof event.attributes === 'object') {
            for (const key of Object.keys(event.attributes)) {
              if (ALLOWED_ATTR_KEYS.has(key)) {
                const v = event.attributes[key];
                if (typeof v === 'string' || typeof v === 'number' || typeof v === 'boolean') {
                  const valueLimit = key === 'bridgeTail' ? 4000 : 200;
                  allowedAttributes[key] = typeof v === 'string' ? v.slice(0, valueLimit) : v;
                }
              }
            }
          }
          insertEvent.run(
            eventId, installIdHash, eventName,
            resultCategory, durationMs,
            JSON.stringify(allowedAttributes), receivedAt,
          );
          inserted.push({ id: eventId, eventName });
        }
        sendJson(response, 200, {
          ok: true,
          received: inserted.length,
          skipped,
          receivedAt,
        }, requestId);
        return;
      }

      // GET /v1/config?appVersion=...&platform=...
      // 任务书 11.6：返回版本受限的功能开关及 ETag。
      // 远程配置只能控制社区增强、实验、诊断上传和非安全网络功能；
      // 永远不能远程关闭数据完整性校验、库存结算、LAN 监控、故障安全告警或凭据保护。
      if (method === 'GET' && path === '/v1/config') {
        const appVersion = String(url.searchParams.get('appVersion') || '').trim();
        const platform = String(url.searchParams.get('platform') || '').trim();
        if (!appVersion || !platform) {
          throw new ApiError(400, 'invalid_request', 'appVersion 和 platform 必填');
        }
        // 读取所有 feature_flags
        const rows = database.prepare('SELECT * FROM feature_flags').all();
        const flags = {};
        for (const row of rows) {
          // 永远不允许远程关闭的安全功能直接跳过
          if (IMMUTABLE_FEATURE_FLAGS.has(row.key)) continue;
          // 版本范围筛选
          if (row.min_app_version && compareSemver(appVersion, row.min_app_version) < 0) continue;
          if (row.max_app_version && compareSemver(appVersion, row.max_app_version) > 0) continue;
          try {
            flags[row.key] = JSON.parse(row.value_json);
          } catch {
            // 跳过无效 JSON
          }
        }
        // 发行元数据走同一条 HTTPS/缓存边界，客户端无需额外更新源。
        // 未配置版本不能作为客户端“已是最新版本”的证据。
        Object.assign(flags, resolveReleaseMetadata(releaseMetadata));
        // 两个平台的版本和安装包独立，Android 绝不回退到桌面安装器。
        const updatePrefix = platform === 'android' ? 'android_' : 'desktop_';
        for (const key of Object.keys(flags)) {
          if ((key.startsWith('desktop_') || key.startsWith('android_')) && !key.startsWith(updatePrefix)) {
            delete flags[key];
          }
        }
        // ETag 基于内容哈希
        const etag = `"${createHash('sha256').update(JSON.stringify(flags)).digest('hex').slice(0, 16)}"`;
        if (request.headers['if-none-match'] === etag) {
          response.writeHead(304, { ETag: etag });
          response.end();
          return;
        }
        const body = {
          flags,
          schemaVersion: 1,
          generatedAt: nowIso(),
          source: 'community_server',
        };
        const data = Buffer.from(JSON.stringify(body));
        response.writeHead(200, {
          'Content-Type': 'application/json; charset=utf-8',
          'Content-Length': data.length,
          'Cache-Control': 'no-store',
          'ETag': etag,
          'X-Request-Id': requestId,
        });
        response.end(data);
        return;
      }

      if (await handleStudioRequest({
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
        requireAdmin: (adminRequest) => requireAdmin(adminRequest, adminToken),
        passwordHash: (value) => passwordHash(value, pepper),
        passwordMatches: (value, encoded) =>
          passwordMatches(value, encoded, pepper),
        studioLive,
        studioOpenStream,
      })) {
        return;
      }

      throw new ApiError(404, 'not_found', '接口不存在');
    } catch (error) {
      const status = error instanceof ApiError ? error.status : 500;
      const code = error instanceof ApiError ? error.code : 'internal_error';
      const message = error instanceof ApiError ? error.message : '服务器内部错误';
      if (!(error instanceof ApiError)) {
        console.error(`[${requestId}]`, error);
      }
      sendJson(response, status, {
        error: { code, message, ...(error.details ? { details: error.details } : {}) },
      }, requestId);
    }
  });

  Object.defineProperty(server, 'operationalReady', {
    value: operationalReady,
    enumerable: false,
  });
  server.on('close', () => {
    clearInterval(maintenanceInterval);
    backupManager?.close();
    emailSender?.close?.();
    rateLimiter.clear();
    database.close();
  });
  return server;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const port = configuredServerPort(process.env.PORT);
  const host = process.env.HOST || '127.0.0.1';
  const server = createCommunityServer();
  await server.operationalReady;
  server.listen(port, host, () => {
    console.log(`Community API listening on http://${host}:${port}`);
  });
}
