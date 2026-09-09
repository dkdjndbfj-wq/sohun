import assert from 'node:assert/strict';
import test from 'node:test';
import { createWebsiteServer } from '../src/server.js';

async function serve(t) {
  const server = createWebsiteServer({ downloadUrl: null, androidDownloadUrl: null });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  return `http://127.0.0.1:${server.address().port}`;
}

test('不存在的页面返回自定义 404，提供根路径导航并禁止索引', async t => {
  const origin = await serve(t);
  for (const pathname of ['/404', '/missing/nested/page?private=do-not-reflect', '/studio/assets/missing-image.png']) {
    const response = await fetch(origin + pathname, { redirect: 'manual' });
    const html = await response.text();
    assert.equal(response.status, 404);
    assert.equal(response.headers.get('location'), null);
    assert.match(response.headers.get('content-type'), /text\/html/);
    assert.match(html, /<title>404 · 页面未找到 · sohun<\/title>/);
    assert.match(html, /<meta name="robots" content="noindex">/);
    assert.match(html, /href="\/">返回首页/);
    assert.match(html, /href="\/#download"/);
    assert.match(html, /href="\/parameters"/);
    assert.match(html, /href="\/orders"/);
    assert.doesNotMatch(html, /do-not-reflect|<script|http-equiv="refresh"/);
  }
});

test('自定义 404 不覆盖正常页面及安装包准备中状态', async t => {
  const origin = await serve(t);
  for (const [pathname, expectedStatus] of [['/', 200], ['/orders', 200], ['/download', 503], ['/download/android', 503]]) {
    const response = await fetch(origin + pathname);
    assert.equal(response.status, expectedStatus);
    assert.doesNotMatch(await response.text(), /<title>404 · 页面未找到/);
  }
});
