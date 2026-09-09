import assert from 'node:assert/strict';
import test from 'node:test';
import { createWebsiteServer } from '../src/server.js';
import { detectDownloadPlatform } from '../src/download_section.js';

async function serve(t, options) {
  const server = createWebsiteServer(options);
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  return `http://127.0.0.1:${server.address().port}`;
}

test('按系统推荐安装包，触屏 Windows 不会被当作手机，桌面模式 iPad 不会推荐 EXE', () => {
  const cases = [
    [{ userAgent: 'Mozilla/5.0 (Linux; Android 14; Pixel 8)', platform: 'Linux armv8l' }, 'android'],
    [{ userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)', platform: 'iPhone' }, 'ios'],
    [{ userAgent: 'Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X)' }, 'ios'],
    [{ userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15)', platform: 'MacIntel', maxTouchPoints: 5 }, 'ios'],
    [{ userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)', platform: 'Win32', maxTouchPoints: 10 }, 'windows'],
    [{ userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15)', platform: 'MacIntel', maxTouchPoints: 0 }, 'unknown'],
    [{ userAgent: 'Mozilla/5.0 (X11; Linux x86_64)', platform: 'Linux x86_64' }, 'unknown'],
    [{}, 'unknown'],
  ];
  for (const [device, expected] of cases) assert.equal(detectDownloadPlatform(device), expected);
});

test('首页按两个安装包各自的配置显示下载按钮，无脚本也能选平台', async t => {
  for (const windows of [false, true]) {
    for (const android of [false, true]) {
      await t.test(`Windows=${windows}, Android=${android}`, async t => {
        const origin = await serve(t, {
          downloadUrl: windows ? 'https://downloads.example/sohun.exe' : null,
          androidDownloadUrl: android ? 'https://downloads.example/sohun.apk' : null,
        });
        const response = await fetch(origin);
        const html = await response.text();
        assert.equal(response.status, 200);
        assert.match(html, /选择下载版本/);
        assert.match(html, /Windows · EXE 安装包/);
        assert.match(html, /Android · APK 安装包/);
        assert.equal(html.includes('href="/download"'), windows);
        assert.equal(html.includes('href="/download/android"'), android);
        assert.equal(html.includes('Windows 安装包正在准备中'), !windows);
        assert.equal(html.includes('Android 安装包正在准备中'), !android);
        assert.match(html, /暂未提供 iOS \/ iPadOS 安装包/);
        assert.doesNotMatch(html, /href="https:\/\/downloads\.example/);
      });
    }
  }
});

test('安装包未就绪时返回平台对应提示，可回到下载区', async t => {
  const origin = await serve(t, { downloadUrl: null, androidDownloadUrl: null });
  for (const [route, name] of [['/download', 'Windows'], ['/download/android', 'Android']]) {
    const response = await fetch(origin + route);
    const html = await response.text();
    assert.equal(response.status, 503);
    assert.ok(html.includes(`<h1>${name} 安装包正在准备中</h1>`));
    assert.match(html, /href="\/#download">返回下载区/);
    assert.doesNotMatch(html, /返回订单入口|href="\/download"/);
  }
});
