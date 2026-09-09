// Colors follow ThemeColorDef.auroraGreen and Aurora.applyTheme(light).
// Text accent follows personalDesktopAccentText. Action surfaces follow the
// client's glass buttons; screenshots keep their original pixels.

// Keep geometry with each component. This shared surface covers both native
// buttons and link CTAs, including states generated after the page has loaded.
export function glassButtonStyles(selector, { primarySelector = '' } = {}) {
  const target = `:is(${selector})`;
  const enabled = `${target}:not(:disabled):not([aria-disabled="true"])`;
  return `
    ${target}{
      --button-fill:var(--glass-button-secondary);--button-hover-fill:var(--glass-button-secondary-hover);--button-ink:var(--text);
      appearance:none;border:1px solid var(--glass-button-rim);background:var(--button-fill);color:var(--button-ink);
      box-shadow:var(--glass-button-shadow);backdrop-filter:blur(14px);-webkit-backdrop-filter:blur(14px);
      transition:background .18s ease,border-color .18s ease,box-shadow .18s ease,transform .18s ease;
    }
    ${primarySelector ? `${target}:where(${primarySelector}){--button-fill:var(--glass-button-primary);--button-hover-fill:var(--glass-button-primary-hover);--button-ink:var(--glass-button-accent)}` : ''}
    @media(hover:hover){${enabled}:hover{background:var(--button-hover-fill);box-shadow:var(--glass-button-hover-shadow);transform:translateY(-1px)}}
    ${enabled}:active{background:var(--button-hover-fill);box-shadow:var(--glass-button-pressed-shadow);transform:scale(.98)}
    ${target}:focus-visible{outline:3px solid var(--green-dark);outline-offset:3px}
    ${target}:is(:disabled,[aria-disabled="true"]){background:var(--glass-button-disabled);color:var(--glass-button-disabled-ink);border-color:var(--glass-button-rim);box-shadow:inset 0 1px 0 rgba(255,255,255,.55);transform:none;cursor:not-allowed}
    @media(prefers-reduced-motion:reduce){${target}{transition:none}${enabled}:hover,${enabled}:active{transform:none}}
    @media(forced-colors:active){${target},${enabled}:hover,${enabled}:active{background:ButtonFace;color:ButtonText;border-color:ButtonText;box-shadow:none;backdrop-filter:none;-webkit-backdrop-filter:none}${target}:is(:disabled,[aria-disabled="true"]){background:ButtonFace;color:GrayText;border-color:GrayText}${target}:is([aria-selected="true"],[aria-pressed="true"]){outline:2px solid Highlight;outline-offset:2px}}
  `;
}

