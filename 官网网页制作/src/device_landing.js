import { baseTokens, icon, logo } from './site_theme.js';

const DEVICE_TOKEN = /^[0-9a-f]{32}$/;

/** A landing page is not a device lookup and carries no account/device data. */
export function renderDeviceLandingPage(token, { androidDownloadAvailable = false } = {}) {
  if (typeof token !== 'string' || token.length !== 32 || !DEVICE_TOKEN.test(token)) {
    throw new TypeError('A canonical device token is required');
  }
  const download = androidDownloadAvailable
    ? `<a class="secondary-link download" href="/download/android">${icon('download')}下载 Android 版</a>`
    : '<p class="download-pending" role="status">Android 安装包正在准备中，请向软件提供方获取安装包。</p>';
  return `<!doctype html>
<html lang="zh-CN"><head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="robots" content="noindex,nofollow">
  <meta name="referrer" content="no-referrer">
  <link rel="icon" href="/favicon.ico" sizes="any">
  <title>打开设备工作台 · sohun</title>
  <style>${baseTokens}
    body{display:flex;flex-direction:column;min-height:100svh}
    .device-header{display:flex;align-items:center;justify-content:space-between;gap:24px;width:min(960px,calc(100% - 40px));margin:26px auto}
    .device-header>a:last-child{font-size:13px;color:var(--muted)}
    .device-main{flex:1;display:grid;place-items:center;padding:28px 20px 52px}
    .device-card{width:min(100%,480px);padding:40px;border-radius:24px;text-align:center;background:rgba(255,255,255,.8);border:1px solid #fff;box-shadow:0 16px 48px -28px rgba(18,44,27,.2)}
    .device-symbol{display:grid;place-items:center;width:64px;height:64px;margin:0 auto 24px;border-radius:20px;background:var(--green-soft);color:var(--green-dark)}
    .device-symbol .icon{width:32px;height:32px}
    h1{font-size:28px;line-height:1.4;letter-spacing:-.025em;color:var(--ink)}
    .intro{margin-top:12px;color:var(--muted);font-size:15px}
    .open-app{width:100%;margin-top:30px;min-height:52px;font-size:16px}
    .access-note{margin-top:16px;font-size:12px;color:var(--muted);line-height:1.8}
    .install{margin-top:28px;padding-top:25px;border-top:1px solid var(--line)}
    .install h2{font-size:14px;font-weight:550;color:var(--text)}
    .download{width:100%;margin-top:16px;min-height:48px}
    .download-pending{margin-top:12px;font-size:13px;color:var(--muted);line-height:1.8}
    .return-note{margin-top:14px;font-size:12px;color:var(--muted)}
    .device-footer{text-align:center;color:var(--faint);font-size:12px;padding:0 20px 24px}
    @media(max-width:380px){.device-header{margin:20px auto}.device-main{padding:18px 16px 36px}.device-card{padding:30px 22px}h1{font-size:25px}}
  </style>
</head><body>
  <header class="device-header">${logo()}<a href="/">返回官网</a></header>
  <main class="device-main">
    <section class="device-card" aria-labelledby="device-title">
      <div class="device-symbol">${icon('printer')}</div>
      <h1 id="device-title">打开设备工作台</h1>
      <p class="intro">在 sohun 中查看设备状态、故障与保养记录。</p>
      <a class="primary-link open-app" href="sohun://device/${token}">打开 sohun ${icon('arrow')}</a>
      <p class="access-note">登录后，应用会核对你是否有权访问这台设备。<br>网页不会显示设备详情。</p>
      <div class="install">
        <h2>手机还没有安装 sohun？</h2>
        ${download}
        <p class="return-note">安装完成后，回到这里打开应用，或再次碰一下设备标签。</p>
      </div>
    </section>
  </main>
  <footer class="device-footer">sohun · 让每一次现场查看更简单</footer>
</body></html>`;
}
