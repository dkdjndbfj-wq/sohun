import { randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';
import {
  createServer,
  request as httpRequest,
} from 'node:http';
import { request as httpsRequest } from 'node:https';
import { fileURLToPath } from 'node:url';
import { renderDeviceLandingPage } from './device_landing.js';

import {
  renderHomePage,
  renderMessagePage,
  renderNotFoundPage,
  renderOrderAccessPage,
  renderParameterPlazaPage,
  renderPublicPage,
} from './public_site.js';

const DEFAULT_HOST = '127.0.0.1';
const DEFAULT_PORT = 27870;
const DEFAULT_BACKEND = 'http://127.0.0.1:27861';

const SITE_ASSETS = new Map([
  ['/studio/assets/sohun-logo.webp', {
    bytes: readFileSync(new URL('../public/assets/sohun-logo.webp', import.meta.url)),
    contentType: 'image/webp',
  }],
  ['/studio/assets/sohun.ico', {
    bytes: readFileSync(new URL('../public/assets/sohun.ico', import.meta.url)),
    contentType: 'image/x-icon',
  }],
  ['/studio/assets/sohun-mark.png', {
    bytes: readFileSync(new URL('../public/assets/sohun-mark.png', import.meta.url)),
    contentType: 'image/png',
  }],
  ['/favicon.ico', {
    bytes: readFileSync(new URL('../public/assets/sohun.ico', import.meta.url)),
    contentType: 'image/x-icon',
  }],
  ['/studio/assets/app-workbench-v2.png', {
    bytes: readFileSync(new URL('../public/assets/app-workbench-v2.png', import.meta.url)),
    contentType: 'image/png',
  }],
  ['/studio/assets/personal-workspace-v3.png', {
    bytes: readFileSync(new URL('../public/assets/personal-workspace-v3.png', import.meta.url)),
    contentType: 'image/png',
  }],
  ['/studio/assets/personal-inventory-v3.png', {
    bytes: readFileSync(new URL('../public/assets/personal-inventory-v3.png', import.meta.url)),
    contentType: 'image/png',
  }],
  ['/studio/assets/personal-workspace-v4.png', {
    bytes: readFileSync(new URL('../public/assets/personal-workspace-v4.png', import.meta.url)),
    contentType: 'image/png',
  }],
  ['/studio/assets/personal-inventory-v4.png', {
    bytes: readFileSync(new URL('../public/assets/personal-inventory-v4.png', import.meta.url)),
    contentType: 'image/png',
  }],
]);

function configuredPort(value) {
  const port = Number(value ?? DEFAULT_PORT);
  if (!Number.isInteger(port) || port < 1 || port > 65_535) {
    throw new Error('PORT must be an integer between 1 and 65535');
  }
  return port;
}

function configuredBackend(value) {
  const origin = new URL(value ?? DEFAULT_BACKEND);
  if (!['http:', 'https:'].includes(origin.protocol)) {
    throw new Error('COMMUNITY_BACKEND_ORIGIN must use http or https');
  }
  if (
    origin.username
    || origin.password
    || origin.pathname !== '/'
    || origin.search
    || origin.hash
  ) {
    throw new Error(
      'COMMUNITY_BACKEND_ORIGIN must be an origin without credentials, path, query, or fragment',
    );
  }
  return origin;
}

export function loadConfiguration(env = process.env) {
  return {
    host: env.HOST || DEFAULT_HOST,
    port: configuredPort(env.PORT),
    backendOrigin: configuredBackend(env.COMMUNITY_BACKEND_ORIGIN),
    downloadUrl: configuredDownloadUrl(env.SOHUN_DOWNLOAD_URL),
    androidDownloadUrl: configuredAndroidDownloadUrl(env.SOHUN_ANDROID_DOWNLOAD_URL),
  };
}

function configuredDownloadUrl(value, variableName = 'SOHUN_DOWNLOAD_URL') {
  const raw = String(value ?? '').trim();
  if (!raw) return null;
  let url;
  try {
    url = new URL(raw);
  } catch {
    throw new Error(`${variableName} must be a valid absolute HTTPS URL`);
  }
  if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash) {
    throw new Error(`${variableName} must be an HTTPS URL without credentials, query, or fragment`);
  }
  return url;
}

function configuredAndroidDownloadUrl(value) {
  const url = configuredDownloadUrl(value, 'SOHUN_ANDROID_DOWNLOAD_URL');
  if (url && !url.pathname.toLowerCase().endsWith('.apk')) {
    throw new Error('SOHUN_ANDROID_DOWNLOAD_URL must point to an APK file');
  }
  return url;
}

function securityHeaders(requestId) {
  return {
    'Cache-Control': 'no-store',
    'Referrer-Policy': 'no-referrer',
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY',
    'X-Request-Id': requestId,
  };
}

