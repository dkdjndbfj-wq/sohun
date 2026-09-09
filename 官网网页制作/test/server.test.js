import assert from 'node:assert/strict';
import { createServer, request as httpRequest } from 'node:http';
import test from 'node:test';

import { createWebsiteServer, loadConfiguration } from '../src/server.js';

function listen(server) {
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      const address = server.address();
      resolve(`http://127.0.0.1:${address.port}`);
    });
  });
}

function close(server) {
  return new Promise((resolve, reject) => {
    server.close((error) => error ? reject(error) : resolve());
  });
}

function rawRequest(url, options = {}) {
  return new Promise((resolve, reject) => {
    const request = httpRequest(url, options, (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('end', () => resolve({
        status: response.statusCode,
        headers: response.headers,
        body: Buffer.concat(chunks),
      }));
    });
    request.on('error', reject);
    request.setTimeout(3000, () => request.destroy(new Error('Test request timed out')));
    request.end();
  });
}

test('官网后端地址拒绝嵌入凭据', () => {
  assert.throws(
    () => loadConfiguration({ COMMUNITY_BACKEND_ORIGIN: 'https://user:password@example.com' }),
    /without credentials/,
  );
});

test('畸形请求 URL 返回 400，后续健康检查仍正常', { timeout: 5000 }, async (t) => {
  const site = createWebsiteServer();
  const origin = await listen(site);
  t.after(() => close(site));
  for (const path of ['http://[', '//[']) {
    const rejected = await rawRequest(origin, { path });
    assert.equal(rejected.status, 400);
    assert.match(rejected.headers['cache-control'], /no-store/);
  }
  assert.equal((await rawRequest(`${origin}/health`)).status, 200);
});

test('官网代理不会被 absolute-form 请求重定向到其他主机', async (t) => {
  let safeHits = 0;
  let attackerHits = 0;
  const safeBackend = createServer((request, response) => {
    safeHits += 1;
    response.writeHead(404);
    response.end();
  });
  const attacker = createServer((request, response) => {
    attackerHits += 1;
    response.writeHead(200);
    response.end('attacker');
  });
  const safeUrl = await listen(safeBackend);
  const attackerUrl = await listen(attacker);
  const website = createWebsiteServer({ backendOrigin: safeUrl });
  const websiteUrl = await listen(website);
  t.after(async () => {
    await close(website);
    await close(safeBackend);
    await close(attacker);
  });

  const response = await rawRequest(websiteUrl, {
    path: `${attackerUrl}/v1/studio/public/anything`,
    headers: { Host: 'official.example' },
  });
  assert.equal(response.status, 404);
  assert.equal(safeHits, 1);
  assert.equal(attackerHits, 0);
});

const orderData = {
  workspaceName: '个人工作室',
  customerName: '测试客户',
  completion: 0.5,
  updatedAt: '2026-08-04T00:00:00.000Z',
  order: {
    id: 'order-1',
    orderNo: 'SO-001',
    title: '独立官网测试订单',
    status: 'production',
    dueAt: null,
    note: '',
    videoEnabled: true,
  },
  workOrders: [{
    id: 'work-1',
    title: '第 1 盘',
    status: 'printing',
    activePrint: true,
    printerName: '01 号打印机',
    progressPercent: 50,
    currentLayer: 120,
    totalLayers: 240,
    remainingMinutes: 30,
  }],
  items: [{
    name: '测试成品',
    completedQuantity: 1,
    requiredQuantity: 2,
  }],
};