export const baseTokens = `
  :root {
    color-scheme:light;
    font-family:"HarmonyOS Sans","Microsoft YaHei UI","PingFang SC",system-ui,sans-serif;
    --canvas:#f4f6f5; --ink:#121614; --text:#1f2923; --muted:#5b665f; --faint:#68736c;
    --green:#00b42a; --green-dark:#006c19; --green-soft:rgba(0,180,42,.10);
    --heading-green:#009a24;
    --surface:rgba(255,255,255,.60); --soft:#f8f9fa; --line:#e9ecef;
    --rim:rgba(255,255,255,.70); --danger:#b42318; --danger-soft:#fff1f0;
    --shadow:0 12px 36px -22px rgba(18,22,20,.16),inset 0 1px 0 rgba(255,255,255,.7);
    --glass-button-accent:#005a15;--glass-button-primary:#e1f3e5;--glass-button-primary-hover:#d4eedb;
    --glass-button-secondary:#f8fbf9;--glass-button-secondary-hover:#eef5f0;--glass-button-rim:#ccdbd0;
    --glass-button-disabled:#edf1ee;--glass-button-disabled-ink:#6b786f;
    --glass-button-shadow:0 6px 18px -10px rgba(18,57,31,.26),inset 0 1px 0 rgba(255,255,255,.9),inset 0 -1px 0 rgba(0,70,24,.04);
    --glass-button-hover-shadow:0 9px 22px -11px rgba(18,57,31,.3),inset 0 1px 0 rgba(255,255,255,.96),inset 0 -1px 0 rgba(0,70,24,.04);
    --glass-button-pressed-shadow:0 3px 9px -7px rgba(18,57,31,.22),inset 0 1px 2px rgba(0,70,24,.08);
    --radius:16px; background:var(--canvas); color:var(--text);
  }
  @supports (backdrop-filter:blur(1px)) or (-webkit-backdrop-filter:blur(1px)){
    :root{--glass-button-primary:linear-gradient(135deg,rgba(255,255,255,.64),rgba(0,180,42,.19));--glass-button-primary-hover:linear-gradient(135deg,rgba(255,255,255,.72),rgba(0,180,42,.25));--glass-button-secondary:linear-gradient(135deg,rgba(255,255,255,.58),rgba(255,255,255,.25));--glass-button-secondary-hover:linear-gradient(135deg,rgba(255,255,255,.76),rgba(255,255,255,.42));--glass-button-rim:rgba(255,255,255,.88);--glass-button-disabled:rgba(237,242,239,.65)}
  }
  *{box-sizing:border-box}
  html{scroll-behavior:smooth;scroll-padding-top:120px}
  body{margin:0;min-height:100vh;background:var(--canvas);color:var(--text);font-size:15px;line-height:1.7;-webkit-font-smoothing:antialiased;isolation:isolate}
  body::before{content:"";position:absolute;z-index:-1;top:0;left:0;right:0;height:900px;background:radial-gradient(ellipse at 0% 0%,rgba(0,180,42,.12),transparent 68%),radial-gradient(ellipse at 100% 90%,rgba(0,168,132,.09),transparent 65%);pointer-events:none}
  h1,h2,h3,h4,p,figure{margin:0} h1,h2,h3,h4{font-weight:650}
  a{color:inherit;text-decoration:none} button,input,select,textarea{font:inherit;letter-spacing:0}
  button,summary{cursor:pointer} button{color:inherit} img{display:block;max-width:100%;height:auto}
  button:disabled{cursor:not-allowed} [hidden]{display:none!important}
  a,button,input,select,summary{ -webkit-tap-highlight-color:transparent }
  :focus-visible{outline:3px solid var(--green-dark);outline-offset:5px}
  ::selection{background:#dbfde7;color:var(--ink)}
  .icon,.button-icon{width:20px;height:20px;fill:none;stroke:currentColor;stroke-width:1.65;stroke-linecap:round;stroke-linejoin:round;flex:none;vertical-align:middle}
  .button-icon{width:17px;height:17px}
  .site-header{position:sticky;top:18px;z-index:30;display:flex;align-items:center;gap:30px;width:min(1200px,calc(100% - 64px));height:72px;margin:18px auto 0;padding:0 22px;border:1px solid var(--rim);border-radius:18px;background:rgba(255,255,255,.72);box-shadow:0 8px 30px -18px rgba(25,67,42,.18),inset 0 1px 0 #fff;backdrop-filter:blur(20px);-webkit-backdrop-filter:blur(20px)}
  .brand{display:inline-flex;align-items:center;gap:9px;white-space:nowrap}
  .brand img{width:32px;height:32px;border-radius:9px}
  .brand>span{font:750 26px/1 system-ui,sans-serif;letter-spacing:-1.4px}
  .brand small{display:none}
  .site-nav{display:flex;align-items:center;justify-content:center;gap:30px;margin-left:auto;font-size:13px;font-weight:500;color:var(--muted)}
  .site-nav a{padding:9px 0;position:relative}.site-nav a:hover,.site-nav a[aria-current]{color:var(--green-dark)}
  .site-nav a[aria-current]::after{content:"";position:absolute;bottom:2px;left:calc(50% - 2px);width:4px;height:4px;border-radius:50%;background:var(--green-dark)}
  .header-action,.primary-link,.secondary-link{display:inline-flex;align-items:center;justify-content:center;gap:10px;min-height:48px;padding:0 23px;border-radius:12px;font-size:14px;font-weight:600;line-height:1.3}
  .header-action{min-height:40px;padding:0 17px;font-size:12px;margin-left:8px;white-space:nowrap}
  .text-link{display:inline-flex;align-items:center;gap:8px;min-height:36px;padding:6px 12px;border-radius:10px;font-size:14px;font-weight:600}
  .mobile-menu{display:none;position:relative}.mobile-menu summary{display:grid;place-items:center;width:40px;height:40px;border-radius:10px;list-style:none}.mobile-menu summary::-webkit-details-marker{display:none}
  ${glassButtonStyles('.header-action,.primary-link,.secondary-link,.text-link,.mobile-menu summary', { primarySelector: '.header-action,.primary-link' })}
  .mobile-links{position:absolute;right:-8px;top:52px;width:min(300px,calc(100vw - 40px));padding:10px;border:1px solid var(--rim);border-radius:16px;background:#f9fcfa;box-shadow:0 18px 50px rgba(24,52,34,.16)}
  .mobile-menu:not([open]) .mobile-links{display:none}
  .mobile-links a{display:block;padding:13px 15px;font-size:14px;border-radius:9px}.mobile-links a:hover{background:var(--green-soft)}
  .site-footer{width:min(1200px,calc(100% - 64px));margin:0 auto;padding:36px 0 24px;border-top:1px solid var(--line)}
  .footer-main{display:flex;align-items:center;justify-content:space-between;gap:24px}.footer-brand p{font-size:12px;color:var(--muted);margin-top:10px}
  .footer-links{display:flex;flex-wrap:wrap;gap:28px;font-size:13px;color:var(--muted)}.footer-links a:hover{color:var(--green-dark)}
  .footer-bottom{display:flex;justify-content:space-between;gap:20px;margin-top:36px;padding-top:18px;border-top:1px solid var(--line);font-size:11px;color:var(--faint)}
  .glass{background:var(--surface);border:1px solid var(--rim);border-radius:var(--radius);box-shadow:var(--shadow)}
  .skip-link{position:fixed;left:20px;top:-100px;z-index:100;background:#fff;color:var(--green-dark);padding:10px 18px;border-radius:10px}.skip-link:focus{top:14px}
  @media(max-width:1000px){.site-nav{gap:20px}.site-header{gap:20px}}
  @media(max-width:800px){html{scroll-padding-top:100px}.site-header{width:calc(100% - 32px);height:64px;top:12px;margin-top:12px;padding:0 14px;gap:10px}.site-nav{display:none}.header-action{margin-left:auto}.mobile-menu{display:block}.site-footer{width:calc(100% - 40px)}.footer-main{align-items:flex-start;flex-direction:column}.footer-links{gap:14px 24px}.footer-bottom{flex-wrap:wrap;gap:4px;margin-top:25px}}
  @media(max-width:380px){.header-action{font-size:11px;padding:0 12px}.brand>span{font-size:23px}.brand img{width:28px;height:28px}.site-header{gap:8px}}
  @media(prefers-reduced-motion:reduce){html{scroll-behavior:auto}*,*::before,*::after{animation-duration:.01ms!important;animation-iteration-count:1!important;transition-duration:.01ms!important}}
`;