function sendHtml(response, status, html, requestId, { nonce = null } = {}) {
  const bytes = Buffer.from(html, 'utf8');
  const scriptPolicy = nonce
    ? `; script-src 'nonce-${nonce}' https://cdn.jsdelivr.net; connect-src 'self' https:; media-src https: blob:`
    : '';
  response.writeHead(status, {
    ...securityHeaders(requestId),
    'Content-Type': 'text/html; charset=utf-8',
    'Content-Length': bytes.length,
    'Content-Security-Policy': `default-src 'none'; style-src 'unsafe-inline'; img-src 'self' blob:${scriptPolicy}; base-uri 'none'; form-action 'self'; frame-ancestors 'none'`,
  });
  response.end(bytes);
}

function sendJson(response, status, value, requestId) {
  const bytes = Buffer.from(JSON.stringify(value));
  response.writeHead(status, {
    ...securityHeaders(requestId),
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': bytes.length,
  });
  response.end(bytes);
}

function sendAsset(response, asset, requestId) {
  response.writeHead(200, {
    'Content-Type': asset.contentType,
    'Content-Length': asset.bytes.length,
    'Cache-Control': 'public, max-age=604800, immutable',
    'X-Content-Type-Options': 'nosniff',
    'X-Request-Id': requestId,
  });
  response.end(asset.bytes);
}

function requestProtocol(request) {
  const forwarded = request.headers['x-forwarded-proto'];
  if (typeof forwarded === 'string') {
    const first = forwarded.split(',')[0].trim().toLowerCase();
    if (first === 'https' || first === 'http') return first;
  }
  return request.socket.encrypted ? 'https' : 'http';
}

function proxyHeaders(request, target) {
  const headers = { ...request.headers };
  delete headers.connection;
  delete headers['proxy-authorization'];
  delete headers['proxy-connection'];
  delete headers['x-forwarded-for'];
  delete headers['x-forwarded-host'];
  delete headers['x-forwarded-proto'];
  headers.host = target.host;
  headers['x-forwarded-for'] = request.socket.remoteAddress ?? '127.0.0.1';
  headers['x-forwarded-host'] = request.headers.host ?? '';
  headers['x-forwarded-proto'] = requestProtocol(request);
  return headers;
}

function rewrittenProxyHeaders(headers, backendOrigin) {
  const result = { ...headers };
  const location = result.location;
  if (typeof location === 'string' && location.startsWith(backendOrigin.origin)) {
    const target = new URL(location);
    result.location = `${target.pathname}${target.search}${target.hash}`;
  }
  return result;
}

function proxyRequest(request, response, backendOrigin, requestId) {
  // Rebuild the upstream target from the parsed request path. HTTP clients may
  // send an absolute-form request target; feeding that directly to `new URL`
  // would let a public proxy route to an attacker-selected origin.
  const incoming = new URL(request.url ?? '/', 'http://localhost');
  const target = new URL(`${incoming.pathname}${incoming.search}`, backendOrigin);
  const send = target.protocol === 'https:' ? httpsRequest : httpRequest;
  const orderLogin = request.method === 'POST'
    && target.pathname === '/studio/order-login';
  const upstream = send(target, {
    method: request.method,
    headers: proxyHeaders(request, target),
  }, (upstreamResponse) => {
    if (orderLogin && (upstreamResponse.statusCode ?? 502) >= 400) {
      upstreamResponse.resume();
      response.writeHead(303, {
        ...securityHeaders(requestId),
        Location: '/orders?error=invalid',
      });
      response.end();
      return;
    }
    const headers = rewrittenProxyHeaders(
      upstreamResponse.headers,
      backendOrigin,
    );
    headers['x-request-id'] ??= requestId;
    response.writeHead(upstreamResponse.statusCode ?? 502, headers);
    upstreamResponse.pipe(response);
  });
  upstream.on('error', () => {
    if (response.headersSent) {
      response.destroy();
      return;
    }
    if (orderLogin) {
      response.writeHead(303, {
        ...securityHeaders(requestId),
        Location: '/orders?error=unavailable',
      });
      response.end();
      return;
    }
    sendJson(response, 502, {
      error: {
        code: 'community_backend_unavailable',
        message: '订单服务暂时无法连接，请稍后重试。',
      },
    }, requestId);
  });
  request.pipe(upstream);
}

function publicProxyPath(pathname) {
  return pathname === '/studio/order-login'
    || pathname.startsWith('/studio/share/')
    || pathname.startsWith('/v1/studio/public/');
}

