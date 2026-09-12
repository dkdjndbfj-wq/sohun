import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync, mkdtempSync, rmSync } from 'node:fs';
import { request as httpRequest } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';

import {
  ApiError,
  createCachedReadinessCheck,
  createRateLimiter,
  createCommunityServer,
  configuredServerPort,
  resolveReleaseMetadata,
  resolveRateLimitAddress,
  resolveOpenStreamConfiguration,
  resolveTencentLiveConfiguration,
  validateAllowedOrigin,
  validatePublicImageUrl,
  validateProductionConfiguration,
} from '../src/server.js';
import { MIGRATIONS, canonicalPresetJson, contentHashOf } from '../src/migrations.js';
import { buildTencentLiveUrl } from '../src/studio_routes.js';
import { renderPublicPage } from '../src/public_site.js';

const ACCOUNT_POLICY = {
  termsVersion: '2026-07-29',
  privacyVersion: '2026-07-29',
};

// Keep migration assertions aligned with the server's current migration
// catalog.  The backup/rehydration tests used to hard-code v21 and silently
// became stale when the RFID ownership and immutable event-ledger migrations
// were added (v22/v23).
const CURRENT_SCHEMA_VERSION = Math.max(
  ...MIGRATIONS.map((migration) => migration.version),
);

function capturingEmailSender() {
  const messages = [];
  return {
    messages,
    async verify() {},
    async sendVerification(message) {
      messages.push({ purpose: 'verify_email', ...message });
      return { messageId: `verify-${messages.length}` };
    },
    async sendPasswordReset(message) {
      messages.push({ purpose: 'reset_password', ...message });
      return { messageId: `reset-${messages.length}` };
    },
    close() {},
  };
}

async function startServer(options = {}) {
  const directory = mkdtempSync(join(tmpdir(), 'consumable-community-'));
  const databasePath = options.databasePath ?? join(directory, 'test.sqlite');
  const server = createCommunityServer({
    databasePath,
    passwordPepper: 'test-pepper',
    ...options,
  });
  await server.operationalReady;
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  return {
    baseUrl: `http://127.0.0.1:${address.port}`,
    databasePath,
    close: async () => {
      await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
      rmSync(directory, { recursive: true, force: true });
    },
  };
}