test('独立官网提供首页、静态资源和健康检查', async (t) => {
  const backend = createServer((request, response) => {
    response.writeHead(404);
    response.end();
  });
  const backendUrl = await listen(backend);
  const website = createWebsiteServer({ backendOrigin: backendUrl });
  const websiteUrl = await listen(website);
  t.after(async () => {
    await close(website);
    await close(backend);
  });

  const home = await fetch(`${websiteUrl}/`);
  const html = await home.text();
  assert.equal(home.status, 200);
  assert.match(html, /sohun 耗材工作台/);
  assert.match(html, /personal-workspace-v4\.png/);
  assert.match(html, /personal-inventory-v4\.png/);
  assert.doesNotMatch(html, /app-workbench-v2\.png|personal-(workspace|inventory)-v3\.png/);
  assert.match(html, /href="\/parameters"/);
  assert.match(html, /href="\/orders"/);
  assert.doesNotMatch(html, /action="\/studio\/order-login"/);

  const orderAccess = await fetch(`${websiteUrl}/orders`);
  const orderHtml = await orderAccess.text();
  assert.equal(orderAccess.status, 200);
  assert.match(orderHtml, /输入订单信息/);
  assert.match(orderHtml, /action="\/studio\/order-login"/);

  for (const filename of [
    'personal-workspace-v4.png', 'personal-inventory-v4.png',
    'personal-workspace-v3.png', 'personal-inventory-v3.png',
  ]) {
    const asset = await fetch(`${websiteUrl}/studio/assets/${filename}`);
    assert.equal(asset.status, 200);
    assert.equal(asset.headers.get('content-type'), 'image/png');
    const png = Buffer.from(await asset.arrayBuffer());
    assert.ok(png.byteLength > 100_000);
    assert.deepEqual(png.subarray(0, 8), Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
    assert.equal(png.toString('ascii', 12, 16), 'IHDR');
    assert.equal(png.readUInt32BE(16), 4080);
    assert.equal(png.readUInt32BE(20), 2700);
  }

  const favicon = await fetch(`${websiteUrl}/favicon.ico`);
  assert.equal(favicon.status, 200);
  assert.equal(favicon.headers.get('content-type'), 'image/x-icon');
  assert.ok((await favicon.arrayBuffer()).byteLength > 100_000);

  const health = await fetch(`${websiteUrl}/health`);
  assert.equal(health.status, 200);
  assert.equal((await health.json()).service, 'sohun-official-website');
});

test('官网下载入口只重定向到显式 HTTPS 安装包地址', async (t) => {
  const backend = createServer((request, response) => {
    response.writeHead(404);
    response.end();
  });
  const backendUrl = await listen(backend);
  const website = createWebsiteServer({
    backendOrigin: backendUrl,
    downloadUrl: 'https://github.com/example/sohun/releases/download/v1.0.0/sohun-setup.exe',
  });
  const websiteUrl = await listen(website);
  t.after(async () => {
    await close(website);
    await close(backend);
  });

  const response = await fetch(`${websiteUrl}/download`, { redirect: 'manual' });
  assert.equal(response.status, 302);
  assert.equal(
    response.headers.get('location'),
    'https://github.com/example/sohun/releases/download/v1.0.0/sohun-setup.exe',
  );
});

test('参数广场仅提供公开参数的只读浏览接口', async (t) => {
  const preset = {
    id: 'preset-1',
    owner: {
      handle: 'maker',
      displayName: '材料玩家',
      avatarUrl: null,
    },
    preset: {
      name: 'PETG 支架参数',
      description: '用于常见桌面支架。',
      material: 'PETG',
      scene: '强度件',
      compatiblePrinters: ['P1S'],
      tags: ['PETG', '支架'],
    },
    likes: 12,
    downloads: 18,
    applicationCount: 18,
    publishedAt: '2026-08-30T00:00:00.000Z',
    updatedAt: '2026-08-30T00:00:00.000Z',
  };
  let listRequest = null;
  let detailCookie = null;
  const backend = createServer((request, response) => {
    const url = new URL(request.url, 'http://localhost');
    if (request.method === 'GET' && url.pathname === '/v1/presets') {
      listRequest = url;
      response.writeHead(200, { 'Content-Type': 'application/json' });
      response.end(JSON.stringify({ items: [preset], nextCursor: null }));
      return;
    }
    if (request.method === 'GET' && url.pathname === '/v1/presets/preset-1') {
      detailCookie = request.headers.cookie ?? null;
      response.writeHead(200, { 'Content-Type': 'application/json' });
      response.end(JSON.stringify(preset));
      return;
    }
    response.writeHead(404);
    response.end();
  });
  const backendUrl = await listen(backend);
  const website = createWebsiteServer({ backendOrigin: backendUrl });
  const websiteUrl = await listen(website);
  t.after(async () => {
    await close(website);
    await close(backend);
  });

  const page = await fetch(`${websiteUrl}/parameters`);
  const pageHtml = await page.text();
  assert.equal(page.status, 200);
  assert.match(pageHtml, /<title>参数广场 · sohun<\/title>/);
  assert.match(pageHtml, /id="presetSearch"/);
  assert.match(pageHtml, /\/api\/presets/);

  const list = await fetch(
    `${websiteUrl}/api/presets?material=PETG&sort=popular&limit=999&ignored=value`,
  );
  assert.equal(list.status, 200);
  assert.deepEqual((await list.json()).items[0].preset.name, 'PETG 支架参数');
  assert.equal(listRequest.searchParams.get('material'), 'PETG');
  assert.equal(listRequest.searchParams.get('sort'), 'popular');
  assert.equal(listRequest.searchParams.get('limit'), '60');
  assert.equal(listRequest.searchParams.has('ignored'), false);

  const detail = await fetch(`${websiteUrl}/api/presets/preset-1`, {
    headers: { Cookie: 'private_session=do-not-forward' },
  });
  assert.equal(detail.status, 200);
  assert.equal((await detail.json()).id, 'preset-1');
  assert.equal(detailCookie, null);

  const write = await fetch(`${websiteUrl}/api/presets`, { method: 'POST' });
  assert.equal(write.status, 404);
});

test('独立官网代理登录并使用本地代码渲染订单页面', async (t) => {
  let forwardedProto = null;
  const backend = createServer((request, response) => {
    const url = new URL(request.url, 'http://localhost');
    if (request.method === 'POST' && url.pathname === '/studio/order-login') {
      forwardedProto = request.headers['x-forwarded-proto'] ?? null;
      let body = '';
      request.setEncoding('utf8');
      request.on('data', (chunk) => { body += chunk; });
      request.on('end', () => {
        if (body.includes('orderNo=BAD')) {
          response.writeHead(401, { 'Content-Type': 'text/html' });
          response.end('invalid');
          return;
        }
        response.writeHead(303, {
          Location: '/studio/order',
          'Set-Cookie': 'sohun_portal_session=test; Path=/; HttpOnly',
        });
        response.end();
      });
      return;
    }
    if (request.method === 'GET'
      && url.pathname === '/v1/studio/public/order') {
      if (!request.headers.cookie?.includes('sohun_portal_session=test')) {
        response.writeHead(401, { 'Content-Type': 'application/json' });
        response.end('{}');
        return;
      }
      response.writeHead(200, { 'Content-Type': 'application/json' });
      response.end(JSON.stringify(orderData));
      return;
    }
    if (request.method === 'GET'
      && url.pathname === '/v1/studio/public/order/video.jpg') {
      response.writeHead(200, { 'Content-Type': 'image/jpeg' });
      response.end(Buffer.from([0xff, 0xd8, 0xff, 0xd9]));
      return;
    }
    response.writeHead(404);
    response.end();
  });
  const backendUrl = await listen(backend);
  const website = createWebsiteServer({ backendOrigin: backendUrl });
  const websiteUrl = await listen(website);
  t.after(async () => {
    await close(website);
    await close(backend);
  });

  const login = await fetch(`${websiteUrl}/studio/order-login`, {
    method: 'POST',
    headers: { 'X-Forwarded-Proto': 'https' },
    body: new URLSearchParams({
      orderNo: 'SO-001',
      password: 'test-password',
    }),
    redirect: 'manual',
  });
  assert.equal(login.status, 303);
  assert.equal(login.headers.get('location'), '/studio/order');
  assert.equal(forwardedProto, 'https');
  const cookie = login.headers.get('set-cookie').split(';')[0];

  const rejected = await fetch(`${websiteUrl}/studio/order-login`, {
    method: 'POST',
    body: new URLSearchParams({ orderNo: 'BAD', password: 'test-password' }),
    redirect: 'manual',
  });
  assert.equal(rejected.status, 303);
  assert.equal(rejected.headers.get('location'), '/orders?error=invalid');

  const page = await fetch(`${websiteUrl}/studio/order`, {
    headers: { Cookie: cookie },
  });
  const html = await page.text();
  assert.equal(page.status, 200);
  assert.match(html, /独立官网测试订单/);
  assert.match(html, /id="printerSelect"/);
  assert.match(html, /aspect-ratio:16\/9/);
  assert.match(html, /cdn\.jsdelivr\.net\/npm\/hls\.js/);
  assert.match(html, /video-playback/);
  assert.doesNotMatch(html, /tcsdk\.com\/player/);

  const frame = await fetch(
    `${websiteUrl}/v1/studio/public/order/video.jpg?workOrderId=work-1`,
    { headers: { Cookie: cookie } },
  );
  assert.equal(frame.status, 200);
  assert.equal(frame.headers.get('content-type'), 'image/jpeg');
  assert.deepEqual(
    Buffer.from(await frame.arrayBuffer()),
    Buffer.from([0xff, 0xd8, 0xff, 0xd9]),
  );
});