const iconPaths = {
  arrow:'<path d="M5 12h14m-6-6 6 6-6 6"/>',
  download:'<path d="M12 3v12m-5-5 5 5 5-5M4 16v4h16v-4"/>',
  windows:'<path d="m3 5 8-1v7H3Zm10-1 8-1v8h-8ZM3 13h8v7l-8-1Zm10 0h8v8l-8-1Z"/>',
  phone:'<rect x="6" y="2" width="12" height="20" rx="2.5"/><path d="M10 5h4M11 19h2"/>',
  spool:'<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="3"/><path d="M12 3v6m0 6v6M3 12h6m6 0h6"/>',
  printer:'<path d="M5 3h14v18H5zM8 3v5h8V3M8 17h8M8 11h8v6H8z"/><path d="M10 14h4"/>',
  layers:'<path d="m12 3 10 5-10 5L2 8Zm-10 9 10 5 10-5M2 16l10 5 10-5"/>',
  box:'<path d="m12 3 9 5v9l-9 5-9-5V8Zm0 10v9M3 8l9 5 9-5M7.5 5.5l9 5"/>',
  search:'<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 5 5"/>',
  shield:'<path d="m12 3 8 3v6c0 5-8 9-8 9s-8-4-8-9V6Z"/><path d="m8 12 3 3 5-6"/>',
  clock:'<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  check:'<path d="m5 12 4 4L19 6"/>',
  menu:'<path d="M5 7h14M5 12h14M5 17h14"/>',
  close:'<path d="m6 6 12 12M18 6 6 18"/>',
  chevron:'<path d="m9 5 7 7-7 7"/>',
  plus:'<path d="M12 5v14M5 12h14"/>',
};

export function icon(name) {
  return `<svg class="icon" viewBox="0 0 24 24" aria-hidden="true">${iconPaths[name] || iconPaths.box}</svg>`;
}

export function arrowIcon() {
  return `<svg class="button-icon" viewBox="0 0 24 24" aria-hidden="true">${iconPaths.arrow}</svg>`;
}

export function logo() {
  return '<a class="brand" href="/" aria-label="sohun 耗材工作台首页"><img src="/studio/assets/sohun-mark.png" alt="" width="32" height="32"><span>sohun</span></a>';
}

export function siteHeader({ orderPage = false, parameterPage = false } = {}) {
  const links = `<a href="/#capabilities">软件功能</a><a href="/#workflow">使用流程</a><a href="/parameters"${parameterPage ? ' aria-current="page"' : ''}>参数广场</a><a href="/orders"${orderPage ? ' aria-current="page"' : ''}>订单查询</a>`;
  return `<a class="skip-link" href="#main-content">跳到主要内容</a><header class="site-header">${logo()}<nav class="site-nav" aria-label="主导航">${links}</nav><a class="header-action" href="/#download">下载客户端${arrowIcon()}</a><details class="mobile-menu"><summary aria-label="展开导航菜单">${icon('menu')}</summary><nav class="mobile-links" aria-label="移动导航">${links}<a href="/#download">下载客户端</a></nav></details></header>`;
}

export function siteFooter() {
  return `<footer class="site-footer"><div class="footer-main"><div class="footer-brand">${logo()}<p>sohun 耗材工作台 · 为每一份创作，留出更多专注。</p></div><nav class="footer-links" aria-label="页脚导航"><a href="/#capabilities">软件功能</a><a href="/parameters">参数广场</a><a href="/orders">订单查询</a><a href="/#download">下载客户端</a></nav></div><div class="footer-bottom"><span>© ${new Date().getFullYear()} sohun</span><span>耗材 · 设备 · 项目，井然有序。</span></div></footer>`;
}