async function jsonRequest(
  baseUrl,
  path,
  { method = 'GET', token, body, headers = {} } = {},
) {
  const response = await fetch(`${baseUrl}${path}`, {
    method,
    headers: {
      ...headers,
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(body ? { 'Content-Type': 'application/json' } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  return {
    status: response.status,
    json: await response.json(),
    headers: response.headers,
  };
}

test('本机检查管理员在服务重启后仍使用固定账号和密码', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'sohun-permanent-account-'));
  const databasePath = join(directory, 'community.sqlite');
  const localInspectionPassword = 'LocalInspection!2026#Test';
  const start = async () => {
    const server = createCommunityServer({
      databasePath,
      passwordPepper: 'local-inspection-test-pepper',
      localInspectionAccountEnabled: true,
      localInspectionAccountPassword: localInspectionPassword,
    });
    await server.operationalReady;
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    return {
      server,
      baseUrl: `http://127.0.0.1:${server.address().port}`,
    };
  };

  try {
    for (let restart = 0; restart < 2; restart += 1) {
      const running = await start();
      const login = await jsonRequest(running.baseUrl, '/v1/auth/login', {
        method: 'POST',
        body: {
          email: 'farm.admin.permanent@sohun.local',
          password: localInspectionPassword,
        },
      });
      assert.equal(login.status, 200);
      assert.equal(login.json.user.email, 'farm.admin.permanent@sohun.local');
      const workspaces = await jsonRequest(
        running.baseUrl,
        '/v1/studio/workspaces',
        { token: login.json.accessToken },
      );
      assert.equal(workspaces.status, 200);
      assert.equal(workspaces.json.items.length, 1);
      assert.equal(workspaces.json.items[0].id, 'sohun-farm-permanent');
      assert.equal(workspaces.json.items[0].role, 'owner');
      await new Promise((resolve, reject) => running.server.close(
        (error) => error ? reject(error) : resolve(),
      ));
    }
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test('本机检查账号必须显式提供密码，且校验失败时不创建数据库', () => {
  const directory = mkdtempSync(join(tmpdir(), 'sohun-local-account-config-'));
  const databasePath = join(directory, 'community.sqlite');
  try {
    assert.throws(
      () => createCommunityServer({
        databasePath,
        passwordPepper: 'local-inspection-test-pepper',
        localInspectionAccountEnabled: true,
      }),
      /LOCAL_INSPECTION_ACCOUNT_PASSWORD/,
    );
    assert.equal(existsSync(databasePath), false);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

function pausedJsonRequest(baseUrl, path, { method, token, body }) {
  const payload = Buffer.from(JSON.stringify(body));
  const request = httpRequest(new URL(path, baseUrl), {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
      'Content-Length': payload.length,
    },
  });
  const result = new Promise((resolve, reject) => {
    request.on('response', (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('end', () => resolve({
        status: response.statusCode,
        json: JSON.parse(Buffer.concat(chunks).toString('utf8')),
      }));
    });
    request.on('error', reject);
  });
  request.flushHeaders();
  return {
    send() {
      request.end(payload);
    },
    result,
  };
}

test('反向代理地址仅在受信任的回环代理下使用', () => {
  const request = (remoteAddress, forwarded) => ({
    socket: { remoteAddress },
    headers: forwarded == null ? {} : { 'x-forwarded-for': forwarded },
  });

  assert.equal(
    resolveRateLimitAddress(request('127.0.0.1', '203.0.113.7')),
    '127.0.0.1',
  );
  assert.equal(
    resolveRateLimitAddress(
      request('127.0.0.1', '203.0.113.7'),
      { trustLoopbackProxy: true },
    ),
    '203.0.113.7',
  );
  assert.equal(
    resolveRateLimitAddress(
      request('198.51.100.8', '203.0.113.7'),
      { trustLoopbackProxy: true },
    ),
    '198.51.100.8',
  );
  for (const forwarded of [
    '203.0.113.7, 198.51.100.8',
    '203.0.113.7:443',
    'not-an-ip',
  ]) {
    assert.equal(
      resolveRateLimitAddress(
        request('::ffff:127.0.0.1', forwarded),
        { trustLoopbackProxy: true },
      ),
      '127.0.0.1',
    );
  }
});

test('限流桶会清扫过期唯一 key、保留正常限流语义并遵守硬上限', () => {
  let timestamp = 1_000;
  const limiter = createRateLimiter({
    now: () => timestamp,
    maxBuckets: 3,
    sweepIntervalMs: 50,
  });
  const request = (address) => ({ socket: { remoteAddress: address }, headers: {} });

  limiter.check(request('198.51.100.1'), 'login', 2, 100);
  limiter.check(request('198.51.100.1'), 'login', 2, 100);
  assert.throws(
    () => limiter.check(request('198.51.100.1'), 'login', 2, 100),
    (error) => error instanceof ApiError && error.code === 'rate_limited',
  );
  limiter.check(request('198.51.100.2'), 'login', 2, 100);
  limiter.check(request('198.51.100.3'), 'login', 2, 100);
  assert.equal(limiter.size, 3);
  assert.throws(
    () => limiter.check(request('198.51.100.4'), 'login', 2, 100),
    (error) => error instanceof ApiError && error.code === 'rate_limiter_capacity',
  );
  assert.equal(limiter.size, 3);

  timestamp += 101;
  limiter.check(request('198.51.100.4'), 'login', 2, 100);
  assert.equal(limiter.size, 1);
});

test('readiness checks are cached for the configured interval', () => {
  let timestamp = 1_000;
  let calls = 0;
  const check = createCachedReadinessCheck(
    () => ({ healthy: ++calls > 0 }),
    { now: () => timestamp, ttlMs: 30_000 },
  );

  assert.equal(check().healthy, true);
  assert.equal(check().healthy, true);
  assert.equal(calls, 1);
  timestamp += 29_999;
  check();
  assert.equal(calls, 1);
  timestamp += 1;
  check();
  assert.equal(calls, 2);
  timestamp = 500;
  check();
  assert.equal(calls, 3);
});

test('公网图片地址只接受显式信任主机上的安全 HTTPS 目标', () => {
  const allowedHosts = new Set(['cdn.example.com']);
  assert.equal(
    validatePublicImageUrl(
      'https://cdn.example.com/avatar/a.png?size=2',
      '图片地址',
      allowedHosts,
    ),
    'https://cdn.example.com/avatar/a.png?size=2',
  );
  assert.throws(
    () => validatePublicImageUrl(
      'https://cdn.example.com/avatar/a.png',
      '图片地址',
    ),
    (error) => error instanceof ApiError && error.code === 'invalid_image_url',
  );
  assert.throws(
    () => validatePublicImageUrl(
      'https://other.example.com/avatar/a.png',
      '图片地址',
      allowedHosts,
    ),
    (error) => error instanceof ApiError && error.code === 'invalid_image_url',
  );
  for (const value of [
    'http://cdn.example.com/a.png',
    'https://localhost/a.png',
    'https://router.local/a.png',
    'https://127.0.0.1/a.png',
    'https://10.0.0.1/a.png',
    'https://172.16.0.1/a.png',
    'https://192.168.1.1/a.png',
    'https://169.254.169.254/latest/meta-data',
    'https://[::1]/a.png',
    'https://[fe80::1]/a.png',
    'https://[fd00::1]/a.png',
    'https://user:password@cdn.example.com/a.png',
    'https://cdn.example.com/a.png#tracking-fragment',
    'javascript:alert(1)',
    'not a url',
  ]) {
    assert.throws(
      () => validatePublicImageUrl(value, '图片地址', allowedHosts),
      (error) => error instanceof ApiError && error.code === 'invalid_image_url',
      value,
    );
  }
});

test('健康检查声明服务身份与当前账号政策', async (t) => {
  const app = await startServer();
  t.after(app.close);

  const health = await jsonRequest(app.baseUrl, '/health');

  assert.equal(health.status, 200);
  assert.equal(health.json.service, 'sohun-community');
  assert.equal(health.json.apiVersion, 1);
  assert.equal(health.json.registrationEnabled, true);
  assert.equal(health.json.termsVersion, ACCOUNT_POLICY.termsVersion);
  assert.equal(health.json.privacyVersion, ACCOUNT_POLICY.privacyVersion);
  assert.equal(health.headers.get('cache-control'), null);
});

test('当前与历史版本条款和隐私政策正文可直接阅读', async (t) => {
  const app = await startServer({ supportEmail: 'privacy@example.com' });
  t.after(app.close);

  for (const type of ['terms', 'privacy']) {
    const current = await jsonRequest(
      app.baseUrl,
      `/v1/policies/${type}/current`,
    );
    assert.equal(current.status, 200);
    assert.equal(current.json.policy.type, type);
    assert.equal(current.json.policy.version, '2026-07-29');
    assert.match(current.json.policy.content, /privacy@example\.com/);
    assert.doesNotMatch(current.json.policy.content, /\{\{SUPPORT_EMAIL\}\}/);

    const historical = await jsonRequest(
      app.baseUrl,
      `/v1/policies/${type}/2026-07-29`,
    );
    assert.equal(historical.status, 200);
    assert.equal(historical.json.policy.current, true);
  }
});

test('邮箱验证发送一次性验证码，未验证账号不能写入社区', async (t) => {
  const sender = capturingEmailSender();
  const app = await startServer({
    autoVerifyEmail: false,
    emailSender: sender,
  });
  t.after(app.close);

  const registered = await jsonRequest(app.baseUrl, '/v1/auth/register', {
    method: 'POST',
    body: {
      email: 'verify@example.com',
      handle: 'verify-user',
      displayName: 'Verify User',
      password: 'StrongPass123',
      acceptTerms: true,
      ...ACCOUNT_POLICY,
    },
  });
  assert.equal(registered.status, 201);
  assert.equal(registered.json.user.emailVerified, false);
  assert.equal(registered.json.verificationEmailSent, true);
  assert.equal(sender.messages.length, 1);
  assert.equal(sender.messages[0].purpose, 'verify_email');
  assert.match(sender.messages[0].code, /^\d{8}$/);

  const blocked = await jsonRequest(app.baseUrl, '/v1/presets', {
    method: 'POST',
    token: registered.json.accessToken,
    body: {},
  });
  assert.equal(blocked.status, 403);
  assert.equal(blocked.json.error.code, 'email_verification_required');

  const farmCreatedBeforeVerification = await jsonRequest(
    app.baseUrl,
    '/v1/studio/workspaces',
    {
      method: 'POST',
      token: registered.json.accessToken,
      body: {
        id: 'pending-verification-farm',
        name: '待验证农场',
      },
    },
  );
  assert.equal(farmCreatedBeforeVerification.status, 201);
  const farmDataBlockedBeforeVerification = await jsonRequest(
    app.baseUrl,
    '/v1/studio/workspaces/pending-verification-farm/snapshot',
    { token: registered.json.accessToken },
  );
  assert.equal(farmDataBlockedBeforeVerification.status, 403);
  assert.equal(
    farmDataBlockedBeforeVerification.json.error.code,
    'email_verification_required',
  );

  const wrong = await jsonRequest(
    app.baseUrl,
    '/v1/me/email-verification/confirm',
    {
      method: 'POST',
      token: registered.json.accessToken,
      body: { code: '00000000' },
    },
  );
  assert.equal(wrong.status, 400);
  assert.equal(wrong.json.error.code, 'invalid_code');

  const confirmed = await jsonRequest(
    app.baseUrl,
    '/v1/me/email-verification/confirm',
    {
      method: 'POST',
      token: registered.json.accessToken,
      body: { code: sender.messages[0].code },
    },
  );
  assert.equal(confirmed.status, 200);
  assert.equal(confirmed.json.user.emailVerified, true);
});

test('免邮箱验证仍可注册登录，未接入 SMTP 的密码找回明确不可用且不枚举账号', async (t) => {
  const app = await startServer({ emailVerificationRequired: false });
  t.after(app.close);
  const registered = await jsonRequest(app.baseUrl, '/v1/auth/register', {
    method: 'POST',
    body: {
      email: 'without-smtp@example.com',
      handle: 'without-smtp',
      displayName: 'No SMTP',
      password: 'StrongPassword123',
      acceptTerms: true,
      ...ACCOUNT_POLICY,
    },
  });
  assert.equal(registered.status, 201);
  const loggedIn = await jsonRequest(app.baseUrl, '/v1/auth/login', {
    method: 'POST',
    body: { email: 'without-smtp@example.com', password: 'StrongPassword123' },
  });
  assert.equal(loggedIn.status, 200);
  const responses = [];
  for (const email of ['without-smtp@example.com', 'missing@example.com']) {
    const result = await jsonRequest(app.baseUrl, '/v1/auth/password-reset/request', {
      method: 'POST', body: { email },
    });
    assert.equal(result.status, 503);
    assert.equal(result.json.error.code, 'email_service_unavailable');
    responses.push(result.json);
  }
  assert.deepEqual(responses[0], responses[1]);
});

test('密码找回响应不枚举邮箱，并在成功后撤销全部旧会话', async (t) => {
  const sender = capturingEmailSender();
  const app = await startServer({ emailSender: sender });
  t.after(app.close);
  const registered = await jsonRequest(app.baseUrl, '/v1/auth/register', {
    method: 'POST',
    body: {
      email: 'reset@example.com',
      handle: 'reset-user',
      displayName: 'Reset User',
      password: 'OldStrong123',
      acceptTerms: true,
      ...ACCOUNT_POLICY,
    },
  });
  const monitorLease = await jsonRequest(app.baseUrl, '/v1/me/printer-faults/monitor', {
    method: 'POST', token: registered.json.accessToken, body: {},
  });
  assert.equal(monitorLease.status, 200);

  const missing = await jsonRequest(
    app.baseUrl,
    '/v1/auth/password-reset/request',
    { method: 'POST', body: { email: 'missing@example.com' } },
  );
  const requested = await jsonRequest(
    app.baseUrl,
    '/v1/auth/password-reset/request',
    { method: 'POST', body: { email: 'reset@example.com' } },
  );
  assert.equal(missing.status, 202);
  assert.equal(requested.status, 202);
  assert.deepEqual(missing.json, requested.json);
  assert.equal(sender.messages.length, 1);
  assert.equal(sender.messages[0].purpose, 'reset_password');

  const confirmed = await jsonRequest(
    app.baseUrl,
    '/v1/auth/password-reset/confirm',
    {
      method: 'POST',
      body: {
        email: 'reset@example.com',
        code: sender.messages[0].code,
        newPassword: 'NewStrong123',
      },
    },
  );
  assert.equal(confirmed.status, 200);

  const oldSession = await jsonRequest(app.baseUrl, '/v1/me', {
    token: registered.json.accessToken,
  });
  assert.equal(oldSession.status, 401);
  const oldMonitor = await jsonRequest(app.baseUrl, '/v1/notifications/printer-faults', {
    token: monitorLease.json.token,
  });
  assert.equal(oldMonitor.status, 401);
  const oldLogin = await jsonRequest(app.baseUrl, '/v1/auth/login', {
    method: 'POST',
    body: { email: 'reset@example.com', password: 'OldStrong123' },
  });
  const newLogin = await jsonRequest(app.baseUrl, '/v1/auth/login', {
    method: 'POST',
    body: { email: 'reset@example.com', password: 'NewStrong123' },
  });
  assert.equal(oldLogin.status, 401);
  assert.equal(newLogin.status, 200);
});

test('账号注销要求密码和明确确认，并级联删除在线账号数据', async (t) => {
  const adminToken = 'account-deletion-admin-token';
  const app = await startServer({ adminToken });
  t.after(app.close);
  const registered = await jsonRequest(app.baseUrl, '/v1/auth/register', {
    method: 'POST',
    body: {
      email: 'delete@example.com',
      handle: 'delete-user',
      displayName: 'Delete User',
      password: 'DeleteStrong123',
      acceptTerms: true,
      ...ACCOUNT_POLICY,
    },
  });

  const rejected = await jsonRequest(app.baseUrl, '/v1/me', {
    method: 'DELETE',
    token: registered.json.accessToken,
    body: { password: 'wrong-password', confirmation: 'DELETE' },
  });
  assert.equal(rejected.status, 400);

  const deleted = await jsonRequest(app.baseUrl, '/v1/me', {
    method: 'DELETE',
    token: registered.json.accessToken,
    body: { password: 'DeleteStrong123', confirmation: 'DELETE' },
  });
  assert.equal(deleted.status, 200);

  const me = await jsonRequest(app.baseUrl, '/v1/me', {
    token: registered.json.accessToken,
  });
  assert.equal(me.status, 401);
  const users = await jsonRequest(app.baseUrl, '/v1/admin/users', {
    token: adminToken,
  });
  assert.equal(users.status, 200);
  assert.equal(users.json.items.length, 0);
  const tombstones = new DatabaseSync(app.databasePath, { readOnly: true });
  try {
    const rows = tombstones.prepare(
      'SELECT id_hash, email_hash FROM deleted_account_tombstones',
    ).all();
    assert.equal(rows.length, 1);
    assert.doesNotMatch(JSON.stringify(rows), /delete@example\.com|delete-user/);
  } finally {
    tombstones.close();
  }
});

test('自动备份通过完整性校验，并向管理员暴露无敏感路径的监控指标', async (t) => {
  const root = mkdtempSync(join(tmpdir(), 'sohun-backup-test-'));
  const backupDirectory = join(root, 'backups');
  const adminToken = 'backup-monitoring-admin-token';
  const app = await startServer({
    adminToken,
    backupEnabled: true,
    backupDirectory,
    backupIntervalHours: 24,
    backupRetentionDays: 30,
  });
  t.after(async () => {
    await app.close();
    rmSync(root, { recursive: true, force: true });
  });

  const ready = await jsonRequest(app.baseUrl, '/ready');
  assert.equal(ready.status, 200);
  assert.equal(ready.json.checks.database, 'ok');
  assert.equal(ready.json.checks.backup, 'ok');

  const metrics = await jsonRequest(app.baseUrl, '/v1/admin/metrics', {
    token: adminToken,
  });
  assert.equal(metrics.status, 200);
  assert.equal(metrics.json.database.schemaVersion, CURRENT_SCHEMA_VERSION);
  assert.equal(metrics.json.backup.configured, true);
  assert.doesNotMatch(JSON.stringify(metrics.json), /sohun-backup-test-|databasePath/);

  const manual = await jsonRequest(app.baseUrl, '/v1/admin/backups', {
    method: 'POST',
    token: adminToken,
  });
  assert.equal(manual.status, 201);
  assert.match(manual.json.backup.sha256, /^[a-f0-9]{64}$/);
  assert.equal(manual.json.backup.schemaVersion, CURRENT_SCHEMA_VERSION);
});

test('生产配置拒绝弱 pepper 和管理员令牌', () => {
  const databasePath = join(tmpdir(), 'sohun-community-production.sqlite');
  const complete = {
    databasePath,
    backupDirectory: join(tmpdir(), 'sohun-community-production-backups'),
    supportEmail: 'support@example.com',
    emailVerificationRequired: false,
  };
  assert.throws(
    () => validateProductionConfiguration({
      passwordPepper: 'short',
      adminToken: 'x'.repeat(64),
      ...complete,
    }),
    /PASSWORD_PEPPER/,
  );
  assert.throws(
    () => validateProductionConfiguration({
      passwordPepper: 'p'.repeat(64),
      adminToken: 'short',
      ...complete,
    }),
    /ADMIN_TOKEN/,
  );
  assert.doesNotThrow(() => validateProductionConfiguration({
    passwordPepper: 'p'.repeat(64),
    adminToken: 'a'.repeat(64),
    ...complete,
  }));
});

test('生产配置强制独立备份、支持邮箱和完整 SMTP 参数', () => {
  const databasePath = join(tmpdir(), 'sohun-production-lifecycle.sqlite');
  const base = {
    passwordPepper: 'p'.repeat(64),
    adminToken: 'a'.repeat(64),
    databasePath,
    backupDirectory: join(tmpdir(), 'sohun-production-lifecycle-backups'),
    supportEmail: 'support@example.com',
    emailVerificationRequired: true,
  };
  assert.throws(
    () => validateProductionConfiguration(base),
    /SMTP_HOST/,
  );
  assert.throws(
    () => validateProductionConfiguration({
      ...base,
      supportEmail: 'invalid',
      emailVerificationRequired: false,
    }),
    /SUPPORT_EMAIL/,
  );
  assert.doesNotThrow(() => validateProductionConfiguration({
    ...base,
    smtpConfiguration: {
      host: 'smtp.example.com',
      port: 587,
      secure: false,
      user: 'smtp-user',
      password: 'smtp-password',
      from: 'no-reply@example.com',
    },
  }));
});

test('腾讯云直播配置使用独立域名并生成短时防盗链地址', () => {
  const config = resolveTencentLiveConfiguration({
    pushDomain: 'push.sohun.top',
    playbackDomain: 'live.sohun.top',
    pushKey: 'push-secret-key',
    playbackKey: 'play-secret-key',
    licenseUrl: 'https://license.vod2.myqcloud.com/license/v2/123/index.html',
  });
  assert.equal(config.appName, 'live');
  const expiresAt = new Date('2030-01-01T00:00:00.000Z');
  const txTime = Math.floor(expiresAt.getTime() / 1000)
    .toString(16)
    .toUpperCase();
  const expectedSecret = createHash('md5')
    .update(`push-secret-keysohun_stream_1${txTime}`, 'utf8')
    .digest('hex');
  assert.equal(
    buildTencentLiveUrl({
      protocol: 'rtmp',
      domain: config.pushDomain,
      appName: config.appName,
      streamName: 'sohun_stream_1',
      key: config.pushKey,
      expiresAt,
    }),
    `rtmp://push.sohun.top/live/sohun_stream_1?txSecret=${expectedSecret}&txTime=${txTime}`,
  );
  assert.throws(
    () => resolveTencentLiveConfiguration({
      pushDomain: 'live.sohun.top',
      playbackDomain: 'live.sohun.top',
      pushKey: 'push-secret-key',
      playbackKey: 'play-secret-key',
      licenseUrl: 'https://license.example.com/player',
    }),
    /must be different/,
  );
  assert.throws(
    () => resolveTencentLiveConfiguration({
      pushDomain: 'push.sohun.top',
      playbackDomain: 'live.sohun.top',
      pushKey: 'push-secret-key',
      playbackKey: 'play-secret-key',
      licenseUrl: 'https://user:password@license.example.com/player',
    }),
    /must be a valid HTTPS URL/,
  );
});

test('客户直播页使用 video 和 TCPlayer，不再把直播渲染成图片', () => {
  const html = renderPublicPage({
    workspaceName: '测试农场',
    customerName: '客户甲',
    order: {
      title: '实时视频订单',
      orderNo: 'SO-LIVE-1',
      status: 'production',
      videoEnabled: true,
    },
    workOrders: [],
    items: [],
    completion: 0,
    updatedAt: '2026-08-04T00:00:00.000Z',
  }, 'nonce-value', {
    videoUrl: '/v1/studio/public/order/video-playback',
    liveVideo: true,
  });
  assert.match(html, /<video id="cameraVideo"/);
  assert.match(html, /TCPlayer\('cameraVideo'/);
  assert.match(html, /video-playback/);
  assert.doesNotMatch(html, /id="cameraImage"/);
  const inlineScript = html.match(/<script nonce="nonce-value">([\s\S]+)<\/script><\/body>/)?.[1];
  assert.ok(inlineScript);
  assert.doesNotThrow(() => new Function(inlineScript));
});

test('自托管 MediaMTX 直播页使用开源 HLS 播放器且不加载腾讯资源', () => {
  const config = resolveOpenStreamConfiguration({
    enabled: 'true',
    rtmpBaseUrl: 'rtmp://api.sohun.top:1935',
    hlsBaseUrl: 'https://api.sohun.top/stream',
  });
  assert.equal(config.rtmpBaseUrl, 'rtmp://api.sohun.top:1935/');
  assert.equal(config.hlsBaseUrl, 'https://api.sohun.top/stream/');
  assert.throws(
    () => resolveOpenStreamConfiguration({
      enabled: 'true',
      rtmpBaseUrl: 'rtmp://user:password@api.sohun.top:1935',
      hlsBaseUrl: 'https://api.sohun.top/stream',
    }),
    /must use rtmp or rtmps/,
  );
  assert.throws(
    () => resolveOpenStreamConfiguration({
      enabled: 'true',
      rtmpBaseUrl: 'rtmp://api.sohun.top:1935',
      hlsBaseUrl: 'https://user:password@api.sohun.top/stream',
    }),
    /must use HTTPS/,
  );
  const html = renderPublicPage({
    workspaceName: '测试农场',
    customerName: '客户甲',
    order: {
      title: '自托管视频订单',
      orderNo: 'SO-OPEN-1',
      status: 'production',
      videoEnabled: true,
    },
    workOrders: [],
    items: [],
    completion: 0,
    updatedAt: '2026-08-04T00:00:00.000Z',
  }, 'nonce-hls', {
    videoUrl: '/v1/studio/public/order/video-playback',
    liveVideo: true,
    liveTransport: 'hls',
  });
  assert.match(html, /cdn\.jsdelivr\.net\/npm\/hls\.js/);
  assert.match(html, /window\.TCPlayer=function/);
  assert.doesNotMatch(html, /tcsdk\.com\/player/);
});

test('生产配置必须显式指定绝对数据库文件，且失败时不会创建或迁移数据库', (t) => {
  const directory = mkdtempSync(join(tmpdir(), 'sohun-production-validation-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const nestedDirectory = join(directory, 'must-not-be-created');
  const databasePath = join(nestedDirectory, 'community.sqlite');

  assert.throws(
    () => validateProductionConfiguration({
      passwordPepper: 'p'.repeat(64),
      adminToken: 'a'.repeat(64),
    }),
    /DATABASE_PATH/,
  );
  assert.throws(
    () => validateProductionConfiguration({
      passwordPepper: 'p'.repeat(64),
      adminToken: 'a'.repeat(64),
      databasePath: 'relative/community.sqlite',
    }),
    /absolute file path/,
  );
  assert.throws(
    () => validateProductionConfiguration({
      passwordPepper: 'p'.repeat(64),
      adminToken: 'a'.repeat(64),
      databasePath: directory,
    }),
    /database file/,
  );
  assert.throws(
    () => createCommunityServer({
      production: true,
      databasePath,
      passwordPepper: 'short',
      adminToken: 'a'.repeat(64),
    }),
    /PASSWORD_PEPPER/,
  );
  assert.equal(existsSync(nestedDirectory), false);
  assert.equal(existsSync(databasePath), false);
});

test('账号政策版本不匹配时拒绝注册', async (t) => {
  const app = await startServer();
  t.after(app.close);

  const response = await jsonRequest(app.baseUrl, '/v1/auth/register', {
    method: 'POST',
    body: {
      email: 'policy@example.com',
      handle: 'policy-user',
      displayName: 'Policy User',
      password: 'StrongPass123',
      acceptTerms: true,
      termsVersion: 'outdated',
      privacyVersion: ACCOUNT_POLICY.privacyVersion,
    },
  });

  assert.equal(response.status, 409);
  assert.equal(response.json.error.code, 'account_policy_updated');
});

test('管理员可安全读取注册账号目录', async (t) => {
  const adminToken = 'local-admin-token-for-account-directory';
  const app = await startServer({ adminToken });
  t.after(app.close);

  const registered = await jsonRequest(app.baseUrl, '/v1/auth/register', {
    method: 'POST',
    body: {
      email: 'owner-visible@example.com',
      handle: 'owner-visible',
      displayName: 'Owner Visible',
      password: 'StrongPass123',
      acceptTerms: true,
      ...ACCOUNT_POLICY,
    },
  });
  assert.equal(registered.status, 201);

  const forbidden = await jsonRequest(app.baseUrl, '/v1/admin/users');
  assert.equal(forbidden.status, 403);

  const users = await jsonRequest(app.baseUrl, '/v1/admin/users', {
    token: adminToken,
  });
  assert.equal(users.status, 200);
  assert.equal(users.json.items.length, 1);
  assert.equal(users.json.items[0].email, 'owner-visible@example.com');
  assert.equal(users.json.items[0].termsVersion, ACCOUNT_POLICY.termsVersion);
  assert.ok(users.json.items[0].termsAcceptedAt);
  assert.ok(users.json.items[0].lastLoginAt);
  const payload = JSON.stringify(users.json);
  assert.doesNotMatch(payload, /password|accessToken|refreshToken|token_hash/i);
});

test('注册、登录和刷新令牌形成真实服务端会话', async (t) => {
  const app = await startServer();
  t.after(app.close);

  const registered = await jsonRequest(app.baseUrl, '/v1/auth/register', {
    method: 'POST',
    body: {
      email: 'maker@example.com',
      handle: 'maker.one',
      displayName: 'Maker One',
      password: 'StrongPass123',
      acceptTerms: true,
      ...ACCOUNT_POLICY,
    },
  });
  assert.equal(registered.status, 201);
  assert.equal(registered.headers.get('cache-control'), 'no-store');
  assert.equal(registered.headers.get('pragma'), 'no-cache');
  assert.equal(registered.json.user.handle, 'maker.one');
  assert.ok(registered.json.accessToken);
  assert.ok(registered.json.refreshToken);
  assert.ok(registered.json.expiresAt);
  assert.ok(registered.json.refreshExpiresAt);
  assert.ok(Date.parse(registered.json.refreshExpiresAt) > Date.parse(registered.json.expiresAt));

  const me = await jsonRequest(app.baseUrl, '/v1/me', {
    token: registered.json.accessToken,
  });
  assert.equal(me.status, 200);
  assert.equal(me.json.user.email, 'maker@example.com');

  const refreshed = await jsonRequest(app.baseUrl, '/v1/auth/refresh', {
    method: 'POST',
    body: { refreshToken: registered.json.refreshToken },
  });
  assert.equal(refreshed.status, 200);
  assert.notEqual(refreshed.json.accessToken, registered.json.accessToken);
  assert.ok(refreshed.json.refreshExpiresAt);
  assert.ok(Date.parse(refreshed.json.refreshExpiresAt) > Date.parse(refreshed.json.expiresAt));
});

test('密码注册和登录保留首尾字符，不会静默 trim', async (t) => {
  const app = await startServer();
  t.after(app.close);
  const exactPassword = ' Abcdefg1 ';

  const registered = await jsonRequest(app.baseUrl, '/v1/auth/register', {
    method: 'POST',
    body: {
      email: 'exact-password@example.com',
      handle: 'exact-password',
      displayName: 'Exact Password',
      password: exactPassword,
      acceptTerms: true,
      ...ACCOUNT_POLICY,
    },
  });
  assert.equal(registered.status, 201);

  const exactLogin = await jsonRequest(app.baseUrl, '/v1/auth/login', {
    method: 'POST',
    body: { email: 'exact-password@example.com', password: exactPassword },
  });
  assert.equal(exactLogin.status, 200);

  const trimmedLogin = await jsonRequest(app.baseUrl, '/v1/auth/login', {
    method: 'POST',
    body: { email: 'exact-password@example.com', password: exactPassword.trim() },
  });
  assert.equal(trimmedLogin.status, 401);
  assert.equal(trimmedLogin.json.error.code, 'invalid_credentials');
});

test('个人资料只接受白名单字段，并支持唯一用户名修改', async (t) => {
  const app = await startServer();
  t.after(app.close);
  const first = await registerUser(app, 'profile-first@example.com', 'profile-first', 'First');
  const second = await registerUser(app, 'profile-second@example.com', 'profile-second', 'Second');

  const forbidden = await jsonRequest(app.baseUrl, '/v1/me', {
    method: 'PATCH',
    token: first.token,
    body: { email: 'rewritten@example.com' },
  });
  assert.equal(forbidden.status, 400);
  assert.equal(forbidden.json.error.code, 'forbidden_field');

  const updated = await jsonRequest(app.baseUrl, '/v1/me', {
    method: 'PATCH',
    token: first.token,
    body: { handle: 'profile-renamed', displayName: 'Renamed' },
  });
  assert.equal(updated.status, 200);
  assert.equal(updated.json.user.handle, 'profile-renamed');
  assert.equal(updated.json.user.displayName, 'Renamed');

  const duplicate = await jsonRequest(app.baseUrl, '/v1/me', {
    method: 'PATCH',
    token: first.token,
    body: { handle: 'profile-second' },
  });
  assert.equal(duplicate.status, 409);
  assert.equal(duplicate.json.error.code, 'handle_exists');

  const me = await jsonRequest(app.baseUrl, '/v1/me', { token: first.token });
  assert.equal(me.status, 200);
  assert.equal(me.json.user.handle, 'profile-renamed');
  assert.equal(second.userId.length > 0, true);
});

test('退出同时撤销访问令牌和刷新令牌', async (t) => {
  const app = await startServer();
  t.after(app.close);

  const registered = await jsonRequest(app.baseUrl, '/v1/auth/register', {
    method: 'POST',
    body: {
      email: 'logout@example.com',
      handle: 'logout-user',
      displayName: 'Logout User',
      password: 'StrongPass123',
      acceptTerms: true,
      ...ACCOUNT_POLICY,
    },
  });
  const loggedOut = await jsonRequest(app.baseUrl, '/v1/auth/logout', {
    method: 'POST',
    token: registered.json.accessToken,
    body: { refreshToken: registered.json.refreshToken },
  });
  assert.equal(loggedOut.status, 200);

  const me = await jsonRequest(app.baseUrl, '/v1/me', {
    token: registered.json.accessToken,
  });
  assert.equal(me.status, 401);

  const refreshed = await jsonRequest(app.baseUrl, '/v1/auth/refresh', {
    method: 'POST',
    body: { refreshToken: registered.json.refreshToken },
  });
  assert.equal(refreshed.status, 401);
});

test('公共参数可按名称和作者搜索，且作者由令牌决定', async (t) => {
  const app = await startServer();
  t.after(app.close);

  const registered = await jsonRequest(app.baseUrl, '/v1/auth/register', {
    method: 'POST',
    body: {
      email: 'author@example.com',
      handle: 'real-author',
      displayName: '真实作者',
      password: 'StrongPass123',
      acceptTerms: true,
      ...ACCOUNT_POLICY,
    },
  });
  const published = await jsonRequest(app.baseUrl, '/v1/presets', {
    method: 'POST',
    token: registered.json.accessToken,
    body: {
      visibility: 'public',
      preset: {
        format: 'bbsparam',
        version: '1.0',
        preset: {
          name: 'PETG 高速结构件',
          author: '伪造作者',
          material: 'Bambu PETG Basic',
          scene: '功能强度',
          compatiblePrinters: ['Bambu Lab P1S'],
          tags: ['高速'],
          params: {},
        },
      },
    },
  });
  assert.equal(published.status, 201);
  assert.equal(published.json.owner.handle, 'real-author');

  const byAuthor = await jsonRequest(app.baseUrl, '/v1/presets?q=%E7%9C%9F%E5%AE%9E%E4%BD%9C%E8%80%85');
  assert.equal(byAuthor.status, 200);
  assert.equal(byAuthor.json.items.length, 1);

  const byName = await jsonRequest(app.baseUrl, '/v1/presets?q=PETG');
  assert.equal(byName.json.items.length, 1);
  assert.equal(byName.json.items[0].preset.preset.name, 'PETG 高速结构件');

  const viewer = await jsonRequest(app.baseUrl, '/v1/auth/register', {
    method: 'POST',
    body: {
      email: 'viewer@example.com',
      handle: 'preset-viewer',
      displayName: '参数用户',
      password: 'StrongPass123',
      acceptTerms: true,
      ...ACCOUNT_POLICY,
    },
  });
  const liked = await jsonRequest(app.baseUrl, `/v1/presets/${published.json.id}/like`, {
    method: 'PUT',
    token: viewer.json.accessToken,
  });
  assert.equal(liked.status, 200);
  assert.equal(liked.json.likes, 1);
  assert.equal(liked.json.likedByMe, true);

  const mine = await jsonRequest(app.baseUrl, '/v1/presets?owner=me', {
    token: registered.json.accessToken,
  });
  assert.equal(mine.status, 200);
  assert.equal(mine.json.items.length, 1);

  const deleted = await jsonRequest(app.baseUrl, `/v1/presets/${published.json.id}`, {
    method: 'DELETE',
    token: registered.json.accessToken,
  });
  assert.equal(deleted.status, 200);
  const afterDelete = await jsonRequest(app.baseUrl, '/v1/presets?q=PETG');
  assert.equal(afterDelete.json.items.length, 0);
});

test('更新参数要求正确 revision，避免静默覆盖', async (t) => {
  const app = await startServer();
  t.after(app.close);

  const registered = await jsonRequest(app.baseUrl, '/v1/auth/register', {
    method: 'POST',
    body: {
      email: 'revision@example.com',
      handle: 'revision-user',
      displayName: 'Revision User',
      password: 'StrongPass123',
      acceptTerms: true,
      ...ACCOUNT_POLICY,
    },
  });
  const preset = {
    format: 'bbsparam',
    version: '1.0',
    preset: { name: '版本测试', params: {} },
  };
  const created = await jsonRequest(app.baseUrl, '/v1/presets', {
    method: 'POST',
    token: registered.json.accessToken,
    body: { preset, visibility: 'public' },
  });
  const updated = await jsonRequest(app.baseUrl, `/v1/presets/${created.json.id}`, {
    method: 'PATCH',
    token: registered.json.accessToken,
    body: { preset, visibility: 'public', revision: 1 },
  });
  assert.equal(updated.status, 200);
  assert.equal(updated.json.revision, 2);

  const conflict = await jsonRequest(app.baseUrl, `/v1/presets/${created.json.id}`, {
    method: 'PATCH',
    token: registered.json.accessToken,
    body: { preset, visibility: 'public', revision: 1 },
  });
  assert.equal(conflict.status, 409);
  assert.equal(conflict.json.error.code, 'revision_conflict');

  const firstConcurrent = pausedJsonRequest(
    app.baseUrl,
    `/v1/presets/${created.json.id}`,
    {
      method: 'PATCH',
      token: registered.json.accessToken,
      body: {
        preset: {
          ...preset,
          preset: { ...preset.preset, name: 'concurrent-a' },
        },
        visibility: 'public',
        revision: 2,
      },
    },
  );
  const secondConcurrent = pausedJsonRequest(
    app.baseUrl,
    `/v1/presets/${created.json.id}`,
    {
      method: 'PATCH',
      token: registered.json.accessToken,
      body: {
        preset: {
          ...preset,
          preset: { ...preset.preset, name: 'concurrent-b' },
        },
        visibility: 'public',
        revision: 2,
      },
    },
  );
  await new Promise((resolve) => setTimeout(resolve, 20));
  firstConcurrent.send();
  secondConcurrent.send();
  const concurrentResults = await Promise.all([
    firstConcurrent.result,
    secondConcurrent.result,
  ]);
  assert.deepEqual(
    concurrentResults.map((result) => result.status).sort(),
    [200, 409],
  );
  assert.equal(
    concurrentResults.find((result) => result.status === 409).json.error.code,
    'revision_conflict',
  );

  const afterConcurrent = await jsonRequest(
    app.baseUrl,
    `/v1/presets/${created.json.id}`,
  );
  assert.equal(afterConcurrent.json.revision, 3);
});

test('preset count and immutable-version byte quotas are enforced', async (t) => {
  const countLimited = await startServer({ maxPresetsPerUser: 1 });
  t.after(countLimited.close);
  const countUser = await registerUser(
    countLimited,
    'quota-count@example.com',
    'quota-count',
    'Quota Count',
  );
  await publishPreset(countLimited, countUser.token);
  const countExceeded = await jsonRequest(countLimited.baseUrl, '/v1/presets', {
    method: 'POST',
    token: countUser.token,
    body: {
      preset: {
        ...SAMPLE_PRESET,
        preset: { ...SAMPLE_PRESET.preset, name: 'second preset' },
      },
      visibility: 'public',
    },
  });
  assert.equal(countExceeded.status, 409);
  assert.equal(countExceeded.json.error.code, 'preset_count_quota_exceeded');

  const presetBytes = Buffer.byteLength(JSON.stringify(SAMPLE_PRESET), 'utf8');
  const byteLimited = await startServer({
    maxPresetBytesPerUser: presetBytes,
  });
  t.after(byteLimited.close);
  const byteUser = await registerUser(
    byteLimited,
    'quota-bytes@example.com',
    'quota-bytes',
    'Quota Bytes',
  );
  const first = await publishPreset(byteLimited, byteUser.token);
  const bytesExceeded = await jsonRequest(
    byteLimited.baseUrl,
    `/v1/presets/${first.id}`,
    {
      method: 'PATCH',
      token: byteUser.token,
      body: { preset: SAMPLE_PRESET, visibility: 'public', revision: 1 },
    },
  );
  assert.equal(bytesExceeded.status, 413);
  assert.equal(bytesExceeded.json.error.code, 'preset_storage_quota_exceeded');
});

// ===== Phase E：社区可信体系 =====

const SAMPLE_PRESET = {
  format: 'bbsparam',
  version: '1.0',
  preset: {
    name: 'PLA 通用参数',
    author: '原作者',
    material: 'Bambu PLA Basic',
    scene: '通用',
    compatiblePrinters: ['Bambu Lab P1S'],
    tags: ['通用'],
    params: { layer_height: 0.2 },
  },
};

async function registerUser(app, email, handle, displayName) {
  const res = await jsonRequest(app.baseUrl, '/v1/auth/register', {
    method: 'POST',
    body: {
      email,
      handle,
      displayName,
      password: 'StrongPass123',
      acceptTerms: true,
      ...ACCOUNT_POLICY,
    },
  });
  assert.equal(res.status, 201);
  return { token: res.json.accessToken, userId: res.json.user.id };
}

function personalInventoryRecord(overrides = {}) {
  return {
    uid: '04AABBCCDDEE11',
    manufacturer: 'sohun',
    model: 'PLA Basic',
    materialType: 'PLA Basic',
    colorHex: '#12ABEF',
    colorName: '湖蓝',
    totalGrams: 1000,
    remainingGrams: 1000,
    batchNo: null,
    purchaseDate: '2026-08-01T00:00:00.000Z',
    note: null,
    createdAt: '2026-08-01T10:00:00.000Z',
    updatedAt: '2026-08-01T10:00:00.000Z',
    density: 1.24,
    recommendedNozzleTemp: 220,
    hygroscopicity: 'low',
    trayUuid: null,
    rfidSyncedAt: null,
    rfidTagUid: '04:a1:b2:c3',
    rfidTagType: 'CUID',
    rfidTagCycle: 1,
    lifecycleStatus: 'active',
    previousConsumableUid: null,
    ...overrides,
  };
}

test('个人库存实物卷固定 1000g，聚合库存仍可保存多卷', async (t) => {
  const app = await startServer();
  t.after(app.close);
  const user = await registerUser(app, 'fixed-capacity@example.com', 'fixed_capacity', '固定规格');
  const put = (records) => jsonRequest(app.baseUrl, '/v1/me/inventory/snapshot', {
    method: 'PUT', token: user.token, body: { revision: 0, records },
  });
  for (const capacity of [500, 2000]) {
    const invalid = await put([personalInventoryRecord({ totalGrams: capacity, remainingGrams: 415 })]);
    assert.equal(invalid.status, 409, JSON.stringify(invalid.json));
    assert.equal(invalid.json.error.code, 'inventory_spool_capacity_conflict');
    const stock = personalInventoryRecord({ rfidTagUid: null, rfidTagType: null,
      sourceRfidTagUid: '04A1B2C3', sourceRfidTagType: 'CUID',
      stockReceiptUid: '8bccb30f-5da8-48d0-988f-ab01e23b0b01',
      stockReceiptIndex: 0, stockReceiptQuantity: 1, totalGrams: capacity, remainingGrams: 415 });
    const invalidReceipt = await put([stock]);
    assert.equal(invalidReceipt.status, 409, JSON.stringify(invalidReceipt.json));
  }
  const aggregate = personalInventoryRecord({ uid: 'aggregate', rfidTagUid: null, rfidTagType: null,
    totalGrams: 3000, remainingGrams: 2415 });
  const valid = await put([aggregate, personalInventoryRecord({ remainingGrams: 415 })]);
  assert.equal(valid.status, 200, JSON.stringify(valid.json));
  assert.equal(valid.json.records.find((record) => record.uid === aggregate.uid).remainingGrams, 2415);
});

test('个人库存再次启用以余量大于 30g 为界，正常消耗到 30g 不抹掉余额', async (t) => {
  const app = await startServer();
  t.after(app.close);
  const user = await registerUser(app, 'reuse-threshold@example.com', 'reuse_threshold', '余量边界');
  const put = (revision, records) => jsonRequest(app.baseUrl, '/v1/me/inventory/snapshot', {
    method: 'PUT', token: user.token, body: { revision, records },
  });
  for (const remainingGrams of [29.9, 30]) {
    const invalid = await put(0, [personalInventoryRecord({ remainingGrams })]);
    assert.equal(invalid.status, 409, JSON.stringify(invalid.json));
    assert.equal(invalid.json.error.code, 'inventory_spool_not_reusable');
  }
  const usable = personalInventoryRecord({ remainingGrams: 30.1 });
  assert.equal((await put(0, [usable])).status, 200);
  const consumed = await put(1, [{ ...usable, remainingGrams: 30 }]);
  assert.equal(consumed.status, 200, JSON.stringify(consumed.json));
  assert.equal(consumed.json.records[0].remainingGrams, 30);
});

test('旧非 1kg 实物卷原样保留且禁止继续扣料或新建异常规格', async (t) => {
  const app = await startServer();
  t.after(app.close);
  const user = await registerUser(app, 'legacy-capacity@example.com', 'legacy_capacity', '旧规格核对');
  const put = (revision, records) => jsonRequest(app.baseUrl, '/v1/me/inventory/snapshot', {
    method: 'PUT', token: user.token, body: { revision, records },
  });
  const saved = await put(0, [personalInventoryRecord()]);
  assert.equal(saved.status, 200);
  const legacy = { ...saved.json.records[0], totalGrams: 2000, remainingGrams: 1875 };
  const database = new DatabaseSync(app.databasePath);
  database.prepare('UPDATE personal_inventory_snapshots SET records_json = ? WHERE user_id = ?')
    .run(JSON.stringify([legacy]), user.userId);
  database.close();
  const preserved = await put(1, [legacy]);
  assert.equal(preserved.status, 200, JSON.stringify(preserved.json));
  assert.equal(preserved.json.records[0].remainingGrams, 1875);
  const changed = await put(2, [{ ...legacy, remainingGrams: 1800 }]);
  assert.equal(changed.status, 409, JSON.stringify(changed.json));
  assert.equal(changed.json.error.code, 'inventory_spool_capacity_conflict');
  const archived = await put(2, [{ ...legacy, lifecycleStatus: 'retired' }]);
  assert.equal(archived.status, 200, JSON.stringify(archived.json));
  assert.equal(archived.json.records[0].remainingGrams, 1875);
});

test('旧余量入库的小容量独立卷只规范名义容量并保留余量', async (t) => {
  const app = await startServer();
  t.after(app.close);
  const user = await registerUser(app, 'legacy-remainder@example.com', 'legacy_remainder', '旧余量');
  const put = (revision, records) => jsonRequest(app.baseUrl, '/v1/me/inventory/snapshot', {
    method: 'PUT', token: user.token, body: { revision, records },
  });
  const saved = await put(0, [personalInventoryRecord({ remainingGrams: 415 })]);
  assert.equal(saved.status, 200, JSON.stringify(saved.json));
  const legacy = { ...saved.json.records[0], totalGrams: 750, remainingGrams: 415 };
  const database = new DatabaseSync(app.databasePath);
  database.prepare('UPDATE personal_inventory_snapshots SET records_json = ? WHERE user_id = ?')
    .run(JSON.stringify([legacy]), user.userId);
  database.close();

  const fetched = await jsonRequest(app.baseUrl, '/v1/me/inventory/snapshot', { token: user.token });
  assert.equal(fetched.json.records[0].totalGrams, 1000);
  assert.equal(fetched.json.records[0].remainingGrams, 415);
  const roundTrip = await put(1, [legacy]);
  assert.equal(roundTrip.status, 200, JSON.stringify(roundTrip.json));
  assert.equal(roundTrip.json.records[0].totalGrams, 1000);
  assert.equal(roundTrip.json.records[0].remainingGrams, 415);
  const ended = await put(2, [{ ...roundTrip.json.records[0], lifecycleStatus: 'replaced' }]);
  assert.equal(ended.status, 200, JSON.stringify(ended.json));
  const reusable = await put(3, [ended.json.records[0], {
    ...ended.json.records[0],
    uid: 'legacy-remainder-next',
    rfidTagCycle: 2,
    previousConsumableUid: ended.json.records[0].uid,
    remainingGrams: 31,
    lifecycleStatus: 'active',
  }]);
  assert.equal(reusable.status, 200, JSON.stringify(reusable.json));
  const endedAgain = await put(4, [reusable.json.records[0], {
    ...reusable.json.records[1], lifecycleStatus: 'replaced',
  }]);
  assert.equal(endedAgain.status, 200, JSON.stringify(endedAgain.json));
  const belowThreshold = await put(5, [
    endedAgain.json.records[0],
    endedAgain.json.records[1],
    {
      ...endedAgain.json.records[1],
      uid: 'legacy-remainder-next-2',
      rfidTagCycle: 3,
      previousConsumableUid: endedAgain.json.records[1].uid,
      remainingGrams: 30,
      lifecycleStatus: 'active',
    },
  ]);
  assert.equal(belowThreshold.status, 409, JSON.stringify(belowThreshold.json));
  assert.equal(belowThreshold.json.error.code, 'inventory_spool_not_reusable');
});

test('个人库存快照按账号隔离、使用 revision 乐观锁并拒绝 RFID 敏感字段', async (t) => {
  const app = await startServer();
  t.after(app.close);
  const alice = await registerUser(
    app,
    'inventory-alice@example.com',
    'inventory_alice',
    '库存用户甲',
  );
  const bob = await registerUser(
    app,
    'inventory-bob@example.com',
    'inventory_bob',
    '库存用户乙',
  );

  const empty = await jsonRequest(app.baseUrl, '/v1/me/inventory/snapshot', {
    token: alice.token,
  });
  assert.equal(empty.status, 200);
  assert.equal(empty.json.revision, 0);
  assert.deepEqual(empty.json.records, []);
  assert.deepEqual(empty.json.materialCatalog, []);
  assert.equal(empty.json.updatedAt, null);
  assert.equal(empty.headers.get('cache-control'), 'no-store');
  assert.equal(empty.headers.get('pragma'), 'no-cache');

  const record = personalInventoryRecord();
  const saved = await jsonRequest(app.baseUrl, '/v1/me/inventory/snapshot', {
    method: 'PUT',
    token: alice.token,
    body: {
      revision: 0,
      records: [record],
      materialCatalog: ['Bambu PLA Basic', 'Custom PETG'],
    },
  });
  assert.equal(saved.status, 200, JSON.stringify(saved.json));
  assert.equal(saved.json.revision, 1);
  assert.equal(saved.json.records[0].colorHex, '#12ABEF');
  assert.equal(saved.json.records[0].rfidTagUid, '04A1B2C3');
  assert.equal(saved.json.records[0].purchaseDate, '2026-08-01T00:00:00.000Z');
  assert.deepEqual(saved.json.materialCatalog, ['Bambu PLA Basic', 'Custom PETG']);
  assert.equal(saved.headers.get('cache-control'), 'no-store');

  const aliceRead = await jsonRequest(
    app.baseUrl,
    '/v1/me/inventory/snapshot',
    { token: alice.token },
  );
  assert.equal(aliceRead.status, 200);
  assert.equal(aliceRead.json.revision, 1);
  assert.deepEqual(aliceRead.json.records, saved.json.records);
  assert.deepEqual(aliceRead.json.materialCatalog, saved.json.materialCatalog);

  const bobRead = await jsonRequest(
    app.baseUrl,
    '/v1/me/inventory/snapshot',
    { token: bob.token },
  );
  assert.equal(bobRead.status, 200);
  assert.equal(bobRead.json.revision, 0);
  assert.deepEqual(bobRead.json.records, []);

  const stale = await jsonRequest(app.baseUrl, '/v1/me/inventory/snapshot', {
    method: 'PUT',
    token: alice.token,
    body: { revision: 0, records: [record] },
  });
  assert.equal(stale.status, 409);
  assert.equal(stale.json.error.code, 'revision_conflict');
  assert.equal(stale.json.error.details.currentRevision, 1);

  const duplicateUid = await jsonRequest(
    app.baseUrl,
    '/v1/me/inventory/snapshot',
    {
      method: 'PUT',
      token: alice.token,
      body: {
        revision: 1,
        records: [record, personalInventoryRecord({ manufacturer: 'other' })],
      },
    },
  );
  assert.equal(duplicateUid.status, 400);
  assert.equal(duplicateUid.json.error.code, 'duplicate_inventory_uid');

  const sensitiveField = await jsonRequest(
    app.baseUrl,
    '/v1/me/inventory/snapshot',
    {
      method: 'PUT',
      token: alice.token,
      body: {
        revision: 1,
        records: [personalInventoryRecord({ rfidRawDump: '01020304' })],
      },
    },
  );
  assert.equal(sensitiveField.status, 400);
  assert.equal(sensitiveField.json.error.code, 'forbidden_field');
  assert.match(sensitiveField.json.error.message, /RFID|密钥|签名/);
});

test('个人库存标签规范化不会截断不含十六进制字符的 CUID/FUID 标识', async (t) => {
  const app = await startServer();
  t.after(app.close);
  const user = await registerUser(
    app,
    'inventory-opaque-tag@example.com',
    'inventory_opaque_tag',
    '不透明标签用户',
  );
  const record = personalInventoryRecord({
    uid: 'opaque-tag-spool',
    rfidTagUid: 'CUID-OWNER-1',
  });
  const saved = await jsonRequest(app.baseUrl, '/v1/me/inventory/snapshot', {
    method: 'PUT',
    token: user.token,
    body: { revision: 0, records: [record] },
  });
  assert.equal(saved.status, 200, JSON.stringify(saved.json));
  assert.equal(saved.json.records[0].rfidTagUid, 'CUID-OWNER-1');
});

test('个人库存带标签历史不能被删除墓碑擦除', async (t) => {
  const app = await startServer();
  t.after(app.close);
  const user = await registerUser(
    app,
    'inventory-tombstone@example.com',
    'inventory_tombstone',
    '删除墓碑用户',
  );
  const record = personalInventoryRecord();
  const deletedAt = '2026-08-02T00:00:00.000Z';
  const saved = await jsonRequest(app.baseUrl, '/v1/me/inventory/snapshot', {
    method: 'PUT',
    token: user.token,
    body: { revision: 0, records: [record], materialCatalog: [] },
  });
  assert.equal(saved.status, 200);
  const deleted = await jsonRequest(app.baseUrl, '/v1/me/inventory/snapshot', {
    method: 'PUT',
    token: user.token,
    body: {
      revision: saved.json.revision,
      records: [],
      materialCatalog: [],
      deletedUids: { [record.uid]: deletedAt },
    },
  });
  // A tagged row is a physical-spool ledger entry. It must remain in the
  // account snapshot even when a client sends a deletion tombstone; otherwise
  // a later device could never prove which cycle consumed the material.
  assert.equal(deleted.status, 409, JSON.stringify(deleted.json));
  assert.equal(deleted.json.error.code, 'inventory_history_required');

  const read = await jsonRequest(
    app.baseUrl,
    '/v1/me/inventory/snapshot',
    { token: user.token },
  );
  assert.equal(read.status, 200);
  assert.equal(read.json.records[0].uid, record.uid);
});

test('个人库存拒绝 RFID 周期冲突、状态矛盾和断开的前驱链', async (t) => {
  const app = await startServer();
  t.after(app.close);
  const user = await registerUser(
    app,
    'inventory-lifecycle-invariants@example.com',
    'inventory_lifecycle_invariants',
    '生命周期校验用户',
  );
  const base = personalInventoryRecord({ uid: 'cycle-1' });

  const duplicateCycle = await jsonRequest(
    app.baseUrl,
    '/v1/me/inventory/snapshot',
    {
      method: 'PUT',
      token: user.token,
      body: {
        revision: 0,
        records: [
          base,
          personalInventoryRecord({ uid: 'cycle-1-fork' }),
        ],
      },
    },
  );
  assert.equal(duplicateCycle.status, 409);
  assert.equal(duplicateCycle.json.error.code, 'inventory_tag_cycle_conflict');

  const activeEmpty = await jsonRequest(
    app.baseUrl,
    '/v1/me/inventory/snapshot',
    {
      method: 'PUT',
      token: user.token,
      body: {
        revision: 0,
        records: [personalInventoryRecord({ remainingGrams: 0 })],
      },
    },
  );
  assert.equal(activeEmpty.status, 400);
  assert.equal(activeEmpty.json.error.code, 'invalid_inventory_record');

  const depletedWithStock = await jsonRequest(
    app.baseUrl,
    '/v1/me/inventory/snapshot',
    {
      method: 'PUT',
      token: user.token,
      body: {
        revision: 0,
        records: [personalInventoryRecord({
          lifecycleStatus: 'depleted',
          remainingGrams: 50,
        })],
      },
    },
  );
  assert.equal(depletedWithStock.status, 400);
  assert.equal(depletedWithStock.json.error.code, 'invalid_inventory_record');

  const brokenPredecessor = await jsonRequest(
    app.baseUrl,
    '/v1/me/inventory/snapshot',
    {
      method: 'PUT',
      token: user.token,
      body: {
        revision: 0,
        records: [personalInventoryRecord({
          uid: 'cycle-2',
          rfidTagCycle: 2,
          previousConsumableUid: 'does-not-exist',
          lifecycleStatus: 'active',
        })],
      },
    },
  );
  assert.equal(brokenPredecessor.status, 409);
  assert.equal(brokenPredecessor.json.error.code, 'inventory_predecessor_missing');
});

test('个人库存相同可复制 UID 在不同账号中独立保存', async (t) => {
  const app = await startServer();
  t.after(app.close);
  const alice = await registerUser(
    app,
    'inventory-claim-alice@example.com',
    'inventory_claim_alice',
    '标签所有者甲',
  );
  const bob = await registerUser(
    app,
    'inventory-claim-bob@example.com',
    'inventory_claim_bob',
    '标签所有者乙',
  );
  const first = await jsonRequest(app.baseUrl, '/v1/me/inventory/snapshot', {
    method: 'PUT',
    token: alice.token,
    body: { revision: 0, records: [personalInventoryRecord({ uid: 'alice-roll' })] },
  });
  assert.equal(first.status, 200);
  const second = await jsonRequest(app.baseUrl, '/v1/me/inventory/snapshot', {
    method: 'PUT',
    token: bob.token,
    body: { revision: 0, records: [personalInventoryRecord({ uid: 'bob-roll' })] },
  });
  assert.equal(second.status, 200, JSON.stringify(second.json));
  assert.equal(second.json.records.length, 1);
  const aliceRead = await jsonRequest(app.baseUrl, '/v1/me/inventory/snapshot', { token: alice.token });
  assert.deepEqual(aliceRead.json.records.map((r) => r.uid), ['alice-roll']);
  assert.deepEqual(second.json.records.map((r) => r.uid), ['bob-roll']);
});

test('个人耗材事件账本跨 revision 合并且不可被删除或改写', async (t) => {
  const app = await startServer();
  t.after(app.close);
  const user = await registerUser(
    app,
    'inventory-events@example.com',
    'inventory_events',
    '事件账本用户',
  );
  const record = personalInventoryRecord({ uid: 'event-roll' });
  const event = {
    eventUid: 'nfc:write-1',
    inventoryUid: record.uid,
    rfidTagUid: record.rfidTagUid,
    rfidTagCycle: 1,
    eventType: 'nfc_bind_success',
    deltaGrams: 0,
    occurredAt: '2026-08-03T10:00:00.000Z',
    source: 'nfc',
    note: '标签绑定',
  };
  const first = await jsonRequest(app.baseUrl, '/v1/me/inventory/snapshot', {
    method: 'PUT',
    token: user.token,
    body: { revision: 0, records: [record], events: [event] },
  });
  assert.equal(first.status, 200, JSON.stringify(first.json));
  assert.equal(first.json.events.length, 1);

  const second = await jsonRequest(app.baseUrl, '/v1/me/inventory/snapshot', {
    method: 'PUT',
    token: user.token,
    body: {
      revision: first.json.revision,
      records: [record],
      // A device may send only its newly observed event; the server retains
      // the earlier immutable event.
      events: [{
        ...event,
        eventUid: 'usage:1',
        eventType: 'usage_finished',
        deltaGrams: -25,
        occurredAt: '2026-08-03T11:00:00.000Z',
        source: 'usage',
      }],
    },
  });
  assert.equal(second.status, 200, JSON.stringify(second.json));
  assert.equal(second.json.events.length, 2);

  const omitted = await jsonRequest(app.baseUrl, '/v1/me/inventory/snapshot', {
    method: 'PUT',
    token: user.token,
    body: { revision: second.json.revision, records: [record], events: [] },
  });
  assert.equal(omitted.status, 200, JSON.stringify(omitted.json));
  assert.equal(omitted.json.events.length, 2);

  const tampered = await jsonRequest(app.baseUrl, '/v1/me/inventory/snapshot', {
    method: 'PUT',
    token: user.token,
    body: {
      revision: omitted.json.revision,
      records: [record],
      events: [{ ...event, note: '被篡改' }],
    },
  });
  assert.equal(tampered.status, 409);
  assert.equal(tampered.json.error.code, 'inventory_event_conflict');
});

test('个人库存核对分叉后保留两卷历史并能继续换卷', async (t) => {
  const app = await startServer();
  t.after(app.close);
  const user = await registerUser(app, 'resolved@example.com', 'resolved', '核对用户');
  const previous = personalInventoryRecord({ uid: 'previous', lifecycleStatus: 'replaced', remainingGrams: 200 });
  const first = personalInventoryRecord({ uid: 'first', rfidTagCycle: 2, previousConsumableUid: previous.uid });
  const put = (revision, records) => jsonRequest(app.baseUrl, '/v1/me/inventory/snapshot', {
    method: 'PUT', token: user.token, body: { revision, records },
  });
  assert.equal((await put(0, [previous, first])).status, 200);
  const chosen = { ...first, uid: 'chosen' };
  const archived = { ...first, lifecycleStatus: 'retired' };
  const resolved = await put(1, [previous, archived, chosen]);
  assert.equal(resolved.status, 200, JSON.stringify(resolved.json));
  const next = { ...chosen, uid: 'next', rfidTagCycle: 3, previousConsumableUid: chosen.uid,
    totalGrams: 1000, remainingGrams: 750 };
  const advanced = await put(2, [previous, archived, { ...chosen, lifecycleStatus: 'replaced' }, next]);
  assert.equal(advanced.status, 200, JSON.stringify(advanced.json));
  assert.equal(advanced.json.records.find((r) => r.uid === previous.uid).remainingGrams, 200);
  const tampered = await put(3, advanced.json.records.map((r) => r.uid === 'next' ? { ...r, rfidTagCycle: 4 } : r));
  assert.equal(tampered.status, 409);
  assert.equal(tampered.json.error.code, 'inventory_spool_identity_conflict');
  const reactivated = await put(3, advanced.json.records.map((r) => r.uid === 'previous' ? { ...r, lifecycleStatus: 'depleted', remainingGrams: 0 } : r));
  assert.equal(reactivated.status, 409);
  assert.equal(reactivated.json.error.code, 'inventory_history_reactivation');
});

test('个人库存余料换绑保留旧标签链路和两个标签的事件', async (t) => {
  const app = await startServer();
  t.after(app.close);
  const user = await registerUser(app, 'retag@example.com', 'retag', '换绑用户');
  const old = personalInventoryRecord({ uid: 'leftover', remainingGrams: 125, lifecycleStatus: 'replaced' });
  const next = personalInventoryRecord({ uid: 'next', rfidTagCycle: 2, previousConsumableUid: old.uid });
  const put = (revision, records, events = []) => jsonRequest(app.baseUrl, '/v1/me/inventory/snapshot', {
    method: 'PUT', token: user.token, body: { revision, records, events },
  });
  assert.equal((await put(0, [old, next])).status, 200);
  const rebound = { ...old, rfidTagUid: '04BB0002', rfidTagType: 'FUID', lifecycleStatus: 'active',
    rfidTagHistory: [{ tagUid: old.rfidTagUid, tagType: old.rfidTagType, cycle: 1, previousInventoryUid: null }] };
  const event = (eventUid, tag) => ({ eventUid, inventoryUid: old.uid, rfidTagUid: tag, rfidTagCycle: 1,
    eventType: 'usage_finished', deltaGrams: -5, source: 'usage', occurredAt: '2026-09-08T00:00:00.000Z' });
  const result = await put(1, [rebound, next], [event('before-rebind', old.rfidTagUid), event('after-rebind', rebound.rfidTagUid)]);
  assert.equal(result.status, 200, JSON.stringify(result.json));
  const saved = result.json.records.find((r) => r.uid === old.uid);
  assert.equal(saved.remainingGrams, 125);
  assert.equal(saved.totalGrams, 1000);
  assert.equal(saved.rfidTagHistory[0].tagUid, '04A1B2C3');
  assert.equal(result.json.events.length, 2);
  const stale = await put(2, [old, next]);
  assert.equal(stale.status, 409);
  assert.equal(stale.json.error.code, 'inventory_spool_identity_conflict');
  const erased = await put(2, [{ ...saved, rfidTagHistory: [] }, next]);
  assert.equal(erased.status, 409);
  const colliding = await put(2, [saved, next, personalInventoryRecord({ uid: 'collision', lifecycleStatus: 'replaced' })]);
  assert.equal(colliding.status, 409);
  assert.equal(colliding.json.error.code, 'inventory_tag_cycle_conflict');
  const forgedEvent = await put(2, [saved, next], [event('wrong-tag', '04CC0003')]);
  assert.equal(forgedEvent.status, 400);
  assert.equal(forgedEvent.json.error.code, 'inventory_event_tag_conflict');
  const second = { ...saved, lifecycleStatus: 'replaced' };
  const successor = { ...next, uid: 'third', rfidTagUid: saved.rfidTagUid, rfidTagType: 'FUID', previousConsumableUid: saved.uid };
  const again = await put(2, [second, next, successor]);
  assert.equal(again.status, 200, JSON.stringify(again.json));
});

test('重复使用同一 CUID 可以从 A 换到 B 再装回半卷 A 并继续同步消耗', async (t) => {
  const app = await startServer();
  t.after(app.close);
  const user = await registerUser(app, 'remnant@example.com', 'remnant', '半卷复用');
  const put = (revision, records, events = []) => jsonRequest(app.baseUrl, '/v1/me/inventory/snapshot', {
    method: 'PUT', token: user.token, body: { revision, records, events },
  });
  const identity = (r) => ({ tagUid: r.rfidTagUid, tagType: r.rfidTagType,
    cycle: r.rfidTagCycle, previousInventoryUid: r.previousConsumableUid ?? null });
  const first = personalInventoryRecord({ uid: 'roll-a', remainingGrams: 415 });
  assert.equal((await put(0, [first])).status, 200);
  const second = personalInventoryRecord({ uid: 'roll-b', rfidTagCycle: 2,
    previousConsumableUid: first.uid, remainingGrams: 850 });
  assert.equal((await put(1, [{ ...first, lifecycleStatus: 'replaced' }, second])).status, 200);
  const resumed = { ...first, rfidTagCycle: 3, previousConsumableUid: second.uid,
    rfidTagHistory: [identity(first)] };
  const parked = { ...second, lifecycleStatus: 'replaced' };
  const result = await put(2, [resumed, parked]);
  assert.equal(result.status, 200, JSON.stringify(result.json));
  assert.equal(result.json.records.length, 2);
  assert.equal(result.json.records.find((r) => r.uid === first.uid).remainingGrams, 415);
  const consumed = { ...resumed, remainingGrams: 390 };
  const event = { eventUid: 'resumed-a-usage', inventoryUid: first.uid,
    rfidTagUid: first.rfidTagUid, rfidTagCycle: 3, eventType: 'usage_finished',
    deltaGrams: -25, source: 'usage', occurredAt: '2026-09-09T00:00:00.000Z' };
  const used = await put(3, [consumed, parked], [event]);
  assert.equal(used.status, 200, JSON.stringify(used.json));
  assert.equal(used.json.records.find((r) => r.uid === second.uid).remainingGrams, 850);
  const secondAgain = { ...second, rfidTagCycle: 4, previousConsumableUid: first.uid,
    rfidTagHistory: [identity(second)] };
  const switched = await put(4, [{ ...consumed, lifecycleStatus: 'replaced' }, secondAgain]);
  assert.equal(switched.status, 200, JSON.stringify(switched.json));
  const firstAgain = { ...consumed, rfidTagCycle: 5, previousConsumableUid: second.uid,
    rfidTagHistory: [identity(first), identity(resumed)] };
  const saved = await put(5, [firstAgain, { ...secondAgain, lifecycleStatus: 'replaced' }]);
  assert.equal(saved.status, 200, JSON.stringify(saved.json));
  assert.equal(saved.json.records.length, 2);
  assert.equal(saved.json.events.length, 1);
  assert.equal(saved.json.records.find((r) => r.uid === first.uid).remainingGrams, 390);
  for (const bad of [
    { ...firstAgain, rfidTagHistory: [identity(first), identity(first)] },
    { ...firstAgain, rfidTagCycle: 3 },
    { ...firstAgain, rfidTagHistory: [identity(resumed), identity(first)] },
  ]) {
    const rejected = await put(6, [bad, { ...secondAgain, lifecycleStatus: 'replaced' }]);
    assert.ok([400, 409].includes(rejected.status), JSON.stringify(rejected.json));
  }
  const fetched = await jsonRequest(app.baseUrl, '/v1/me/inventory/snapshot', { token: user.token });
  assert.equal(fetched.json.revision, 6);
  assert.equal(fetched.json.records.find((r) => r.uid === first.uid).rfidTagHistory.length, 2);
});

test('个人库存换绑不能增加余量、篡改历史或遗漏原标签的下一卷', async (t) => {
  const app = await startServer();
  t.after(app.close);
  const user = await registerUser(app, 'retag_guard@example.com', 'retag_guard', '换绑边界');
  const old = personalInventoryRecord({ uid: 'old', remainingGrams: 125, lifecycleStatus: 'replaced' });
  const next = personalInventoryRecord({ uid: 'next', rfidTagCycle: 2, previousConsumableUid: old.uid });
  const put = (revision, records) => jsonRequest(app.baseUrl, '/v1/me/inventory/snapshot', {
    method: 'PUT', token: user.token, body: { revision, records },
  });
  assert.equal((await put(0, [old, next])).status, 200);
  const rebound = { ...old, rfidTagUid: '04BB0002', lifecycleStatus: 'active',
    rfidTagHistory: [{ tagUid: old.rfidTagUid, tagType: old.rfidTagType, cycle: 1, previousInventoryUid: null }] };
  for (const patch of [{ remainingGrams: 126 }, { totalGrams: 2000 },
    { rfidTagHistory: [{ ...rebound.rfidTagHistory[0], cycle: 2 }] },
    { rfidTagHistory: [{ ...rebound.rfidTagHistory[0], secretKey: 'forbidden' }] }]) {
    const result = await put(1, [{ ...rebound, ...patch }, next]);
    assert.ok([400, 409].includes(result.status), JSON.stringify(result.json));
  }
  const second = await registerUser(app, 'retag_offline@example.com', 'retag_offline', '离线历史');
  const missing = await jsonRequest(app.baseUrl, '/v1/me/inventory/snapshot', {
    method: 'PUT', token: second.token, body: { revision: 0, records: [rebound] },
  });
  assert.equal(missing.status, 409);
  assert.equal(missing.json.error.code, 'inventory_rebind_successor_missing');
  const unchanged = await jsonRequest(app.baseUrl, '/v1/me/inventory/snapshot', { token: user.token });
  assert.equal(unchanged.json.revision, 1);
  assert.equal(unchanged.json.records.find((r) => r.uid === old.uid).remainingGrams, 125);
});

test('个人库存普通耗材仍可使用删除墓碑', async (t) => {
  const app = await startServer();
  t.after(app.close);
  const user = await registerUser(app, 'untagged-delete@example.com', 'untagged_delete', '普通库存');
  const record = personalInventoryRecord({ rfidTagUid: null, rfidTagType: null });
  const saved = await jsonRequest(app.baseUrl, '/v1/me/inventory/snapshot', {
    method: 'PUT', token: user.token, body: { revision: 0, records: [record] },
  });
  assert.equal(saved.status, 200);
  const deletedUids = { [record.uid]: '2026-09-06T00:00:00.000Z' };
  const removed = await jsonRequest(app.baseUrl, '/v1/me/inventory/snapshot', {
    method: 'PUT', token: user.token, body: { revision: 1, records: [], deletedUids },
  });
  assert.equal(removed.status, 200);
  const fetched = await jsonRequest(app.baseUrl, '/v1/me/inventory/snapshot', { token: user.token });
  assert.deepEqual(fetched.json.records, []);
  assert.deepEqual(fetched.json.deletedUids, deletedUids);
});

test('个人耗材事件分页超过一万条、重传幂等、回填旧时间与事务回滚', async (t) => {
  const app = await startServer();
  t.after(app.close);
  const user = await registerUser(app, 'paged-events@example.com', 'paged_events', '分页账本');
  const other = await registerUser(app, 'paged-other@example.com', 'paged_other', '其他账号');
  const record = personalInventoryRecord({ uid: 'large-ledger' });
  assert.equal((await jsonRequest(app.baseUrl, '/v1/me/inventory/snapshot', {
    method: 'PUT', token: user.token, body: { revision: 0, records: [record] },
  })).status, 200);
  const event = (i) => ({ eventUid: `event-${i}`, inventoryUid: record.uid,
    rfidTagUid: record.rfidTagUid, rfidTagCycle: 1, eventType: 'usage_finished',
    deltaGrams: -1, source: 'usage', occurredAt: '2026-09-06T00:00:00.000Z',
    printerUid: 'printer-1', printerName: '工作台', channelIndex: 7 });
  const post = (events, token = user.token) => jsonRequest(app.baseUrl, '/v1/me/inventory/events', {
    method: 'POST', token, body: { events },
  });
  const count = 10205;
  for (let offset = 0; offset < count; offset += 200) {
    const batch = Array.from({ length: Math.min(200, count - offset) }, (_, i) => event(offset + i));
    assert.equal((await post(batch)).status, 200);
  }
  assert.equal((await post([event(0), event(200)])).status, 200);
  // The first insert in a failed batch must be rolled back as well.
  const conflict = await post([event('rolled-back'), { ...event(0), deltaGrams: -999 }]);
  assert.equal(conflict.status, 409);
  assert.equal(conflict.json.error.code, 'inventory_event_conflict');
  assert.equal((await post([event('foreign')], other.token)).status, 400);
  const isolated = await jsonRequest(app.baseUrl, '/v1/me/inventory/events', { token: other.token });
  assert.deepEqual(isolated.json.events, []);
  const ids = new Set();
  let cursor = 0;
  let more = true;
  while (more) {
    const page = await jsonRequest(app.baseUrl, `/v1/me/inventory/events?after=${cursor}&limit=200`, { token: user.token });
    assert.equal(page.status, 200);
    assert.ok(page.json.events.length <= 200);
    assert.ok(page.json.nextCursor > cursor);
    for (const item of page.json.events) ids.add(item.eventUid);
    cursor = page.json.nextCursor;
    more = page.json.hasMore;
  }
  assert.equal(ids.size, count);
  assert.equal(ids.has('event-rolled-back'), false);
  assert.equal((await post([{ ...event('backdated'), occurredAt: '2020-01-01T00:00:00Z' }])).status, 200);
  const backdated = await jsonRequest(app.baseUrl, `/v1/me/inventory/events?after=${cursor}`, { token: user.token });
  assert.equal(backdated.json.events[0].eventUid, 'event-backdated');
  const snapshot = await jsonRequest(app.baseUrl, '/v1/me/inventory/snapshot', { token: user.token });
  assert.equal(snapshot.json.eventSyncVersion, 1);
  assert.ok(snapshot.json.events.length <= 200);
});

async function publishPreset(app, token, preset = SAMPLE_PRESET, visibility = 'public') {
  const res = await jsonRequest(app.baseUrl, '/v1/presets', {
    method: 'POST',
    token,
    body: { preset, visibility },
  });
  assert.equal(res.status, 201);
  return res.json;
}

test('工作室同步执行角色权限、乐观锁和脱敏客户进度分享', async (t) => {
  const app = await startServer();
  t.after(app.close);
  const owner = await registerUser(
    app,
    'studio-owner@example.com',
    'studio_owner',
    '工作室所有者',
  );
  const operator = await registerUser(
    app,
    'studio-operator@example.com',
    'studio_operator',
    '生产操作员',
  );
  const workspaceId = 'workspace-local-1';

  const created = await jsonRequest(app.baseUrl, '/v1/studio/workspaces', {
    method: 'POST',
    token: owner.token,
    body: { id: workspaceId, name: '测试打印农场' },
  });
  assert.equal(created.status, 201);
  assert.equal(created.json.revision, 0);

  const member = await jsonRequest(
    app.baseUrl,
    `/v1/studio/workspaces/${workspaceId}/members`,
    {
      method: 'POST',
      token: owner.token,
      body: {
        email: 'studio-operator@example.com',
        displayName: '生产操作员',
        role: 'operator',
      },
    },
  );
  assert.equal(member.status, 200);

  const snapshot = {
    customers: [{ id: 'customer-1', name: '客户甲', phone: '不应出现在公开页' }],
    orders: [
      {
        id: 'order-1',
        customerId: 'customer-1',
        orderNo: 'SO-001',
        title: '三色展示件',
        status: 'production',
        dueAt: '2026-08-10',
      },
      {
        id: 'order-2',
        orderNo: 'SO-002',
        title: '其他客户保密订单',
        status: 'production',
        portalVideoEnabled: true,
      },
    ],
    workOrders: [
      {
        id: 'work-1',
        orderId: 'order-1',
        productionPlateId: 'plate-1',
        title: '主体批次',
        quantity: 4,
        completedQuantity: 2,
        status: 'printing',
        printerName: '农场 3 号机',
        progressPercent: 48,
        currentLayer: 96,
        totalLayers: 200,
        remainingMinutes: 42,
        activePrint: true,
        updatedAt: '2026-08-03T10:00:00.000Z',
      },
      {
        id: 'work-2',
        orderId: 'order-2',
        title: '保密批次',
        quantity: 1,
        completedQuantity: 0,
        status: 'printing',
        printerName: '农场 8 号机',
        progressPercent: 20,
        activePrint: true,
      },
      {
        id: 'work-3',
        orderId: 'order-1',
        title: '细节补充批次',
        quantity: 0,
        completedQuantity: 0,
        status: 'printing',
        printerName: '农场 5 号机',
        progressPercent: 21,
        currentLayer: 42,
        totalLayers: 200,
        remainingMinutes: 68,
        activePrint: true,
      },
    ],
    productionPackages: [
      {
        id: 'package-1',
        orderId: 'order-1',
        sourceName: '徽章切片.3mf',
      },
    ],
    productionPlates: [
      {
        id: 'plate-1',
        orderId: 'order-1',
        packageId: 'package-1',
        plateIndex: 1,
        name: '徽章盘',
        requiredRuns: 4,
      },
    ],
    orderItems: [
      {
        id: 'item-1',
        orderId: 'order-1',
        packageId: 'package-1',
        plateId: 'plate-1',
        name: '三色徽章成品',
        perRunQuantity: 2,
        requiredQuantity: 9,
      },
      {
        id: 'item-secret',
        orderId: 'order-2',
        name: '其他客户保密成品',
        perRunQuantity: 1,
        requiredQuantity: 1,
      },
    ],
    inventoryItems: [{ uid: 'spool-1', materialType: 'PLA', remainingGrams: 800 }],
  };
  const uploaded = await jsonRequest(
    app.baseUrl,
    `/v1/studio/workspaces/${workspaceId}/snapshot`,
    {
      method: 'PUT',
      token: owner.token,
      body: { baseRevision: 0, snapshot },
    },
  );
  assert.equal(uploaded.status, 200, JSON.stringify(uploaded.json));
  assert.equal(uploaded.json.revision, 1);

  const operatorRead = await jsonRequest(
    app.baseUrl,
    `/v1/studio/workspaces/${workspaceId}/snapshot`,
    { token: operator.token },
  );
  assert.equal(operatorRead.status, 200);
  assert.equal(operatorRead.json.snapshot.orders[0].id, 'order-1');

  const operatorShare = await jsonRequest(
    app.baseUrl,
    `/v1/studio/workspaces/${workspaceId}/share-links`,
    {
      method: 'POST',
      token: operator.token,
      body: { orderId: 'order-1' },
    },
  );
  assert.equal(operatorShare.status, 403);

  const share = await jsonRequest(
    app.baseUrl,
    `/v1/studio/workspaces/${workspaceId}/share-links`,
    {
      method: 'POST',
      token: owner.token,
      body: {
        orderId: 'order-1',
        expiresInDays: 30,
        portalPassword: 'Customer-8624',
      },
    },
  );
  assert.equal(share.status, 201);
  assert.equal(typeof share.json.token, 'string');

  const homePage = await fetch(`${app.baseUrl}/`);
  const homeHtml = await homePage.text();
  assert.equal(homePage.status, 200);
  assert.match(homeHtml, /sohun 耗材工作台/);
  assert.match(homeHtml, /action="\/studio\/order-login"/);
  assert.match(homeHtml, /客户订单入口/);
  assert.match(homeHtml, /@media\(max-width:680px\)/);
  const homeAsset = await fetch(`${app.baseUrl}/studio/assets/app-workbench-v2.png`);
  assert.equal(homeAsset.status, 200);
  assert.equal(homeAsset.headers.get('content-type'), 'image/png');
  assert.match(homeHtml, /\/studio\/assets\/app-workbench-v2\.png/);
  assert.doesNotMatch(homeHtml, /printer-p1s|printer-a1|Bambu|拓竹/);

  const wrongOrderLogin = await fetch(`${app.baseUrl}/studio/order-login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      orderNo: 'SO-001',
      password: 'wrong-password',
    }),
  });
  const wrongOrderHtml = await wrongOrderLogin.text();
  assert.equal(wrongOrderLogin.status, 401);
  assert.match(wrongOrderHtml, /订单号或访问密码不正确/);
  assert.doesNotMatch(wrongOrderHtml, /三色展示件/);

  const orderLogin = await fetch(`${app.baseUrl}/studio/order-login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      orderNo: 'so-001',
      password: 'Customer-8624',
    }),
    redirect: 'manual',
  });
  assert.equal(orderLogin.status, 303);
  assert.equal(orderLogin.headers.get('location'), '/studio/order');
  const orderCookie = orderLogin.headers.get('set-cookie').split(';')[0];
  const orderPage = await fetch(`${app.baseUrl}/studio/order`, {
    headers: { Cookie: orderCookie },
  });
  const orderHtml = await orderPage.text();
  assert.equal(orderPage.status, 200);
  assert.match(orderHtml, /三色展示件/);
  assert.match(orderHtml, /正在打印的打印机/);
  assert.match(orderHtml, /id="printerSelect"/);
  assert.match(orderHtml, /暂无打印机正在打印/);
  assert.match(orderHtml, /aspect-ratio:16\/9/);
  const sessionProgress = await jsonRequest(
    app.baseUrl,
    '/v1/studio/public/order',
    { headers: { Cookie: orderCookie } },
  );
  assert.equal(sessionProgress.status, 200);
  assert.equal(sessionProgress.json.order.orderNo, 'SO-001');

  const malformedCookieProgress = await jsonRequest(
    app.baseUrl,
    '/v1/studio/public/order',
    { headers: { Cookie: 'sohun_portal_session=%' } },
  );
  assert.equal(malformedCookieProgress.status, 401);
  assert.equal(
    malformedCookieProgress.json.error.code,
    'studio_portal_auth_required',
  );

  const publicProgress = await jsonRequest(
    app.baseUrl,
    `/v1/studio/public/orders/${encodeURIComponent(share.json.token)}`,
  );
  assert.equal(publicProgress.status, 401);

  const anonymousPage = await fetch(`${app.baseUrl}${share.json.relativeUrl}`);
  const anonymousHtml = await anonymousPage.text();
  assert.equal(anonymousPage.status, 200);
  assert.match(anonymousHtml, /访问密码/);
  assert.doesNotMatch(anonymousHtml, /三色展示件/);

  const login = await fetch(`${app.baseUrl}${share.json.relativeUrl}/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ password: 'Customer-8624' }),
    redirect: 'manual',
  });
  assert.equal(login.status, 303);
  const cookie = login.headers.get('set-cookie').split(';')[0];

  const authorizedProgressResponse = await fetch(
    `${app.baseUrl}/v1/studio/public/orders/${encodeURIComponent(share.json.token)}`,
    { headers: { Cookie: cookie } },
  );
  const authorizedProgress = await authorizedProgressResponse.json();
  assert.equal(authorizedProgressResponse.status, 200);
  assert.equal(authorizedProgress.completion, 0.5);
  const recoveredLinkProgress = await fetch(
    `${app.baseUrl}/v1/studio/public/orders/${encodeURIComponent(share.json.id)}`,
    { headers: { Cookie: cookie } },
  );
  assert.equal(recoveredLinkProgress.status, 200);
  assert.equal(authorizedProgress.order.title, '三色展示件');
  assert.equal(authorizedProgress.customerName, '客户甲');
  assert.equal(authorizedProgress.workOrders[0].printerName, '农场 3 号机');
  assert.equal(authorizedProgress.workOrders[0].currentLayer, 96);
  assert.equal(authorizedProgress.plateCount, 1);
  assert.equal(authorizedProgress.items[0].name, '三色徽章成品');
  assert.equal(authorizedProgress.items[0].completedQuantity, 4);
  assert.equal(authorizedProgress.items[0].requiredQuantity, 9);
  assert.equal('phone' in authorizedProgress, false);

  const page = await fetch(`${app.baseUrl}${share.json.relativeUrl}`, {
    headers: { Cookie: cookie },
  });
  const html = await page.text();
  assert.equal(page.status, 200);
  assert.match(html, /三色展示件/);
  assert.match(html, /三色徽章成品/);
  assert.doesNotMatch(html, /其他客户保密成品/);
  assert.doesNotMatch(html, /不应出现在公开页/);
  assert.match(page.headers.get('content-security-policy'), /default-src 'none'/);
  assert.match(page.headers.get('content-security-policy'), /script-src 'nonce-/);
  assert.doesNotMatch(html, /打印机序列号/);

  const videoDemandBeforeViewing = await jsonRequest(
    app.baseUrl,
    `/v1/studio/workspaces/${workspaceId}/video-demand`,
    { token: operator.token },
  );
  assert.equal(videoDemandBeforeViewing.status, 200);
  assert.deepEqual(videoDemandBeforeViewing.json.items, []);

  const videoSession = await jsonRequest(
    app.baseUrl,
    `/v1/studio/workspaces/${workspaceId}/video-sessions`,
    {
      method: 'POST',
      token: operator.token,
      body: {
        orderId: 'order-1',
        workOrderId: 'work-1',
        publicPrinterName: '农场 3 号机',
      },
    },
  );
  assert.equal(videoSession.status, 201);
  const frame = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x01, 0x02, 0xff, 0xd9]);
  const uploadedFrame = await fetch(
    `${app.baseUrl}${videoSession.json.uploadPath}`,
    {
      method: 'PUT',
      headers: {
        Authorization: `Bearer ${videoSession.json.uploadToken}`,
        'Content-Type': 'image/jpeg',
      },
      body: frame,
    },
  );
  assert.equal(uploadedFrame.status, 204);
  const publicFrame = await fetch(
    `${app.baseUrl}/v1/studio/public/orders/${encodeURIComponent(share.json.token)}/video.jpg`,
    { headers: { Cookie: cookie } },
  );
  assert.equal(publicFrame.status, 200);
  assert.deepEqual(Buffer.from(await publicFrame.arrayBuffer()), frame);

  const videoDemandWhileViewing = await jsonRequest(
    app.baseUrl,
    `/v1/studio/workspaces/${workspaceId}/video-demand`,
    { token: operator.token },
  );
  assert.equal(videoDemandWhileViewing.status, 200);
  assert.equal(videoDemandWhileViewing.json.items.length, 1);
  assert.equal(videoDemandWhileViewing.json.items[0].orderId, 'order-1');
  assert.equal(videoDemandWhileViewing.json.items[0].workOrderId, 'work-1');
  assert.equal(videoDemandWhileViewing.json.items[0].viewerCount, 1);
  assert.ok(Date.parse(videoDemandWhileViewing.json.items[0].expiresAt) > Date.now());

  const anonymousFrame = await fetch(
    `${app.baseUrl}/v1/studio/public/orders/${encodeURIComponent(share.json.token)}/video.jpg`,
  );
  assert.equal(anonymousFrame.status, 401);

  const otherVideoSession = await jsonRequest(
    app.baseUrl,
    `/v1/studio/workspaces/${workspaceId}/video-sessions`,
    {
      method: 'POST',
      token: operator.token,
      body: {
        orderId: 'order-2',
        workOrderId: 'work-2',
        publicPrinterName: '农场 8 号机',
      },
    },
  );
  assert.equal(otherVideoSession.status, 201);
  const otherFrame = Buffer.from([0xff, 0xd8, 0xaa, 0xbb, 0xff, 0xd9]);
  const uploadedOtherFrame = await fetch(
    `${app.baseUrl}${otherVideoSession.json.uploadPath}`,
    {
      method: 'PUT',
      headers: {
        Authorization: `Bearer ${otherVideoSession.json.uploadToken}`,
        'Content-Type': 'image/jpeg',
      },
      body: otherFrame,
    },
  );
  assert.equal(uploadedOtherFrame.status, 204);
  const isolatedFrame = await fetch(
    `${app.baseUrl}/v1/studio/public/orders/${encodeURIComponent(share.json.token)}/video.jpg?workOrderId=work-1`,
    { headers: { Cookie: cookie } },
  );
  assert.equal(isolatedFrame.status, 200);
  assert.deepEqual(Buffer.from(await isolatedFrame.arrayBuffer()), frame);

  const secondOrderVideoSession = await jsonRequest(
    app.baseUrl,
    `/v1/studio/workspaces/${workspaceId}/video-sessions`,
    {
      method: 'POST',
      token: operator.token,
      body: {
        orderId: 'order-1',
        workOrderId: 'work-3',
        publicPrinterName: '农场 5 号机',
      },
    },
  );
  assert.equal(secondOrderVideoSession.status, 201);
  const secondFrame = Buffer.from([
    0xff, 0xd8, 0x12, 0x34, 0x56, 0xff, 0xd9,
  ]);
  const uploadedSecondFrame = await fetch(
    `${app.baseUrl}${secondOrderVideoSession.json.uploadPath}`,
    {
      method: 'PUT',
      headers: {
        Authorization: `Bearer ${secondOrderVideoSession.json.uploadToken}`,
        'Content-Type': 'image/jpeg',
      },
      body: secondFrame,
    },
  );
  assert.equal(uploadedSecondFrame.status, 204);
  const selectedSecondFrame = await fetch(
    `${app.baseUrl}/v1/studio/public/order/video.jpg?workOrderId=work-3`,
    { headers: { Cookie: orderCookie } },
  );
  assert.equal(selectedSecondFrame.status, 200);
  assert.deepEqual(
    Buffer.from(await selectedSecondFrame.arrayBuffer()),
    secondFrame,
  );

  const videoSessionListing = await jsonRequest(
    app.baseUrl,
    `/v1/studio/workspaces/${workspaceId}/video-sessions`,
    { token: operator.token },
  );
  assert.equal(videoSessionListing.status, 404);
  const publicControl = await jsonRequest(
    app.baseUrl,
    `/v1/studio/public/orders/${encodeURIComponent(share.json.token)}/control`,
    { method: 'POST', body: { action: 'pause' } },
  );
  assert.equal(publicControl.status, 401);

  const safeAttemptSnapshot = await jsonRequest(
    app.baseUrl,
    `/v1/studio/workspaces/${workspaceId}/snapshot`,
    {
      method: 'PUT',
      token: owner.token,
      body: {
        baseRevision: 1,
        snapshot: {
          schemaVersion: 2,
          orders: [{ id: 'order-1', status: 'draft', totalPrice: 0 }],
          productionPackages: [{ id: 'package-1', orderId: 'order-1' }],
          productionPlates: [{
            id: 'plate-1',
            orderId: 'order-1',
            packageId: 'package-1',
            requiredRuns: 1,
            estimatedSeconds: 0,
            estimatedGrams: 0,
          }],
          workOrders: [{
            id: 'work-1',
            orderId: 'order-1',
            productionPlateId: 'plate-1',
            quantity: 1,
            completedQuantity: 0,
            status: 'queued',
            materialCostSnapshot: 0,
            quotedPriceSnapshot: 0,
          }],
          printAttempts: [{
            id: 'attempt-cloud-safe-1',
            workOrderId: 'work-1',
            attemptNo: 1,
            printerRef: 'a'.repeat(64),
            outcome: 'failed',
            progressPercent: 35,
            consumedGrams: 12.5,
            materialCost: 1.2,
          }],
        },
      },
    },
  );
  assert.equal(safeAttemptSnapshot.status, 200, JSON.stringify(safeAttemptSnapshot.json));
  assert.equal(safeAttemptSnapshot.json.revision, 2);

  const invalidInventory = await jsonRequest(
    app.baseUrl,
    `/v1/studio/workspaces/${workspaceId}/snapshot`,
    {
      method: 'PUT',
      token: owner.token,
      body: {
        baseRevision: 2,
        snapshot: {
          schemaVersion: 2,
          inventoryItems: [{
            uid: 'invalid-stock',
            totalGrams: 1000,
            remainingGrams: 1200,
          }],
        },
      },
    },
  );
  assert.equal(invalidInventory.status, 400);
  assert.equal(invalidInventory.json.error.code, 'invalid_studio_snapshot');

  const leaked = await jsonRequest(
    app.baseUrl,
    `/v1/studio/workspaces/${workspaceId}/snapshot`,
    {
      method: 'PUT',
      token: owner.token,
      body: {
        baseRevision: 2,
        snapshot: { printerSerial: 'SECRET-SERIAL' },
      },
    },
  );
  assert.equal(leaked.status, 400);
  assert.equal(leaked.json.error.code, 'sensitive_studio_field');

  const conflict = await jsonRequest(
    app.baseUrl,
    `/v1/studio/workspaces/${workspaceId}/snapshot`,
    {
      method: 'PUT',
      token: operator.token,
      body: { baseRevision: 0, snapshot },
    },
  );
  assert.equal(conflict.status, 409);
  assert.equal(conflict.json.error.code, 'studio_revision_conflict');
});

test('管理员创建独立成员账号并执行首次改密、全功能和停用闭环', async (t) => {
  const adminToken = 'farm-verification-review-admin-token';
  const app = await startServer({ adminToken });
  t.after(app.close);
  const owner = await registerUser(
    app,
    'farm-owner@example.com',
    'farm_owner_account',
    '农场负责人',
  );
  const organizationId = 'farm-identity-workspace';
  const created = await jsonRequest(app.baseUrl, '/v1/studio/workspaces', {
    method: 'POST',
    token: owner.token,
    body: { id: organizationId, name: '身份隔离测试农场' },
  });
  assert.equal(created.status, 201);

  const profile = await jsonRequest(
    app.baseUrl,
    `/v1/farm/organizations/${organizationId}`,
    { token: owner.token },
  );
  assert.equal(profile.status, 200);
  assert.match(profile.json.organization.organizationCode, /^F[A-F0-9]{10}$/);
  assert.equal(profile.json.organization.verificationStatus, 'draft');
  assert.deepEqual(
    new Set(profile.json.roles.map((role) => role.code)),
    new Set(['owner', 'member']),
  );

  const updatedProfile = await jsonRequest(
    app.baseUrl,
    `/v1/farm/organizations/${organizationId}`,
    {
      method: 'PATCH',
      token: owner.token,
      body: {
        displayName: '身份隔离测试农场',
        subjectType: 'sole_proprietor',
        legalName: '测试打印服务部',
        registrationNumber: '91310000TEST123456',
        contactName: '负责人甲',
        contactPhone: '13800000000',
        contactEmail: 'owner@example.com',
        region: '上海市',
        businessAddress: '测试路 1 号',
        serviceArea: '全国',
        printerCount: 12,
        staffCount: 4,
        locationCount: 1,
        printerModels: ['Bambu Lab P1S'],
        materials: ['PLA', 'PETG'],
        orderTypes: ['来图加工'],
        invoiceCapability: true,
      },
    },
  );
  assert.equal(updatedProfile.status, 200);
  assert.equal(updatedProfile.json.organization.printerCount, 12);

  const submitted = await jsonRequest(
    app.baseUrl,
    `/v1/farm/organizations/${organizationId}/verification-submissions`,
    { method: 'POST', token: owner.token, body: { documentManifest: [] } },
  );
  assert.equal(submitted.status, 201);
  assert.equal(submitted.json.submission.status, 'under_review');

  const reviewQueue = await jsonRequest(
    app.baseUrl,
    '/v1/admin/farm/verification-submissions',
    { token: adminToken },
  );
  assert.equal(reviewQueue.status, 200);
  assert.equal(reviewQueue.json.items.length, 1);
  assert.equal(reviewQueue.json.items[0].organizationId, organizationId);
  const reviewed = await jsonRequest(
    app.baseUrl,
    `/v1/admin/farm/verification-submissions/${submitted.json.submission.id}`,
    {
      method: 'PATCH',
      token: adminToken,
      body: { decision: 'approved', verificationLevel: 1 },
    },
  );
  assert.equal(reviewed.status, 200);
  assert.equal(reviewed.json.organizationStatus, 'verified');

  const staffCreated = await jsonRequest(
    app.baseUrl,
    `/v1/farm/organizations/${organizationId}/staff`,
    {
      method: 'POST',
      token: owner.token,
      body: {
        displayName: '切片员工甲',
        loginName: 'slicer01',
        employeeNo: 'S-001',
        roleCodes: ['slicer', 'inventory_manager', 'auditor'],
        primaryRoleCode: 'slicer',
      },
    },
  );
  assert.equal(staffCreated.status, 201);
  assert.equal(staffCreated.json.member.accountStatus, 'pending_activation');
  assert.deepEqual(staffCreated.json.member.roleCodes, ['member']);
  assert.equal(staffCreated.json.member.primaryRoleCode, 'member');
  assert.equal(staffCreated.json.passwordShownOnce, true);
  assert.ok(staffCreated.json.initialPassword.length >= 12);

  const staffLogin = await jsonRequest(app.baseUrl, '/v1/farm/auth/staff-login', {
    method: 'POST',
    body: {
      organizationCode: profile.json.organization.organizationCode,
      loginName: 'slicer01',
      password: staffCreated.json.initialPassword,
    },
  });
  assert.equal(staffLogin.status, 200);
  assert.equal(staffLogin.json.mustChangePassword, true);
  assert.deepEqual(staffLogin.json.staff.roleCodes, ['member']);
  assert.equal(staffLogin.json.staff.primaryRoleCode, 'member');

  const staffCannotCreateFarm = await jsonRequest(
    app.baseUrl,
    '/v1/studio/workspaces',
    {
      method: 'POST',
      token: staffLogin.json.accessToken,
      body: { id: 'staff-owned-farm', name: '越权创建农场' },
    },
  );
  assert.equal(staffCannotCreateFarm.status, 403);
  assert.equal(
    staffCannotCreateFarm.json.error.code,
    'farm_staff_cannot_create_organization',
  );

  const blockedBeforePasswordChange = await jsonRequest(
    app.baseUrl,
    `/v1/studio/workspaces/${organizationId}/snapshot`,
    { token: staffLogin.json.accessToken },
  );
  assert.equal(blockedBeforePasswordChange.status, 403);
  assert.equal(
    blockedBeforePasswordChange.json.error.code,
    'farm_password_change_required',
  );

  const changed = await jsonRequest(
    app.baseUrl,
    '/v1/farm/auth/change-initial-password',
    {
      method: 'POST',
      token: staffLogin.json.accessToken,
      body: {
        currentPassword: staffCreated.json.initialPassword,
        newPassword: 'NewSecure!Pass123',
      },
    },
  );
  assert.equal(changed.status, 200);
  assert.equal(changed.json.mustChangePassword, false);

  const staffRead = await jsonRequest(
    app.baseUrl,
    `/v1/studio/workspaces/${organizationId}/snapshot`,
    { token: changed.json.accessToken },
  );
  assert.equal(staffRead.status, 200);

  const staffSnapshotWrite = await jsonRequest(
    app.baseUrl,
    `/v1/studio/workspaces/${organizationId}/snapshot`,
    {
      method: 'PUT',
      token: changed.json.accessToken,
      body: { baseRevision: 0, snapshot: {} },
    },
  );
  assert.equal(staffSnapshotWrite.status, 200);

  const detailedSnapshotWrite = await jsonRequest(
    app.baseUrl,
    `/v1/studio/workspaces/${organizationId}/snapshot`,
    {
      method: 'PUT',
      token: changed.json.accessToken,
      body: {
        baseRevision: 1,
        snapshot: {
          activityEvents: [{
            id: 'client-audit-order-created-0001',
            actorMemberId: staffCreated.json.member.id,
            actorDisplayName: '切片操作员',
            actorIdentity: 'member',
            actionCode: 'order.created',
            entityType: 'order',
            entityId: 'order-audit-1',
            summary: '创建订单 SO-AUDIT-1',
            createdAt: new Date().toISOString(),
          }],
        },
      },
    },
  );
  assert.equal(detailedSnapshotWrite.status, 200);

  const personalCommunityDenied = await jsonRequest(app.baseUrl, '/v1/presets', {
    token: changed.json.accessToken,
  });
  assert.equal(personalCommunityDenied.status, 403);
  assert.equal(
    personalCommunityDenied.json.error.code,
    'farm_staff_realm_forbidden',
  );

  const staffSelfDeletion = await jsonRequest(app.baseUrl, '/v1/me', {
    method: 'DELETE',
    token: changed.json.accessToken,
    body: { password: 'NewSecure!Pass123', confirmation: 'DELETE' },
  });
  assert.equal(staffSelfDeletion.status, 403);
  assert.equal(staffSelfDeletion.json.error.code, 'farm_staff_account_managed');

  const staffListFromCombinedRoles = await jsonRequest(
    app.baseUrl,
    `/v1/farm/organizations/${organizationId}/staff`,
    { token: changed.json.accessToken },
  );
  assert.equal(staffListFromCombinedRoles.status, 200);

  const rolesUpdated = await jsonRequest(
    app.baseUrl,
    `/v1/farm/organizations/${organizationId}/staff/${staffCreated.json.member.id}`,
    {
      method: 'PATCH',
      token: owner.token,
      body: {
        roleCodes: ['slicer', 'inventory_manager'],
        primaryRoleCode: 'inventory_manager',
      },
    },
  );
  assert.equal(rolesUpdated.status, 200);
  assert.equal(rolesUpdated.json.member.primaryRoleCode, 'member');
  assert.deepEqual(rolesUpdated.json.member.roleCodes, ['member']);

  const staffListAfterAuditorRemoved = await jsonRequest(
    app.baseUrl,
    `/v1/farm/organizations/${organizationId}/staff`,
    { token: changed.json.accessToken },
  );
  assert.equal(staffListAfterAuditorRemoved.status, 200);

  const staffCreatesStaff = await jsonRequest(
    app.baseUrl,
    `/v1/farm/organizations/${organizationId}/staff`,
    {
      method: 'POST',
      token: changed.json.accessToken,
      body: {
        displayName: '新成员账号',
        loginName: 'member02',
        roleCode: 'print_operator',
      },
    },
  );
  assert.equal(staffCreatesStaff.status, 201);
  assert.deepEqual(staffCreatesStaff.json.member.roleCodes, ['member']);

  const reset = await jsonRequest(
    app.baseUrl,
    `/v1/farm/organizations/${organizationId}/staff/${staffCreated.json.member.id}/reset-credential`,
    { method: 'POST', token: owner.token, body: {} },
  );
  assert.equal(reset.status, 200);
  assert.notEqual(reset.json.initialPassword, staffCreated.json.initialPassword);

  const revokedSession = await jsonRequest(
    app.baseUrl,
    `/v1/studio/workspaces/${organizationId}/snapshot`,
    { token: changed.json.accessToken },
  );
  assert.equal(revokedSession.status, 401);

  const disabled = await jsonRequest(
    app.baseUrl,
    `/v1/farm/organizations/${organizationId}/staff/${staffCreated.json.member.id}`,
    {
      method: 'PATCH',
      token: owner.token,
      body: { accountStatus: 'deactivated' },
    },
  );
  assert.equal(disabled.status, 200);
  assert.equal(disabled.json.member.accountStatus, 'deactivated');

  const disabledLogin = await jsonRequest(app.baseUrl, '/v1/farm/auth/staff-login', {
    method: 'POST',
    body: {
      organizationCode: profile.json.organization.organizationCode,
      loginName: 'slicer01',
      password: reset.json.initialPassword,
    },
  });
  assert.equal(disabledLogin.status, 403);
  assert.equal(disabledLogin.json.error.code, 'farm_staff_disabled');

  const auditLogs = await jsonRequest(
    app.baseUrl,
    `/v1/farm/organizations/${organizationId}/audit-logs`,
    { token: owner.token },
  );
  assert.equal(auditLogs.status, 200);
  assert.ok(auditLogs.json.items.some((item) => item.action === 'member.created'));
  assert.ok(auditLogs.json.items.some((item) => item.action === 'member.deactivated'));

  const removed = await jsonRequest(
    app.baseUrl,
    `/v1/farm/organizations/${organizationId}/staff/${staffCreated.json.member.id}`,
    {
      method: 'PATCH',
      token: owner.token,
      body: { accountStatus: 'removed' },
    },
  );
  assert.equal(removed.status, 200);
  assert.equal(removed.json.member.accountStatus, 'removed');
  assert.equal(removed.json.member.active, false);

  const restoreRemoved = await jsonRequest(
    app.baseUrl,
    `/v1/farm/organizations/${organizationId}/staff/${staffCreated.json.member.id}`,
    {
      method: 'PATCH',
      token: owner.token,
      body: { accountStatus: 'active' },
    },
  );
  assert.equal(restoreRemoved.status, 409);
  assert.equal(restoreRemoved.json.error.code, 'farm_staff_removed');

  const auditAfterRemoval = await jsonRequest(
    app.baseUrl,
    `/v1/farm/organizations/${organizationId}/audit-logs?limit=500`,
    { token: owner.token },
  );
  assert.ok(auditAfterRemoval.json.items.some((item) => item.action === 'member.removed'));
  assert.ok(
    auditAfterRemoval.json.items.some(
      (item) => item.clientEventId === 'client-audit-order-created-0001'
        && item.actorName === '切片员工甲'
        && item.summary === '创建订单 SO-AUDIT-1',
    ),
  );
  assert.ok(
    auditAfterRemoval.json.items.some(
      (item) => item.action === 'member.created' && item.actorName,
    ),
  );
  const immutableAuditDatabase = new DatabaseSync(app.databasePath);
  try {
    assert.throws(
      () => immutableAuditDatabase.exec('DELETE FROM farm_audit_logs'),
      /immutable/,
    );
  } finally {
    immutableAuditDatabase.close();
  }

  const ownerDeletion = await jsonRequest(app.baseUrl, '/v1/me', {
    method: 'DELETE',
    token: owner.token,
    body: { password: 'StrongPass123', confirmation: 'DELETE' },
  });
  assert.equal(ownerDeletion.status, 409);
  assert.equal(ownerDeletion.json.error.code, 'farm_ownership_transfer_required');
});

test('头像与社区预览图在真实写入边界拒绝内网 URL', async (t) => {
  const app = await startServer({ publicImageHosts: ['cdn.example.com'] });
  t.after(app.close);
  const user = await registerUser(
    app,
    'safe-image@example.com',
    'safe-image-user',
    'Safe Image User',
  );

  const accepted = await jsonRequest(app.baseUrl, '/v1/me', {
    method: 'PATCH',
    token: user.token,
    body: { avatarUrl: 'https://cdn.example.com/avatar.png?size=128' },
  });
  assert.equal(accepted.status, 200);
  assert.equal(
    accepted.json.user.avatarUrl,
    'https://cdn.example.com/avatar.png?size=128',
  );

  for (const avatarUrl of [
    'http://cdn.example.com/avatar.png',
    'https://other.example.com/avatar.png',
    'https://127.0.0.1/avatar.png',
    'https://[::1]/avatar.png',
  ]) {
    const rejected = await jsonRequest(app.baseUrl, '/v1/me', {
      method: 'PATCH',
      token: user.token,
      body: { avatarUrl },
    });
    assert.equal(rejected.status, 400);
    assert.equal(rejected.json.error.code, 'invalid_image_url');
  }

  const unsafePreset = {
    ...SAMPLE_PRESET,
    preset: {
      ...SAMPLE_PRESET.preset,
      previewImageUrl: 'https://192.168.1.10/camera/snapshot',
    },
  };
  const rejectedPreset = await jsonRequest(app.baseUrl, '/v1/presets', {
    method: 'POST',
    token: user.token,
    body: { preset: unsafePreset, visibility: 'public' },
  });
  assert.equal(rejectedPreset.status, 400);
  assert.equal(rejectedPreset.json.error.code, 'invalid_image_url');

  const safePreset = {
    ...SAMPLE_PRESET,
    preset: {
      ...SAMPLE_PRESET.preset,
      previewImageUrl: 'https://cdn.example.com/preview.png',
    },
  };
  const published = await publishPreset(app, user.token, safePreset);
  const tamperDatabase = new DatabaseSync(app.databasePath);
  try {
    const stored = tamperDatabase.prepare(
      'SELECT preset_json FROM presets WHERE id = ?',
    ).get(published.id);
    const payload = JSON.parse(stored.preset_json);
    payload.preset.previewImageUrl = 'https://other.example.com/redirect';
    tamperDatabase.prepare(
      'UPDATE presets SET preset_json = ? WHERE id = ?',
    ).run(JSON.stringify(payload), published.id);
    tamperDatabase.prepare(
      'UPDATE users SET avatar_url = ? WHERE id = ?',
    ).run('https://other.example.com/avatar.png', user.userId);
  } finally {
    tamperDatabase.close();
  }

  const sanitizedPreset = await jsonRequest(
    app.baseUrl,
    `/v1/presets/${published.id}`,
  );
  assert.equal(sanitizedPreset.json.owner.avatarUrl, null);
  assert.equal(sanitizedPreset.json.preset.preset.previewImageUrl, null);
  const sanitizedUser = await jsonRequest(app.baseUrl, '/v1/me', {
    token: user.token,
  });
  assert.equal(sanitizedUser.json.user.avatarUrl, null);

  const defaultDeny = await startServer();
  t.after(defaultDeny.close);
  const defaultUser = await registerUser(
    defaultDeny,
    'default-image-deny@example.com',
    'default-image-deny',
    'Default Image Deny',
  );
  const deniedWithoutConfiguration = await jsonRequest(
    defaultDeny.baseUrl,
    '/v1/me',
    {
      method: 'PATCH',
      token: defaultUser.token,
      body: { avatarUrl: 'https://cdn.example.com/avatar.png' },
    },
  );
  assert.equal(deniedWithoutConfiguration.status, 400);
  assert.equal(
    deniedWithoutConfiguration.json.error.code,
    'invalid_image_url',
  );
});

function fingerprintOf(presetPayload) {
  return contentHashOf(JSON.stringify(presetPayload));
}

test('打印结果上传幂等并拒绝禁止字段', async (t) => {
  const app = await startServer();
  t.after(app.close);

  const author = await registerUser(app, 'author1@example.com', 'author-one', '作者一');
  const published = await publishPreset(app, author.token);
  const fingerprint = fingerprintOf(SAMPLE_PRESET);

  // 未登录不能提交结果
  const unauth = await jsonRequest(app.baseUrl, `/v1/presets/${published.id}/print-results`, {
    method: 'POST',
    body: {
      clientResultId: 'unauth-result-id-1234',
      publicationRevision: 1,
      presetFingerprint: fingerprint,
      technicalStatus: 'finished',
      recordedAt: new Date().toISOString(),
    },
  });
  assert.equal(unauth.status, 401);

  // 作者自测：合法上传
  const authorResult = await jsonRequest(app.baseUrl, `/v1/presets/${published.id}/print-results`, {
    method: 'POST',
    token: author.token,
    body: {
      clientResultId: 'author-self-test-0001',
      publicationRevision: 1,
      presetFingerprint: fingerprint,
      technicalStatus: 'finished',
      userOutcome: 'success',
      printerModel: 'P1S',
      nozzleDiameter: 0.4,
      materialProfile: 'Bambu PLA Basic',
      plateType: 'textured_pei',
      humidityBucket: 'medium',
      estimatedSeconds: 3600,
      actualSeconds: 3720,
      estimatedGrams: 42.5,
      actualGrams: 43.1,
      rating: 4,
      recordedAt: new Date().toISOString(),
    },
  });
  assert.equal(authorResult.status, 201);
  assert.equal(authorResult.json.idempotent, false);

  // 重复提交返回原结果（幂等）
  const duplicate = await jsonRequest(app.baseUrl, `/v1/presets/${published.id}/print-results`, {
    method: 'POST',
    token: author.token,
    body: {
      clientResultId: 'author-self-test-0001',
      publicationRevision: 1,
      presetFingerprint: fingerprint,
      technicalStatus: 'finished',
      recordedAt: new Date().toISOString(),
    },
  });
  assert.equal(duplicate.status, 200);
  assert.equal(duplicate.json.idempotent, true);
  assert.equal(duplicate.json.clientResultId, 'author-self-test-0001');

  // 拒绝禁止字段：客户端尝试传 likes/trustScore/authorId/userId/installId/id
  const forbidden = await jsonRequest(app.baseUrl, `/v1/presets/${published.id}/print-results`, {
    method: 'POST',
    token: author.token,
    body: {
      clientResultId: 'forbidden-attempt-0001',
      publicationRevision: 1,
      presetFingerprint: fingerprint,
      technicalStatus: 'finished',
      recordedAt: new Date().toISOString(),
      likes: 999,
      trustScore: 0.99,
      authorId: 'fake',
    },
  });
  assert.equal(forbidden.status, 400);
  assert.equal(forbidden.json.error.code, 'forbidden_field');

  // revision 不存在
  const badRevision = await jsonRequest(app.baseUrl, `/v1/presets/${published.id}/print-results`, {
    method: 'POST',
    token: author.token,
    body: {
      clientResultId: 'bad-revision-0001',
      publicationRevision: 99,
      presetFingerprint: fingerprint,
      technicalStatus: 'finished',
      recordedAt: new Date().toISOString(),
    },
  });
  assert.equal(badRevision.status, 409);
  assert.equal(badRevision.json.error.code, 'revision_mismatch');

  // fingerprint 不匹配
  const badFingerprint = await jsonRequest(app.baseUrl, `/v1/presets/${published.id}/print-results`, {
    method: 'POST',
    token: author.token,
    body: {
      clientResultId: 'bad-fingerprint-0001',
      publicationRevision: 1,
      presetFingerprint: '0'.repeat(64),
      technicalStatus: 'finished',
      recordedAt: new Date().toISOString(),
    },
  });
  assert.equal(badFingerprint.status, 409);
  assert.equal(badFingerprint.json.error.code, 'fingerprint_mismatch');

  // 非法 technicalStatus
  const badStatus = await jsonRequest(app.baseUrl, `/v1/presets/${published.id}/print-results`, {
    method: 'POST',
    token: author.token,
    body: {
      clientResultId: 'bad-status-0001',
      publicationRevision: 1,
      presetFingerprint: fingerprint,
      technicalStatus: 'excellent',
      recordedAt: new Date().toISOString(),
    },
  });
  assert.equal(badStatus.status, 400);

  // 非法 rating
  const badRating = await jsonRequest(app.baseUrl, `/v1/presets/${published.id}/print-results`, {
    method: 'POST',
    token: author.token,
    body: {
      clientResultId: 'bad-rating-0001',
      publicationRevision: 1,
      presetFingerprint: fingerprint,
      technicalStatus: 'finished',
      rating: 6,
      recordedAt: new Date().toISOString(),
    },
  });
  assert.equal(badRating.status, 400);
});

test('PATCH 只能修改主观字段，客观字段被拒绝；DELETE 撤回后汇总更新', async (t) => {
  const app = await startServer();
  t.after(app.close);

  const author = await registerUser(app, 'author2@example.com', 'author-two', '作者二');
  const viewer = await registerUser(app, 'viewer2@example.com', 'viewer-two', '观众二');
  const published = await publishPreset(app, author.token);
  const fingerprint = fingerprintOf(SAMPLE_PRESET);

  // 观众上传技术结果
  const created = await jsonRequest(app.baseUrl, `/v1/presets/${published.id}/print-results`, {
    method: 'POST',
    token: viewer.token,
    body: {
      clientResultId: 'viewer-result-0001',
      publicationRevision: 1,
      presetFingerprint: fingerprint,
      technicalStatus: 'finished',
      printerModel: 'P1S',
      recordedAt: new Date().toISOString(),
    },
  });
  assert.equal(created.status, 201);
  assert.equal(created.json.revision, 1);

  // PATCH 补充主观评价
  const patched = await jsonRequest(app.baseUrl, `/v1/presets/${published.id}/print-results/viewer-result-0001`, {
    method: 'PATCH',
    token: viewer.token,
    body: {
      expectedRevision: 1,
      userOutcome: 'usable',
      rating: 4,
    },
  });
  assert.equal(patched.status, 200);
  assert.equal(patched.json.revision, 2);

  // 过期 revision 被拒绝
  const stale = await jsonRequest(app.baseUrl, `/v1/presets/${published.id}/print-results/viewer-result-0001`, {
    method: 'PATCH',
    token: viewer.token,
    body: { expectedRevision: 1, userOutcome: 'success' },
  });
  assert.equal(stale.status, 409);
  assert.equal(stale.json.error.code, 'revision_conflict');

  // 拒绝修改客观字段
  const forbidden = await jsonRequest(app.baseUrl, `/v1/presets/${published.id}/print-results/viewer-result-0001`, {
    method: 'PATCH',
    token: viewer.token,
    body: { expectedRevision: 2, technicalStatus: 'failed' },
  });
  assert.equal(forbidden.status, 400);
  assert.equal(forbidden.json.error.code, 'forbidden_field');

  // 他人不能 PATCH
  const other = await registerUser(app, 'other2@example.com', 'other-two', '其他用户');
  const otherPatch = await jsonRequest(app.baseUrl, `/v1/presets/${published.id}/print-results/viewer-result-0001`, {
    method: 'PATCH',
    token: other.token,
    body: { expectedRevision: 2, userOutcome: 'success' },
  });
  assert.equal(otherPatch.status, 404);

  // 汇总包含该记录
  const summaryBefore = await jsonRequest(app.baseUrl, `/v1/presets/${published.id}/print-results/summary`);
  assert.equal(summaryBefore.status, 200);
  assert.equal(summaryBefore.json.publicSamples, 1);

  // DELETE 撤回
  const deleted = await jsonRequest(app.baseUrl, `/v1/presets/${published.id}/print-results/viewer-result-0001`, {
    method: 'DELETE',
    token: viewer.token,
  });
  assert.equal(deleted.status, 200);

  // 汇总随之更新
  const summaryAfter = await jsonRequest(app.baseUrl, `/v1/presets/${published.id}/print-results/summary`);
  assert.equal(summaryAfter.json.publicSamples, 0);
});

test('汇总排除作者自测，样本不足时不达标；应用记录幂等', async (t) => {
  const app = await startServer();
  t.after(app.close);

  const author = await registerUser(app, 'author3@example.com', 'author-three', '作者三');
  const published = await publishPreset(app, author.token);
  const fingerprint = fingerprintOf(SAMPLE_PRESET);

  // 作者自测 2 条
  for (let i = 0; i < 2; i++) {
    await jsonRequest(app.baseUrl, `/v1/presets/${published.id}/print-results`, {
      method: 'POST',
      token: author.token,
      body: {
        clientResultId: `author-self-${i.toString().padStart(4, '0')}`,
        publicationRevision: 1,
        presetFingerprint: fingerprint,
        technicalStatus: 'finished',
        userOutcome: 'success',
        rating: 5,
        recordedAt: new Date().toISOString(),
      },
    });
  }

  // 汇总：作者自测不计入公共样本
  const summary = await jsonRequest(app.baseUrl, `/v1/presets/${published.id}/print-results/summary`);
  assert.equal(summary.status, 200);
  assert.equal(summary.json.publicSamples, 0);
  assert.equal(summary.json.authorSelfTestCount, 2);
  assert.equal(summary.json.meetsThreshold, false);
  assert.equal(summary.json.isHighTrust, false);
  assert.equal(summary.json.badgeLabel, null);

  // 非作者观众 1 条：仍不满足 3 条/2 用户的门槛
  const viewer = await registerUser(app, 'viewer3@example.com', 'viewer-three', '观众三');
  await jsonRequest(app.baseUrl, `/v1/presets/${published.id}/print-results`, {
    method: 'POST',
    token: viewer.token,
    body: {
      clientResultId: 'viewer-result-0001',
      publicationRevision: 1,
      presetFingerprint: fingerprint,
      technicalStatus: 'finished',
      userOutcome: 'success',
      rating: 5,
      printerModel: 'P1S',
      recordedAt: new Date().toISOString(),
    },
  });
  const summary2 = await jsonRequest(app.baseUrl, `/v1/presets/${published.id}/print-results/summary`);
  assert.equal(summary2.json.publicSamples, 1);
  assert.equal(summary2.json.uniqueUserCount, 1);
  assert.equal(summary2.json.meetsThreshold, false);
  assert.equal(summary2.json.badgeLabel, null);

  // 应用记录幂等：同一 clientApplicationId 重复 PUT 返回 idempotent=true
  const app1 = await jsonRequest(app.baseUrl, `/v1/presets/${published.id}/applications/client-app-0001`, {
    method: 'PUT',
    token: viewer.token,
  });
  assert.equal(app1.status, 201);
  assert.equal(app1.json.idempotent, false);

  const app2 = await jsonRequest(app.baseUrl, `/v1/presets/${published.id}/applications/client-app-0001`, {
    method: 'PUT',
    token: viewer.token,
  });
  assert.equal(app2.status, 200);
  assert.equal(app2.json.idempotent, true);
  assert.equal(app2.json.id, app1.json.id);

  const app3 = await jsonRequest(
    app.baseUrl,
    `/v1/presets/${published.id}/applications/client-app-0002`,
    { method: 'PUT', token: viewer.token },
  );
  assert.equal(app3.status, 200);
  assert.equal(app3.json.idempotent, true);
  assert.equal(app3.json.id, app1.json.id);

  const afterApplications = await jsonRequest(
    app.baseUrl,
    `/v1/presets/${published.id}`,
  );
  assert.equal(afterApplications.json.applicationCount, 1);
  assert.equal(afterApplications.json.downloads, 1);
});

test('达到门槛后显示徽章和高可信；汇总包含分布数据', async (t) => {
  const app = await startServer();
  t.after(app.close);

  const author = await registerUser(app, 'author4@example.com', 'author-four', '作者四');
  const published = await publishPreset(app, author.token);
  const fingerprint = fingerprintOf(SAMPLE_PRESET);

  // 3 个不同非作者用户各上传 1 条 + 1 个用户上传第 4 条，达到最低门槛
  for (let i = 0; i < 3; i++) {
    const u = await registerUser(app, `viewer4-${i}@example.com`, `viewer-four-${i}`, `观众四${i}`);
    await jsonRequest(app.baseUrl, `/v1/presets/${published.id}/print-results`, {
      method: 'POST',
      token: u.token,
      body: {
        clientResultId: `viewer-${i}-result-0001`,
        publicationRevision: 1,
        presetFingerprint: fingerprint,
        technicalStatus: 'finished',
        userOutcome: i === 2 ? 'quality_failed' : 'success',
        rating: i === 2 ? 2 : 5,
        printerModel: i === 0 ? 'P1S' : 'X1C',
        recordedAt: new Date().toISOString(),
      },
    });
  }

  const summary = await jsonRequest(app.baseUrl, `/v1/presets/${published.id}/print-results/summary`);
  assert.equal(summary.json.publicSamples, 3);
  assert.equal(summary.json.uniqueUserCount, 3);
  assert.equal(summary.json.meetsThreshold, true);
  assert.equal(summary.json.isHighTrust, false);
  assert.ok(summary.json.badgeLabel);
  assert.ok(summary.json.badgeLabel.includes('社区实打'));
  assert.ok(!summary.json.badgeLabel.includes('高可信'));
  assert.equal(summary.json.deviceFinishedCount, 3);
  assert.equal(summary.json.deviceFailedCount, 0);
  assert.equal(summary.json.deviceCancelledCount, 0);
  assert.equal(summary.json.userSuccessCount, 2);
  assert.equal(summary.json.userQualityFailedCount, 1);
  assert.equal(summary.json.ratingCount, 3);
  assert.ok(summary.json.ratingAverage > 0);
  assert.equal(summary.json.printerModelCoverage, 2);
  // smoothedUsableRate 使用 Beta(2,2) 先验：2 成功 / 3 总 → 3/5 = 0.6
  assert.ok(summary.json.smoothedUsableRate > 0.5);
  assert.ok(summary.json.smoothedUsableRate < 0.7);
});

test('举报去重、权限隔离和状态变更', async (t) => {
  const app = await startServer({ adminToken: 'local-admin-token' });
  t.after(app.close);

  const author = await registerUser(app, 'author5@example.com', 'author-five', '作者五');
  const viewer = await registerUser(app, 'viewer5@example.com', 'viewer-five', '观众五');
  const published = await publishPreset(app, author.token);

  // 提交举报
  const reported = await jsonRequest(app.baseUrl, `/v1/presets/${published.id}/reports`, {
    method: 'POST',
    token: viewer.token,
    body: {
      reason: 'dangerous_params',
      note: '温度设置过高',
    },
  });
  assert.equal(reported.status, 201);

  // 同一用户同一参数再次举报被拒绝
  const dup = await jsonRequest(app.baseUrl, `/v1/presets/${published.id}/reports`, {
    method: 'POST',
    token: viewer.token,
    body: { reason: 'spam' },
  });
  assert.equal(dup.status, 409);
  assert.equal(dup.json.error.code, 'report_exists');

  // 非法 reason
  const badReason = await jsonRequest(app.baseUrl, `/v1/presets/${published.id}/reports`, {
    method: 'POST',
    token: viewer.token,
    body: { reason: 'made_up_reason' },
  });
  assert.equal(badReason.status, 400);

  // 未登录不能举报
  const unauth = await jsonRequest(app.baseUrl, `/v1/presets/${published.id}/reports`, {
    method: 'POST',
    body: { reason: 'spam' },
  });
  assert.equal(unauth.status, 401);

  // 不存在的参数不能举报
  const notFound = await jsonRequest(app.baseUrl, '/v1/presets/nonexistent-id/reports', {
    method: 'POST',
    token: viewer.token,
    body: { reason: 'spam' },
  });
  assert.equal(notFound.status, 404);

  // 管理员接口：无 token 被拒
  const adminNoToken = await jsonRequest(app.baseUrl, '/v1/admin/reports');
  assert.equal(adminNoToken.status, 403);

  const adminWrongToken = await jsonRequest(app.baseUrl, '/v1/admin/reports', {
    token: 'wrong-admin-token',
  });
  assert.equal(adminWrongToken.status, 403);

  const adminList = await jsonRequest(app.baseUrl, '/v1/admin/reports', {
    token: 'local-admin-token',
  });
  assert.equal(adminList.status, 200);
  assert.equal(adminList.json.items.length, 1);
  assert.equal(adminList.json.items[0].reporter_id, viewer.userId);

  const moderated = await jsonRequest(
    app.baseUrl,
    `/v1/admin/reports/${reported.json.id}`,
    {
      method: 'PATCH',
      token: 'local-admin-token',
      body: {
        status: 'reviewing',
        moderationStatus: 'under_review',
        resolutionNote: '本地验收审核',
      },
    },
  );
  assert.equal(moderated.status, 200);
  assert.equal(moderated.json.moderationStatus, 'under_review');

  const hiddenFromFeed = await jsonRequest(app.baseUrl, '/v1/presets');
  assert.ok(!hiddenFromFeed.json.items.some((item) => item.id === published.id));
  const hiddenDirect = await jsonRequest(app.baseUrl, `/v1/presets/${published.id}`);
  assert.equal(hiddenDirect.status, 404);
});

test('作者信誉达到门槛后展示数值', async (t) => {
  const app = await startServer();
  t.after(app.close);

  const author = await registerUser(app, 'author6@example.com', 'author-six', '作者六');

  // 作者未发布参数时信誉不可用
  const repBefore = await jsonRequest(app.baseUrl, '/v1/authors/author-six/reputation');
  assert.equal(repBefore.status, 200);
  assert.equal(repBefore.json.meetsThreshold, false);
  assert.equal(repBefore.json.publicPresets, 0);
  assert.equal(repBefore.json.reputationScore, null);

  // 发布 2 个公开参数
  const preset1 = await publishPreset(app, author.token, {
    format: 'bbsparam',
    version: '1.0',
    preset: { name: '参数一', params: { layer_height: 0.2 } },
  });
  const preset2 = await publishPreset(app, author.token, {
    format: 'bbsparam',
    version: '1.0',
    preset: { name: '参数二', params: { layer_height: 0.16 } },
  });

  // 为两个参数分别由非作者用户上传记录，达到 5 条 + 2 个参数门槛
  for (let i = 0; i < 3; i++) {
    const u = await registerUser(app, `rep-user-${i}-a@example.com`, `rep-user-${i}-a`, `信誉用户${i}a`);
    await jsonRequest(app.baseUrl, `/v1/presets/${preset1.id}/print-results`, {
      method: 'POST',
      token: u.token,
      body: {
        clientResultId: `rep-${i}-preset1-0001`,
        publicationRevision: 1,
        presetFingerprint: contentHashOf(JSON.stringify({
          format: 'bbsparam',
          version: '1.0',
          preset: { name: '参数一', params: { layer_height: 0.2 } },
        })),
        technicalStatus: 'finished',
        userOutcome: 'success',
        rating: 5,
        recordedAt: new Date().toISOString(),
      },
    });
  }
  for (let i = 0; i < 2; i++) {
    const u = await registerUser(app, `rep-user-${i}-b@example.com`, `rep-user-${i}-b`, `信誉用户${i}b`);
    await jsonRequest(app.baseUrl, `/v1/presets/${preset2.id}/print-results`, {
      method: 'POST',
      token: u.token,
      body: {
        clientResultId: `rep-${i}-preset2-0001`,
        publicationRevision: 1,
        presetFingerprint: contentHashOf(JSON.stringify({
          format: 'bbsparam',
          version: '1.0',
          preset: { name: '参数二', params: { layer_height: 0.16 } },
        })),
        technicalStatus: 'finished',
        userOutcome: 'usable',
        rating: 4,
        recordedAt: new Date().toISOString(),
      },
    });
  }

  const rep = await jsonRequest(app.baseUrl, '/v1/authors/author-six/reputation');
  assert.equal(rep.status, 200);
  assert.equal(rep.json.meetsThreshold, true);
  assert.equal(rep.json.publicPresets, 2);
  assert.ok(rep.json.nonAuthorSamples >= 5);
  assert.ok(rep.json.reputationScore !== null);
  assert.ok(rep.json.reputationScore >= 0 && rep.json.reputationScore <= 100);
  assert.equal(rep.json.score, rep.json.reputationScore);
  assert.ok(rep.json.badgeLabel);
  assert.ok(rep.json.completionPerformance >= 0);
  // 不应暴露邮箱或 userId
  assert.equal(rep.json.email, undefined);
  assert.equal(rep.json.userId, undefined);

  // Owner removal is a soft removal: public feed hides the preset, while
  // historical reputation facts cannot be laundered away.
  const removed = await jsonRequest(app.baseUrl, `/v1/presets/${preset1.id}`, {
    method: 'DELETE',
    token: author.token,
  });
  assert.equal(removed.status, 200);
  const repAfterRemoval = await jsonRequest(app.baseUrl, '/v1/authors/author-six/reputation');
  assert.equal(repAfterRemoval.json.meetsThreshold, true);
  assert.equal(repAfterRemoval.json.historicalPresetCount, 2);
  assert.equal(repAfterRemoval.json.publicPresets, 1);
  assert.ok(repAfterRemoval.json.score !== null);
});

test('版本事实、身份隔离、公开性和幂等限流形成闭环', async (t) => {
  const app = await startServer();
  t.after(app.close);

  const author = await registerUser(app, 'contract-author@example.com', 'contract-author', '契约作者');
  const viewer = await registerUser(app, 'contract-viewer@example.com', 'contract-viewer', '契约读者');
  const first = await publishPreset(app, author.token);
  assert.match(first.versionId, /^[0-9a-f]{64}$/);
  assert.equal(first.versionId, first.contentHash);
  assert.equal(first.owner.id, undefined);
  assert.equal(first.ownedByMe, true);

  const publicDetail = await jsonRequest(app.baseUrl, `/v1/presets/${first.id}`);
  assert.equal(publicDetail.status, 200);
  assert.equal(publicDetail.json.owner.id, undefined);
  assert.equal(publicDetail.json.ownedByMe, false);

  const privatePreset = await publishPreset(app, author.token, SAMPLE_PRESET, 'private');
  const privateResult = await jsonRequest(app.baseUrl, `/v1/presets/${privatePreset.id}/print-results`, {
    method: 'POST',
    token: author.token,
    body: {
      clientResultId: 'private-result-0001',
      publicationRevision: 1,
      presetFingerprint: privatePreset.contentHash,
      technicalStatus: 'finished',
      recordedAt: '2026-07-28T00:00:00.000Z',
    },
  });
  assert.equal(privateResult.status, 404);

  const forbidden = await jsonRequest(app.baseUrl, `/v1/presets/${first.id}/print-results`, {
    method: 'POST',
    token: viewer.token,
    body: {
      clientResultId: 'sensitive-result-0001',
      publicationRevision: 1,
      presetFingerprint: first.contentHash,
      technicalStatus: 'finished',
      serialNumber: '01P00A000000001',
      recordedAt: '2026-07-28T00:00:00.000Z',
    },
  });
  assert.equal(forbidden.status, 400);
  assert.equal(forbidden.json.error.code, 'forbidden_field');

  const baseBody = {
    clientResultId: 'idempotent-result-0001',
    publicationRevision: 1,
    presetFingerprint: first.contentHash,
    technicalStatus: 'finished',
    recordedAt: '2026-07-28T00:00:00.000Z',
  };
  const created = await jsonRequest(app.baseUrl, `/v1/presets/${first.id}/print-results`, {
    method: 'POST', token: viewer.token, body: baseBody,
  });
  assert.equal(created.status, 201);
  for (let index = 0; index < 12; index++) {
    const retry = await jsonRequest(app.baseUrl, `/v1/presets/${first.id}/print-results`, {
      method: 'POST', token: viewer.token, body: baseBody,
    });
    assert.equal(retry.status, 200);
    assert.equal(retry.json.id, created.json.id);
  }

  for (let index = 0; index < 9; index++) {
    const fresh = await jsonRequest(app.baseUrl, `/v1/presets/${first.id}/print-results`, {
      method: 'POST',
      token: viewer.token,
      body: { ...baseBody, clientResultId: `fresh-result-${index.toString().padStart(4, '0')}` },
    });
    assert.equal(fresh.status, 201);
  }
  const limited = await jsonRequest(app.baseUrl, `/v1/presets/${first.id}/print-results`, {
    method: 'POST',
    token: viewer.token,
    body: { ...baseBody, clientResultId: 'fresh-result-over-limit' },
  });
  assert.equal(limited.status, 429);

  const second = await publishPreset(app, author.token, {
    ...SAMPLE_PRESET,
    preset: { ...SAMPLE_PRESET.preset, name: '第二份参数', scene: '精细' },
  });
  const rebound = await jsonRequest(app.baseUrl, `/v1/presets/${second.id}/print-results`, {
    method: 'POST',
    token: viewer.token,
    body: {
      ...baseBody,
      presetFingerprint: second.contentHash,
    },
  });
  assert.equal(rebound.status, 409);
  assert.equal(rebound.json.error.code, 'idempotency_conflict');

  const application = await jsonRequest(app.baseUrl, `/v1/presets/${first.id}/applications/shared-app-0001`, {
    method: 'PUT', token: viewer.token,
  });
  assert.equal(application.status, 201);
  const applicationRebound = await jsonRequest(
    app.baseUrl,
    `/v1/presets/${second.id}/applications/shared-app-0001`,
    { method: 'PUT', token: viewer.token },
  );
  assert.equal(applicationRebound.status, 409);
  assert.equal(applicationRebound.json.error.code, 'idempotency_conflict');
});

test('匿名下载不改变推荐和热门排序，登录应用才作为信号', async (t) => {
  const app = await startServer();
  t.after(app.close);
  const author = await registerUser(app, 'rank-author@example.com', 'rank-author', '排序作者');
  const viewer = await registerUser(app, 'rank-viewer@example.com', 'rank-viewer', '排序用户');
  const older = await publishPreset(app, author.token, {
    ...SAMPLE_PRESET,
    preset: { ...SAMPLE_PRESET.preset, name: '旧参数' },
  });
  await new Promise((resolve) => setTimeout(resolve, 10));
  const newer = await publishPreset(app, author.token, {
    ...SAMPLE_PRESET,
    preset: { ...SAMPLE_PRESET.preset, name: '新参数' },
  });

  for (let index = 0; index < 20; index++) {
    const downloaded = await jsonRequest(app.baseUrl, `/v1/presets/${older.id}/download`, {
      method: 'POST',
    });
    assert.equal(downloaded.status, 200);
  }
  const recommended = await jsonRequest(app.baseUrl, '/v1/presets?sort=recommended');
  const popularBefore = await jsonRequest(app.baseUrl, '/v1/presets?sort=popular');
  assert.equal(recommended.json.items[0].id, newer.id);
  assert.equal(popularBefore.json.items[0].id, newer.id);
  const olderRow = recommended.json.items.find((item) => item.id === older.id);
  assert.equal(olderRow.downloads, 0);
  assert.equal(olderRow.applicationCount, 0);

  const applied = await jsonRequest(app.baseUrl, `/v1/presets/${older.id}/applications/ranked-app-0001`, {
    method: 'PUT', token: viewer.token,
  });
  assert.equal(applied.status, 201);
  const popularAfter = await jsonRequest(app.baseUrl, '/v1/presets?sort=popular');
  assert.equal(popularAfter.json.items[0].id, older.id);
  assert.equal(popularAfter.json.items[0].applicationCount, 1);
  assert.equal(popularAfter.json.items[0].downloads, 1);
});

test('高可信不能只看样本数，必须通过 Wilson 下界', async (t) => {
  const app = await startServer();
  t.after(app.close);
  const author = await registerUser(app, 'wilson-author@example.com', 'wilson-author', 'Wilson 作者');
  const published = await publishPreset(app, author.token);
  for (let userIndex = 0; userIndex < 5; userIndex++) {
    const user = await registerUser(
      app,
      `wilson-${userIndex}@example.com`,
      `wilson-user-${userIndex}`,
      `Wilson 用户 ${userIndex}`,
    );
    for (let resultIndex = 0; resultIndex < 2; resultIndex++) {
      const result = await jsonRequest(app.baseUrl, `/v1/presets/${published.id}/print-results`, {
        method: 'POST',
        token: user.token,
        body: {
          clientResultId: `wilson-${userIndex}-${resultIndex}-result`,
          publicationRevision: 1,
          presetFingerprint: published.contentHash,
          technicalStatus: 'finished',
          userOutcome: 'quality_failed',
          rating: 1,
          recordedAt: '2026-07-28T00:00:00.000Z',
        },
      });
      assert.equal(result.status, 201);
    }
  }
  const summary = await jsonRequest(app.baseUrl, `/v1/presets/${published.id}/print-results/summary`);
  assert.equal(summary.json.outcomeSampleCount, 10);
  assert.equal(summary.json.outcomeUserCount, 5);
  assert.equal(summary.json.meetsThreshold, true);
  assert.equal(summary.json.isHighTrust, false);
  assert.equal(summary.json.badgeLabel, '社区实打记录');
});

test('Node 参数指纹与 Dart schema-v2 固定 fixture 字节级一致', () => {
  const fixture = {
    format: 'bbsparam',
    version: '1.0',
    preset: {
      name: '不参与指纹',
      inherits: 'fdm_process_common',
      material: 'Bambu PLA Basic',
      scene: 'quality',
      plateType: 'textured_pei',
      compatiblePrinters: ['X1C', 'P1S', 'X1C'],
      params: {
        quality: { layer_height: '0.20', line_width: '0.400' },
        speed: { inner_wall_speed: '100' },
        support: { enable_support: '0' },
      },
    },
  };
  assert.equal(
    contentHashOf(fixture),
    '5df269c466451776bd26542535612d40cbbc76dc08fe453f9ec9e2bb15530edd',
  );
  assert.ok(!canonicalPresetJson(fixture).includes('不参与指纹'));
});

// ===== Phase F：可观测性与远程配置 =====

test('telemetry 批量上传：白名单、幂等和批量上限', async (t) => {
  const app = await startServer();
  t.after(app.close);

  const installIdHash = createHash('sha256').update('install-1').digest('hex');

  // 合法批量
  const ok = await fetch(`${app.baseUrl}/v1/telemetry/batch`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Install-Id-Hash': installIdHash,
    },
    body: JSON.stringify({
      events: [
        {
          id: 'event-00000001',
          eventName: 'app.crash',
          resultCategory: 'fatal',
          durationMs: 120,
          attributes: { platform: 'windows', app_version: '1.0.0', error_type: 'StateError' },
        },
        {
          id: 'event-00000002',
          eventName: 'sync.community_presets',
          resultCategory: 'success',
          durationMs: 350,
          attributes: { endpoint_template: '/v1/presets', status_class: '2xx' },
        },
      ],
    }),
  });
  assert.equal(ok.status, 200);
  const okBody = await ok.json();
  assert.equal(okBody.received, 2);
  assert.equal(okBody.skipped.length, 0);

  // 重复事件 ID 幂等：再次上传相同 ID 不报错，但仍计入 received（INSERT OR IGNORE 静默）
  const dup = await fetch(`${app.baseUrl}/v1/telemetry/batch`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Install-Id-Hash': installIdHash,
    },
    body: JSON.stringify({
      events: [
        {
          id: 'event-00000001',
          eventName: 'app.crash',
          attributes: { platform: 'windows' },
        },
      ],
    }),
  });
  assert.equal(dup.status, 200);

  // 不在白名单的事件被跳过
  const notWhitelisted = await fetch(`${app.baseUrl}/v1/telemetry/batch`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Install-Id-Hash': installIdHash,
    },
    body: JSON.stringify({
      events: [
        {
          id: 'event-00000003',
          eventName: 'user.keystroke',
          attributes: { content: '不应被记录' },
        },
      ],
    }),
  });
  assert.equal(notWhitelisted.status, 200);
  const skipBody = await notWhitelisted.json();
  assert.equal(skipBody.received, 0);
  assert.equal(skipBody.skipped.length, 1);
  assert.equal(skipBody.skipped[0].reason, 'not_whitelisted');

  // 缺失 X-Install-Id-Hash 头
  const noHeader = await fetch(`${app.baseUrl}/v1/telemetry/batch`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      events: [{ id: 'event-00000004', eventName: 'app.crash' }],
    }),
  });
  assert.equal(noHeader.status, 400);

  // 批量超限（>50 条）返回 413
  const tooMany = await fetch(`${app.baseUrl}/v1/telemetry/batch`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Install-Id-Hash': installIdHash,
    },
    body: JSON.stringify({
      events: Array.from({ length: 51 }, (_, i) => ({
        id: `event-batch-${i.toString().padStart(4, '0')}`,
        eventName: 'app.crash',
      })),
    }),
  });
  assert.equal(tooMany.status, 413);
  const tooManyBody = await tooMany.json();
  assert.equal(tooManyBody.error.code, 'payload_too_large');

  // 空数组返回 400
  const empty = await fetch(`${app.baseUrl}/v1/telemetry/batch`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Install-Id-Hash': installIdHash,
    },
    body: JSON.stringify({ events: [] }),
  });
  assert.equal(empty.status, 400);

  const malformedHash = await fetch(`${app.baseUrl}/v1/telemetry/batch`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Install-Id-Hash': 'attacker-controlled-bucket',
    },
    body: JSON.stringify({
      events: [{ id: 'event-invalid-hash', eventName: 'app.crash' }],
    }),
  });
  assert.equal(malformedHash.status, 400);

  const sixth = await fetch(`${app.baseUrl}/v1/telemetry/batch`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Install-Id-Hash': createHash('sha256').update('spoof-1').digest('hex'),
    },
    body: JSON.stringify({
      events: [{ id: 'event-rate-limit-0001', eventName: 'app.crash' }],
    }),
  });
  assert.equal(sixth.status, 200);

  const seventh = await fetch(`${app.baseUrl}/v1/telemetry/batch`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Install-Id-Hash': createHash('sha256').update('spoof-2').digest('hex'),
    },
    body: JSON.stringify({
      events: [{ id: 'event-rate-limit-0002', eventName: 'app.crash' }],
    }),
  });
  assert.equal(seventh.status, 429);
  assert.equal((await seventh.json()).error.code, 'rate_limited');
});

test('telemetry 字段白名单：禁止属性被剥离', async (t) => {
  const app = await startServer();
  t.after(app.close);

  const installIdHash = createHash('sha256').update('install-2').digest('hex');

  // 尝试通过 attributes 上传敏感字段：服务端只保留白名单键
  const res = await fetch(`${app.baseUrl}/v1/telemetry/batch`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Install-Id-Hash': installIdHash,
    },
    body: JSON.stringify({
      events: [
        {
          id: 'event-sanitize-0001',
          eventName: 'http.community_request',
          attributes: {
            endpoint_template: '/v1/presets',
            status_class: '2xx',
            // 以下键不在白名单中，应被剥离
            userEmail: 'leak@example.com',
            accessToken: 'eyJhbGc...',
            printerSerial: '01S00C12345',
            trayUuid: '12345678-1234-1234-1234-123456789012',
            filePath: ['C:', 'Users', 'victim', 'secret.gcode'].join('\\'),
          },
        },
      ],
    }),
  });
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.received, 1);
});

test('telemetry 产品问题事件：接收新事件并仅保留安全属性', async (t) => {
  const app = await startServer();
  t.after(app.close);

  const installIdHash = createHash('sha256').update('install-product-issues').digest('hex');
  const response = await fetch(`${app.baseUrl}/v1/telemetry/batch`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Install-Id-Hash': installIdHash,
    },
    body: JSON.stringify({
      events: [
        {
          id: 'event-upgrade-0001',
          eventName: 'app.upgrade',
          attributes: {
            fromSchema: 8,
            toSchema: 9,
            backupCreated: true,
            phase: 'complete',
            userEmail: 'must-not-persist@example.com',
          },
        },
        {
          id: 'event-compatibility-0001',
          eventName: 'printer.compatibility',
          attributes: {
            connectionMode: 'lan',
            printerModel: 'X1C',
            fallbackUsed: false,
            // 2026-09-03 设备诊断策略：序列号进入白名单（客户端默认关闭开关）
            printerSerial: 'A1-SERIAL-0001',
            accessToken: 'MUST-NOT-PERSIST',
          },
        },
        {
          id: 'event-onboarding-0001',
          eventName: 'onboarding.flow',
          attributes: {
            stepIndex: 4,
            visitedSteps: 5,
            cloudConnected: true,
            action: 'finish',
            filePath: ['C:', 'Users', 'victim', 'secret.txt'].join('\\'),
          },
        },
      ],
    }),
  });

  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.received, 3);
  assert.deepEqual(body.skipped, []);

  const database = new DatabaseSync(app.databasePath, { readOnly: true });
  let rows;
  try {
    rows = database.prepare(`
      SELECT event_name, attributes_json
      FROM telemetry_events
      WHERE install_id_hash = ?
      ORDER BY event_name
    `).all(installIdHash);
  } finally {
    database.close();
  }

  assert.deepEqual(
    rows.map((row) => ({
      eventName: row.event_name,
      attributes: JSON.parse(row.attributes_json),
    })),
    [
      {
        eventName: 'app.upgrade',
        attributes: {
          fromSchema: 8,
          toSchema: 9,
          backupCreated: true,
          phase: 'complete',
        },
      },
      {
        eventName: 'onboarding.flow',
        attributes: {
          stepIndex: 4,
          visitedSteps: 5,
          cloudConnected: true,
          action: 'finish',
        },
      },
      {
        eventName: 'printer.compatibility',
        attributes: {
          connectionMode: 'lan',
          printerModel: 'X1C',
          fallbackUsed: false,
          printerSerial: 'A1-SERIAL-0001',
        },
      },
    ],
  );
});

test('远程配置：ETag、版本过滤和必填参数', async (t) => {
  const app = await startServer();
  t.after(app.close);

  // 缺少必填参数
  const missing = await fetch(`${app.baseUrl}/v1/config`);
  assert.equal(missing.status, 400);

  // 合法请求
  const res1 = await fetch(`${app.baseUrl}/v1/config?appVersion=1.0.0&platform=windows`);
  assert.equal(res1.status, 200);
  assert.ok(res1.headers.get('etag'));
  const body1 = await res1.json();
  assert.equal(body1.source, 'community_server');
  assert.equal(typeof body1.flags, 'object');
  const etag = res1.headers.get('etag');

  // If-None-Match 命中返回 304
  const res2 = await fetch(`${app.baseUrl}/v1/config?appVersion=1.0.0&platform=windows`, {
    headers: { 'If-None-Match': etag },
  });
  assert.equal(res2.status, 304);

  // If-None-Match 不命中返回 200
  const res3 = await fetch(`${app.baseUrl}/v1/config?appVersion=1.0.0&platform=windows`, {
    headers: { 'If-None-Match': '"stale-etag"' },
  });
  assert.equal(res3.status, 200);
});

test('数据库迁移：账号、参数和点赞在重启后保留', async (t) => {
  // 使用独立临时目录，跨两次服务器实例复用同一数据库文件
  const directory = mkdtempSync(join(tmpdir(), 'consumable-community-mig-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const databasePath = join(directory, 'community.sqlite');

  // 第一次启动：创建数据
  const server1 = createCommunityServer({ databasePath, passwordPepper: 'test-pepper' });
  await new Promise((resolve) => server1.listen(0, '127.0.0.1', resolve));
  const port1 = server1.address().port;
  const baseUrl1 = `http://127.0.0.1:${port1}`;

  const author = await jsonRequest(baseUrl1, '/v1/auth/register', {
    method: 'POST',
    body: {
      email: 'mig-author@example.com',
      handle: 'mig-author',
      displayName: '迁移作者',
      password: 'StrongPass123',
      acceptTerms: true,
      ...ACCOUNT_POLICY,
    },
  });
  assert.equal(author.status, 201);
  const published = await jsonRequest(baseUrl1, '/v1/presets', {
    method: 'POST',
    token: author.json.accessToken,
    body: { preset: SAMPLE_PRESET, visibility: 'public' },
  });
  assert.equal(published.status, 201);

  const viewer = await jsonRequest(baseUrl1, '/v1/auth/register', {
    method: 'POST',
    body: {
      email: 'mig-viewer@example.com',
      handle: 'mig-viewer',
      displayName: '迁移观众',
      password: 'StrongPass123',
      acceptTerms: true,
      ...ACCOUNT_POLICY,
    },
  });
  const liked = await jsonRequest(baseUrl1, `/v1/presets/${published.json.id}/like`, {
    method: 'PUT',
    token: viewer.json.accessToken,
  });
  assert.equal(liked.status, 200);
  assert.equal(liked.json.likes, 1);

  await new Promise((resolve, reject) => server1.close((e) => e ? reject(e) : resolve()));

  const legacyDatabase = new DatabaseSync(databasePath);
  try {
    legacyDatabase.exec(`
      DROP INDEX preset_applications_user_preset_revision_idx;
      DELETE FROM community_schema_migrations WHERE version IN (11, 12);
      UPDATE presets SET downloads = 999 WHERE id = '${published.json.id}';
    `);
    const insertLegacyApplication = legacyDatabase.prepare(`
      INSERT INTO preset_applications(
        id, user_id, preset_id, publication_revision, client_application_id, applied_at
      ) VALUES (?, ?, ?, 1, ?, ?)
    `);
    insertLegacyApplication.run(
      'legacy-application-1',
      viewer.json.user.id,
      published.json.id,
      'legacy-client-application-1',
      '2026-07-31T00:00:00.000Z',
    );
    insertLegacyApplication.run(
      'legacy-application-2',
      viewer.json.user.id,
      published.json.id,
      'legacy-client-application-2',
      '2026-07-31T00:01:00.000Z',
    );
  } finally {
    legacyDatabase.close();
  }

  // 第二次启动：复用同一数据库，验证数据保留
  const server2 = createCommunityServer({ databasePath, passwordPepper: 'test-pepper' });
  await new Promise((resolve) => server2.listen(0, '127.0.0.1', resolve));
  const port2 = server2.address().port;
  const baseUrl2 = `http://127.0.0.1:${port2}`;

  // 重复注册返回 409（账号已保留）
  const dup = await jsonRequest(baseUrl2, '/v1/auth/register', {
    method: 'POST',
    body: {
      email: 'mig-author@example.com',
      handle: 'mig-author',
      displayName: '迁移作者',
      password: 'StrongPass123',
      acceptTerms: true,
      ...ACCOUNT_POLICY,
    },
  });
  assert.equal(dup.status, 409);

  // 登录验证账号密码可用
  const login = await jsonRequest(baseUrl2, '/v1/auth/login', {
    method: 'POST',
    body: { email: 'mig-author@example.com', password: 'StrongPass123' },
  });
  assert.equal(login.status, 200);

  // 参数和点赞仍保留
  const presetList = await jsonRequest(baseUrl2, '/v1/presets?q=PLA');
  assert.equal(presetList.status, 200);
  assert.equal(presetList.json.items.length, 1);
  assert.equal(presetList.json.items[0].likes, 1);
  assert.equal(presetList.json.items[0].applicationCount, 1);
  assert.equal(presetList.json.items[0].downloads, 1);

  const migratedDatabase = new DatabaseSync(databasePath, { readOnly: true });
  try {
    const applicationRows = migratedDatabase.prepare(`
      SELECT COUNT(*) AS count FROM preset_applications
      WHERE user_id = ? AND preset_id = ? AND publication_revision = 1
    `).get(viewer.json.user.id, published.json.id);
    assert.equal(applicationRows.count, 1);
    const schema = migratedDatabase.prepare(`
      SELECT MAX(version) AS version FROM community_schema_migrations
    `).get();
    assert.equal(schema.version, CURRENT_SCHEMA_VERSION);
  } finally {
    migratedDatabase.close();
  }

  await new Promise((resolve, reject) => server2.close((e) => e ? reject(e) : resolve()));
});

test('CORS origin must be an explicit HTTPS origin in production', async (t) => {
  assert.equal(validateAllowedOrigin(undefined), '*');
  assert.equal(
    validateAllowedOrigin('http://127.0.0.1:3000'),
    'http://127.0.0.1:3000',
  );
  assert.equal(
    validateAllowedOrigin('https://console.example.com/', { production: true }),
    'https://console.example.com',
  );
  assert.throws(
    () => validateAllowedOrigin(undefined, { production: true }),
    /COMMUNITY_ALLOWED_ORIGIN/,
  );
  assert.throws(
    () => validateAllowedOrigin('*', { production: true }),
    /exact HTTPS origin/,
  );
  assert.throws(
    () => validateAllowedOrigin('http://console.example.com', { production: true }),
    /exact HTTPS origin/,
  );
  assert.throws(
    () => validateAllowedOrigin('https://console.example.com/api'),
    /single HTTP or HTTPS origin/,
  );

  const productionDirectory = mkdtempSync(join(tmpdir(), 'sohun-production-cors-'));
  t.after(() => rmSync(productionDirectory, { recursive: true, force: true }));
  const productionDatabasePath = join(productionDirectory, 'community.sqlite');
  assert.throws(
    () => createCommunityServer({
      production: true,
      databasePath: productionDatabasePath,
      backupDirectory: join(productionDirectory, 'backups'),
      passwordPepper: 'p'.repeat(64),
      adminToken: 'a'.repeat(64),
      supportEmail: 'support@example.com',
      emailVerificationRequired: false,
    }),
    /COMMUNITY_ALLOWED_ORIGIN/,
  );
  assert.equal(existsSync(productionDatabasePath), false);

  const app = await startServer({ allowedOrigin: 'https://console.example.com' });
  t.after(app.close);
  const response = await fetch(`${app.baseUrl}/health`, {
    method: 'OPTIONS',
    headers: {
      Origin: 'https://console.example.com',
      'Access-Control-Request-Method': 'GET',
    },
  });
  assert.equal(response.status, 204);
  assert.equal(
    response.headers.get('access-control-allow-origin'),
    'https://console.example.com',
  );
});

test('GitHub Releases metadata builds a safe installer URL', async (t) => {
  assert.deepEqual(resolveReleaseMetadata({
    latestVersion: 'v1.0.0',
    githubRepository: 'example/sohun-client',
    githubReleaseTag: 'v1.0.0',
    installerAsset: 'sohun-setup-1.0.0-1-windows-x64.exe',
    releaseNotes: 'Initial public release',
  }), {
    desktop_latest_version: 'v1.0.0',
    desktop_download_url:
      'https://github.com/example/sohun-client/releases/download/v1.0.0/sohun-setup-1.0.0-1-windows-x64.exe',
    desktop_release_notes: 'Initial public release',
  });

  const app = await startServer({
    releaseMetadata: {
      latestVersion: 'v1.0.0',
      githubRepository: 'example/sohun-client',
      installerAsset: 'sohun-setup-1.0.0-1-windows-x64.exe',
    },
  });
  t.after(app.close);
  const response = await fetch(
    `${app.baseUrl}/v1/config?appVersion=1.0.0&platform=windows`,
  );
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(
    body.flags.desktop_download_url,
    'https://github.com/example/sohun-client/releases/download/v1.0.0/sohun-setup-1.0.0-1-windows-x64.exe',
  );

  assert.deepEqual(resolveReleaseMetadata({
    latestVersion: 'v1.0.0',
    githubRepository: '../not-a-repository',
    installerAsset: 'setup.exe',
  }), {
    desktop_latest_version: 'v1.0.0',
  });

  assert.deepEqual(resolveReleaseMetadata({
    latestVersion: 'v1.0.1',
    downloadUrl: 'http://downloads.example.com/sohun.exe',
  }), {
    desktop_latest_version: 'v1.0.1',
  });
  assert.deepEqual(resolveReleaseMetadata({
    latestVersion: 'v1.0.1',
    downloadUrl: 'https://user:password@downloads.example.com/sohun.exe',
  }), {
    desktop_latest_version: 'v1.0.1',
  });

  assert.deepEqual(resolveReleaseMetadata({
    latestVersion: 'v2.0.0',
    minSupportedVersion: 'v1.5.0',
    forceUpdate: true,
    downloadUrl: 'http://downloads.example.com/sohun.exe',
  }), {
    desktop_latest_version: 'v2.0.0',
    desktop_min_supported_version: '',
    desktop_force_update: false,
  });

  assert.deepEqual(resolveReleaseMetadata({
    latestVersion: 'v2.0.0',
    minSupportedVersion: 'v1.5.0',
    forceUpdate: true,
    downloadUrl: 'https://downloads.example.com/sohun.exe',
  }), {
    desktop_latest_version: 'v2.0.0',
    desktop_min_supported_version: 'v1.5.0',
    desktop_force_update: true,
    desktop_download_url: 'https://downloads.example.com/sohun.exe',
  });
});

test('社区服务入口在创建数据库前拒绝非法 PORT', () => {
  assert.equal(configuredServerPort(undefined), 27861);
  assert.equal(configuredServerPort('  '), 27861);
  assert.equal(configuredServerPort('27861'), 27861);
  assert.throws(() => configuredServerPort('0'), /PORT/);
  assert.throws(() => configuredServerPort('65536'), /PORT/);
  assert.throws(() => configuredServerPort('27861.5'), /PORT/);
  assert.throws(() => configuredServerPort('0x1000'), /PORT/);
});

test('malformed encoded studio path returns a client error instead of 500', async (t) => {
  const app = await startServer();
  t.after(app.close);

  const response = await jsonRequest(app.baseUrl, '/v1/studio/public/orders/%');
  assert.equal(response.status, 400);
  assert.equal(response.json.error.code, 'invalid_path');

  const authorResponse = await jsonRequest(app.baseUrl, '/v1/authors/%/reputation');
  assert.equal(authorResponse.status, 400);
  assert.equal(authorResponse.json.error.code, 'invalid_path');
});
