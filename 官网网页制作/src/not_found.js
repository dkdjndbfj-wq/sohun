import { baseTokens, siteHeader, siteFooter, icon, arrowIcon } from './site_theme.js';

const notFoundStyles = `
  .not-found-page{display:flex;flex-direction:column;min-height:100svh}
  .not-found-main{flex:1;display:grid;place-items:center;width:min(960px,calc(100% - 40px));margin:0 auto;padding:56px 0 64px}
  .not-found-content{width:100%;text-align:center}
  .error-code{display:flex;justify-content:center;align-items:center;gap:18px;user-select:none;margin:0 auto 28px}
  .error-digit{font:750 clamp(140px,16vw,210px)/1 system-ui,sans-serif;letter-spacing:-.06em;color:var(--heading-green)}
  .error-spool{position:relative;display:grid;place-items:center;flex:none;width:152px;height:152px;border:1px solid var(--rim);border-radius:50%;background:linear-gradient(145deg,rgba(255,255,255,.82),rgba(255,255,255,.38));box-shadow:0 18px 40px -25px rgba(0,180,42,.26),inset 0 1px 0 #fff;color:var(--heading-green)}
  .error-spool .icon{width:116px;height:116px;stroke-width:1.15}
  .not-found-content h1{font-size:clamp(28px,3.5vw,40px);line-height:1.45;letter-spacing:-1px;color:var(--ink)}
  .not-found-description{max-width:430px;margin:18px auto 0;font-size:14px;line-height:1.9;color:var(--muted)}
  .not-found-actions{display:flex;justify-content:center;flex-wrap:wrap;gap:12px;margin:29px 0 0}
  .not-found-actions a{min-width:150px}
  .not-found-destinations{display:flex;align-items:center;justify-content:center;flex-wrap:wrap;gap:19px;margin:34px auto 0;padding-top:22px;border-top:1px solid var(--line);width:fit-content;font-size:12px;color:var(--muted)}
  .not-found-destinations>a{display:inline-flex;align-items:center;gap:7px;min-height:32px;color:var(--green-dark)}
  .not-found-destinations>a:hover{text-decoration:underline;text-underline-offset:4px}
  .not-found-destinations .icon{width:15px;height:15px}
  @media(max-width:600px){
    .not-found-main{padding:44px 0 48px}
    .error-code{gap:12px;margin-bottom:25px}.error-digit{font-size:144px}
    .error-spool{width:106px;height:106px}.error-spool .icon{width:82px;height:82px}
    .not-found-content h1{font-size:28px;letter-spacing:-.8px}
    .not-found-description{font-size:13px;max-width:310px;padding:0 6px}
    .not-found-actions{margin-top:25px;gap:10px}.not-found-actions a{min-width:0;padding:0 19px;font-size:13px}
    .not-found-destinations{margin-top:28px;gap:12px 17px;font-size:11px;padding-top:18px}
  }
  @media(max-width:360px){
    .error-code{gap:10px}.error-digit{font-size:119px}
    .error-spool{width:88px;height:88px}.error-spool .icon{width:68px;height:68px}
    .not-found-content h1{font-size:25px}.not-found-actions a{padding:0 15px}
  }
`;

export function renderNotFoundPage() {
  return `<!doctype html>
<html lang="zh-CN"><head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="robots" content="noindex">
  <meta name="theme-color" content="#f4f6f5">
  <meta name="description" content="你访问的 sohun 页面不存在。返回首页，或继续查看软件下载、参数广场和订单查询。">
  <link rel="icon" href="/favicon.ico" sizes="any">
  <title>404 · 页面未找到 · sohun</title>
  <style>${baseTokens}${notFoundStyles}</style>
</head><body class="not-found-page">
  ${siteHeader()}
  <main class="not-found-main" id="main-content">
    <section class="not-found-content" aria-labelledby="not-found-title">
      <div class="error-code" aria-hidden="true"><span class="error-digit">4</span><span class="error-spool">${icon('spool')}</span><span class="error-digit">4</span></div>
      <h1 id="not-found-title">这一页，暂时找不到了。</h1>
      <p class="not-found-description">链接可能已失效，或地址输入有误。<br>回到首页，继续寻找你需要的内容。</p>
      <div class="not-found-actions"><a class="primary-link" href="/">返回首页${arrowIcon()}</a><a class="secondary-link" href="/#download">${icon('download')}软件下载</a></div>
      <nav class="not-found-destinations" aria-label="其他常用入口"><span>也可以前往</span><a href="/parameters">${icon('layers')}参数广场</a><a href="/orders">${icon('search')}订单查询</a></nav>
    </section>
  </main>
  ${siteFooter()}
</body></html>`;
}