const PUBLIC_PRESET_QUERY_FIELDS = new Map([
  ['q', 120],
  ['material', 80],
  ['scene', 80],
  ['printer', 120],
  ['cursor', 400],
]);
const PUBLIC_PRESET_SORTS = new Set([
  'recommended',
  'newest',
  'popular',
  'mostLiked',
  'name',
]);
const PUBLIC_PRESET_ID = /^[A-Za-z0-9_-]{1,128}$/;

function safeQueryValue(value, maxLength) {
  const normalized = value?.trim() ?? '';
  return normalized.slice(0, maxLength);
}

async function proxyPublicPreset({
  response,
  url,
  backendOrigin,
  requestId,
}) {
  const match = url.pathname.match(/^\/api\/presets(?:\/([^/]+))?$/);
  if (!match) {
    return false;
  }

  const target = new URL('/v1/presets', backendOrigin);
  const encodedId = match[1];
  if (encodedId) {
    let presetId;
    try {
      presetId = decodeURIComponent(encodedId);
    } catch {
      sendJson(response, 404, {
        error: {
          code: 'not_found',
          message: '没有找到该参数。',
        },
      }, requestId);
      return true;
    }
    if (!PUBLIC_PRESET_ID.test(presetId)) {
      sendJson(response, 404, {
        error: {
          code: 'not_found',
          message: '没有找到该参数。',
        },
      }, requestId);
      return true;
    }
    target.pathname = `/v1/presets/${encodeURIComponent(presetId)}`;
  } else {
    for (const [field, maxLength] of PUBLIC_PRESET_QUERY_FIELDS) {
      const value = safeQueryValue(url.searchParams.get(field), maxLength);
      if (value) {
        target.searchParams.set(field, value);
      }
    }
    const sort = url.searchParams.get('sort');
    if (sort && PUBLIC_PRESET_SORTS.has(sort)) {
      target.searchParams.set('sort', sort);
    }
    const requestedLimit = Number(url.searchParams.get('limit'));
    if (Number.isInteger(requestedLimit) && requestedLimit > 0) {
      target.searchParams.set('limit', String(Math.min(requestedLimit, 60)));
    }
  }

  let upstream;
  try {
    upstream = await fetch(target, {
      headers: { Accept: 'application/json' },
      redirect: 'manual',
    });
  } catch {
    sendJson(response, 502, {
      error: {
        code: 'community_backend_unavailable',
        message: '参数广场暂时不可用，请稍后重试。',
      },
    }, requestId);
    return true;
  }

  const bytes = Buffer.from(await upstream.arrayBuffer());
  response.writeHead(upstream.status, {
    ...securityHeaders(requestId),
    'Content-Type': upstream.headers.get('content-type')
      ?? 'application/json; charset=utf-8',
    'Content-Length': bytes.length,
  });
  response.end(bytes);
  return true;
}

async function renderOrderPage({
  request,
  response,
  backendOrigin,
  requestId,
}) {
  const target = new URL('/v1/studio/public/order', backendOrigin);
  let upstream;
  try {
    upstream = await fetch(target, {
      headers: {
        Cookie: request.headers.cookie ?? '',
        'X-Forwarded-For': request.socket.remoteAddress ?? '127.0.0.1',
        'X-Forwarded-Host': request.headers.host ?? '',
        'X-Forwarded-Proto': requestProtocol(request),
      },
      redirect: 'manual',
    });
  } catch {
    sendHtml(response, 502, renderMessagePage(
      '订单服务暂不可用',
      '无法连接订单服务，请稍后重试。',
    ), requestId);
    return;
  }
  if (upstream.status === 401 || upstream.status === 403) {
    response.writeHead(303, {
      ...securityHeaders(requestId),
      Location: '/orders',
    });
    response.end();
    return;
  }
  if (!upstream.ok) {
    sendHtml(response, 502, renderMessagePage(
      '订单读取失败',
      '订单服务暂时无法返回数据，请稍后重试。',
    ), requestId);
    return;
  }
  const data = await upstream.json();
  const nonce = randomBytes(18).toString('base64url');
  sendHtml(
    response,
    200,
    renderPublicPage(data, nonce, {
      videoUrl: '/v1/studio/public/order/video-playback',
      liveVideo: true,
      liveTransport: 'hls',
    }),
    requestId,
    { nonce },
  );
}

