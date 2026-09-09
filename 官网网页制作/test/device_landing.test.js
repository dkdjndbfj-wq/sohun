import assert from 'node:assert/strict';
import { createServer, request as httpRequest } from 'node:http';
import test from 'node:test';

import { renderDeviceLandingPage } from '../src/device_landing.js';
import { createWebsiteServer, loadConfiguration } from '../src/server.js';

const TOKEN = '0123456789abcdef0123456789abcdef';

function listen(server) {
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      resolve(`http://127.0.0.1:${server.address().port}`);
    });
  });
}

function close(server) {
  return new Promise((resolve, reject) => {
    server.close((error) => error ? reject(error) : resolve());
  });
}

function rawRequest(origin, path, method = 'GET') {
  return new Promise((resolve, reject) => {
    const request = httpRequest(origin, { path, method }, (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('end', () => resolve({
        status: response.statusCode,
        headers: response.headers,
        body: Buffer.concat(chunks).toString('utf8'),
      }));
    });
    request.on('error', reject);
    request.end();
  });
}

test('设备落地页只呈现应用入口，不向后端查询设备资料', async (t) => {
  let requests = 0;
  const backend = createServer((request, response) => {
    requests += 1;
    response.end('private-device-access-code');
  });
  const backendOrigin = await listen(backend);
  const website = createWebsiteServer({ backendOrigin, androidDownloadUrl: null });
  const origin = await listen(website);
  t.after(async () => {
    await close(website);
    await close(backend);
  });

  const response = await rawRequest(origin, `/device/${TOKEN}`);
  assert.equal(response.status, 200);
  assert.match(response.body, /打开设备工作台/);
  assert.match(response.body, new RegExp(`href="sohun://device/${TOKEN}"`));
  assert.match(response.body, /应用会核对你是否有权访问这台设备/);
  assert.match(response.body, /Android 安装包正在准备中/);
  assert.doesNotMatch(response.body, /private-device-access-code|<script|href="\/download"|href="\/download\/android"/);
  assert.equal(requests, 0);
  assert.equal(response.headers['cache-control'], 'no-store');
  assert.equal(response.headers['referrer-policy'], 'no-referrer');
  assert.match(response.headers['content-security-policy'], /default-src 'none'/);
  assert.match(response.body, /name="robots" content="noindex,nofollow"/);
});

test('设备入口拒绝非法标识、额外路径、查询及 URL 标准化绕过', async (t) => {
  const website = createWebsiteServer({ androidDownloadUrl: null });
  const origin = await listen(website);
  t.after(() => close(website));
  for (const path of [
    '/device', '/device/', '/device/04AABBCCDDEE11',
    `/device/${TOKEN}/`, `/device/${TOKEN}/extra`, `/device/${TOKEN}?secret=1`,
    `/device/${TOKEN}?`, `/device/${TOKEN}#secret`, `/device/${TOKEN.toUpperCase()}`,
    `/device/%30${TOKEN.slice(1)}`, `/device/ignored/../${TOKEN}`,
    `/device/${TOKEN}%0a`, `https://attacker.invalid/device/${TOKEN}`,
  ]) {
    const response = await rawRequest(origin, path);
    assert.equal(response.status, 404, path);
    assert.doesNotMatch(response.body, /href="sohun:\/\/device\//);
    assert.doesNotMatch(response.body, /secret=1|attacker.invalid/);
  }
  assert.equal((await rawRequest(origin, `/device/${TOKEN}`, 'POST')).status, 405);
});

test('Android 下载配置为空时不跳转 Windows 安装程序', async (t) => {
  const website = createWebsiteServer({
    downloadUrl: 'https://downloads.example/sohun-windows.exe',
    androidDownloadUrl: null,
  });
  const origin = await listen(website);
  t.after(() => close(website));
  const response = await rawRequest(origin, '/download/android');
  assert.equal(response.status, 503);
  assert.match(response.body, /Android 安装包正在准备中/);
  assert.equal(response.headers.location, undefined);
  assert.doesNotMatch(response.body, /sohun-windows\.exe/);
});

test('Android 下载有独立 HTTPS APK 地址且不会携带设备标识', async (t) => {
  const download = 'https://downloads.example/sohun-mobile.apk';
  const website = createWebsiteServer({ androidDownloadUrl: download });
  const origin = await listen(website);
  t.after(() => close(website));
  const page = await rawRequest(origin, `/device/${TOKEN}`);
  assert.equal(page.status, 200);
  assert.match(page.body, /href="\/download\/android"/);
  assert.match(page.body, /下载 Android 版/);
  const response = await rawRequest(origin, '/download/android');
  assert.equal(response.status, 302);
  assert.equal(response.headers.location, download);
  assert.equal(response.headers['referrer-policy'], 'no-referrer');
  assert.equal((await rawRequest(origin, `/download/android?device=${TOKEN}`)).status, 404);
  assert.equal((await rawRequest(origin, '/download/android', 'POST')).status, 404);
});

test('Android 配置拒绝凭据、非 HTTPS、查询及 Windows 包地址', () => {
  assert.equal(loadConfiguration({}).androidDownloadUrl, null);
  const configured = loadConfiguration({
    SOHUN_ANDROID_DOWNLOAD_URL: 'https://downloads.example/sohun.apk',
  });
  assert.equal(configured.androidDownloadUrl.toString(), 'https://downloads.example/sohun.apk');
  for (const value of [
    'https://user:pass@example.com/app.apk', 'http://example.com/app.apk',
    'javascript:alert(1)', 'https://example.com/app.apk?token=secret',
    'https://example.com/app.apk#secret', 'https://example.com/sohun.exe',
    'https://example.com/app.msi', '/sohun.apk',
  ]) {
    assert.throws(() => loadConfiguration({ SOHUN_ANDROID_DOWNLOAD_URL: value }), /SOHUN_ANDROID_DOWNLOAD_URL/);
    assert.throws(() => createWebsiteServer({ androidDownloadUrl: value }), /SOHUN_ANDROID_DOWNLOAD_URL/);
  }
});

test('页面渲染边界拒绝注入与非规范标识', () => {
  for (const value of [null, 123, '<script>alert(1)</script>', `${TOKEN}\n`, TOKEN.toUpperCase()]) {
    assert.throws(() => renderDeviceLandingPage(value), /canonical device token/);
  }
});