export function createWebsiteServer({
  backendOrigin = configuredBackend(),
  downloadUrl = configuredDownloadUrl(process.env.SOHUN_DOWNLOAD_URL),
  androidDownloadUrl = configuredAndroidDownloadUrl(process.env.SOHUN_ANDROID_DOWNLOAD_URL),
} = {}) {
  const normalizedBackend = backendOrigin instanceof URL
    ? backendOrigin
    : configuredBackend(backendOrigin);
  const normalizedAndroidDownload = configuredAndroidDownloadUrl(androidDownloadUrl);
  return createServer(async (request, response) => {
    const requestId = randomBytes(12).toString('hex');
    let url;
    try {
      url = new URL(request.url ?? '/', 'http://localhost');
    } catch {
      sendHtml(response, 400, renderMessagePage(
        '请求地址无效',
        '请从网站首页重新打开所需页面。',
      ), requestId);
      return;
    }
    const pathname = url.pathname;
    try {
      if (pathname === '/device' || pathname.startsWith('/device/')) {
        const match = /^\/device\/([0-9a-f]{32})$/.exec(request.url ?? '');
        if (request.method !== 'GET' || !match || match[0] !== request.url) {
          sendHtml(response, request.method === 'GET' ? 404 : 405, renderMessagePage(
            '设备入口无效',
            '请重新碰一下设备标签，或从应用的设备列表进入。',
          ), requestId);
          return;
        }
        sendHtml(response, 200, renderDeviceLandingPage(match[1], {
          androidDownloadAvailable: normalizedAndroidDownload !== null,
        }), requestId);
        return;
      }
      if (pathname === '/download/android') {
        if (request.method !== 'GET' || request.url !== '/download/android') {
          sendHtml(response, 404, renderMessagePage(
            '下载入口无效',
            '请从官网下载区重新选择 Android 版。',
          ), requestId);
        } else if (normalizedAndroidDownload) {
          response.writeHead(302, {
            ...securityHeaders(requestId),
            Location: normalizedAndroidDownload.toString(),
          });
          response.end();
        } else {
          sendHtml(response, 503, renderMessagePage(
            'Android 安装包正在准备中',
            '请向软件提供方获取 Android 安装包，或稍后再试。',
          ), requestId);
        }
        return;
      }
      if (request.method === 'GET' && SITE_ASSETS.has(pathname)) {
        sendAsset(response, SITE_ASSETS.get(pathname), requestId);
        return;
      }
      if (request.method === 'GET' && pathname === '/') {
        const nonce = randomBytes(18).toString('base64url');
        sendHtml(response, 200, renderHomePage(nonce, {
          windowsDownloadAvailable: Boolean(downloadUrl),
          androidDownloadAvailable: normalizedAndroidDownload !== null,
        }), requestId, { nonce });
        return;
      }
      if (request.method === 'GET' && pathname === '/download') {
        if (downloadUrl) {
          response.writeHead(302, {
            ...securityHeaders(requestId),
            Location: downloadUrl.toString(),
          });
          response.end();
        } else {
          sendHtml(response, 503, renderMessagePage(
            '下载地址尚未配置',
            '管理员正在准备最新 Windows 安装包，请稍后再试。',
          ), requestId);
        }
        return;
      }
      if (request.method === 'GET' && pathname === '/parameters') {
        const nonce = randomBytes(18).toString('base64url');
        sendHtml(
          response,
          200,
          renderParameterPlazaPage(nonce),
          requestId,
          { nonce },
        );
        return;
      }
      if (request.method === 'GET' && pathname === '/orders') {
        const error = url.searchParams.get('error');
        const orderNo = url.searchParams.get('orderNo') ?? '';
        sendHtml(response, 200, renderOrderAccessPage({
          error,
          orderNo,
        }), requestId);
        return;
      }
      if (request.method === 'GET' && pathname === '/health') {
        sendJson(response, 200, {
          ok: true,
          service: 'sohun-official-website',
          backendOrigin: normalizedBackend.origin,
        }, requestId);
        return;
      }
      if (request.method === 'GET' && pathname === '/studio/order') {
        await renderOrderPage({
          request,
          response,
          backendOrigin: normalizedBackend,
          requestId,
        });
        return;
      }
      if (request.method === 'GET'
        && await proxyPublicPreset({
          response,
          url,
          backendOrigin: normalizedBackend,
          requestId,
        })) {
        return;
      }
      if (publicProxyPath(pathname)) {
        proxyRequest(request, response, normalizedBackend, requestId);
        return;
      }
      sendHtml(response, 404, renderNotFoundPage(), requestId);
    } catch (error) {
      console.error(`[${requestId}]`, error);
      if (!response.headersSent) {
        sendHtml(response, 500, renderMessagePage(
          '网站暂时不可用',
          '服务器处理请求时出现错误，请稍后重试。',
        ), requestId);
      } else {
        response.destroy();
      }
    }
  });
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const configuration = loadConfiguration();
  const server = createWebsiteServer({
    backendOrigin: configuration.backendOrigin,
    downloadUrl: configuration.downloadUrl,
    androidDownloadUrl: configuration.androidDownloadUrl,
  });
  server.listen(configuration.port, configuration.host, () => {
    console.log(
      `sohun official website: http://${configuration.host}:${configuration.port}`,
    );
    console.log(`community backend: ${configuration.backendOrigin.origin}`);
  });
}
