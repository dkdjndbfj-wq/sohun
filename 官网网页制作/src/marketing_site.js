import { baseTokens, siteHeader, siteFooter, icon, arrowIcon } from './site_theme.js';
import { marketingStyles } from './marketing_styles.js';
import { workbenchPreview, workflowSection, connectedSection } from './product_showcase.js';
import { downloadSection, downloadPlatformScript } from './download_section.js';

function escape(value) {
  return String(value ?? '').replace(/[&<>"']/g, (character) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  })[character]);
}

function head(title, description) {
  return `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="description" content="${escape(description)}"><meta name="theme-color" content="#f4f6f5"><link rel="icon" href="/favicon.ico" sizes="any"><title>${escape(title)}</title><style>${baseTokens}${marketingStyles}</style></head>`;
}

function featureSection() {
  const features = [
    ['spool', '每一卷，都清清楚楚。', '材质、颜色、批次与剩余克数，整理成自己的耗材库。打印前，先知道手边有什么。', '耗材库存 / 余量记录'],
    ['printer', '每一台，都尽在眼前。', '集中查看打印机状态、当前任务和打印进度。设备需要处理时，更容易及时发现。', '设备管理 / 打印状态'],
    ['layers', '每一步，都有迹可循。', '导入 3MF 文件，保留打印盘和对象名称。从一个创意到多个任务，安排更有条理。', '切片项目 / 多盘安排'],
  ];
  return `<section class="capabilities content-width" id="capabilities"><div class="section-heading-row"><h2>从耗材到作品，<br>每一步都有据可依。</h2><p>不用再来回翻找表格、切片文件和聊天记录。<br>让信息回到它该在的位置，把专注留给创作。</p></div><div class="feature-grid">${features.map(([glyph, title, description, meta]) => `<article class="feature-item"><div class="feature-icon">${icon(glyph)}</div><h3>${title}</h3><p>${description}</p><span class="feature-meta">${meta}</span></article>`).join('')}</div><div class="desktop-reference"><a class="text-link" href="/studio/assets/personal-inventory-v4.png" target="_blank" rel="noopener">查看个人端耗材库存截图${arrowIcon()}</a></div></section>`;
}

function previewScript(nonce) {
  return `<script nonce="${escape(nonce)}">
    (() => {
      ${downloadPlatformScript}
      const tabs = [...document.querySelectorAll('.preview-tab')];
      const activate = (tab) => {
        for (const item of tabs) {
          const selected = item === tab;
          item.setAttribute('aria-selected', String(selected));
          item.tabIndex = selected ? 0 : -1;
          document.getElementById(item.getAttribute('aria-controls')).hidden = !selected;
        }
      };
      tabs.forEach((tab, index) => {
        tab.addEventListener('click', () => activate(tab));
        tab.addEventListener('keydown', (event) => {
          let next;
          if (event.key === 'ArrowRight' || event.key === 'ArrowDown') next = (index + 1) % tabs.length;
          else if (event.key === 'ArrowLeft' || event.key === 'ArrowUp') next = (index + tabs.length - 1) % tabs.length;
          else if (event.key === 'Home') next = 0;
          else if (event.key === 'End') next = tabs.length - 1;
          else return;
          event.preventDefault(); activate(tabs[next]); tabs[next].focus();
        });
      });
      for (const menu of document.querySelectorAll('.mobile-menu')) {
        menu.querySelectorAll('a').forEach(link => link.addEventListener('click', () => menu.removeAttribute('open')));
        menu.addEventListener('keydown', event => {
          if (event.key === 'Escape') { menu.open = false; menu.querySelector('summary').focus(); }
        });
      }
    })();
  </script>`;
}

export function renderHomePage(nonce = '', downloads = {}) {
  return `${head('sohun 耗材工作台 · 让每一份创作，都井然有序', 'sohun 个人耗材工作台，将 3D 打印耗材库存、打印机状态和多盘项目整理在一起。探索软件功能、社区参数与订单查询。')}<body>${siteHeader()}<main class="home-main" id="main-content"><section class="hero"><div class="intro-enter"><h1>让每一份创作，<span>都井然有序。</span></h1><p class="hero-description">从一卷耗材到每一次打印，把库存、设备与项目，<br>收进一个清晰的工作台。</p><div class="hero-actions"><a class="primary-link" id="primaryDownload" href="#download">${icon('download')}<span data-download-label>选择下载版本</span>${arrowIcon()}</a><a class="secondary-link" href="#capabilities">探索软件功能${icon('chevron')}</a></div></div>${workbenchPreview()}<div class="preview-note"><span>${icon('spool')}耗材一目了然</span><span>${icon('printer')}设备集中管理</span><span>${icon('layers')}项目有序推进</span></div></section>${featureSection()}${workflowSection()}${connectedSection()}${downloadSection(downloads)}</main>${siteFooter()}${previewScript(nonce)}</body></html>`;
}

export function renderOrderAccessPage({ error = null, orderNo = '' } = {}) {
  const errorMessage = error === 'invalid' ? '订单号或访问密码不正确，请检查后重试。' : error === 'unavailable' ? '订单服务暂时无法连接，请稍后重试。' : null;
  const features = [['clock', '每一步进度，随时了解', '查看订单状态、完成度与预计剩余时间。'], ['printer', '每一次打印，都更透明', '服务方开放后，可查看关联打印机的实时画面。'], ['shield', '专属订单，专属访问', '验证后仅展示与你的订单相关的信息。']];
  return `${head('订单查询 · sohun', '使用服务方提供的订单号和访问密码，查看 sohun 订单生产进度。')}<body class="utility-page">${siteHeader({ orderPage: true })}<main class="access-main" id="main-content"><section class="access-copy"><h1>你的作品，<span>正在成为现实。</span></h1><p>从开始打印，到准备交付。<br>在这里，查看专属于你的订单进度。</p><div class="access-features">${features.map(([glyph, title, description]) => `<div class="access-feature">${icon(glyph)}<div><strong>${title}</strong><p>${description}</p></div></div>`).join('')}</div></section><section class="access-panel" aria-labelledby="access-title"><div class="access-lock">${icon('shield')}</div><h2 id="access-title">输入订单信息</h2><p>订单号和访问密码由服务方提供。</p>${errorMessage ? `<div class="form-error" id="access-error" role="alert">${errorMessage}</div>` : ''}<form method="post" action="/studio/order-login"${errorMessage ? ' aria-describedby="access-error"' : ''}><div class="field"><label for="orderNo">订单号</label><input id="orderNo" name="orderNo" type="text" value="${escape(orderNo)}" autocomplete="off" maxlength="100" placeholder="例如 SO-2026-001" required></div><div class="field"><label for="password">访问密码</label><input id="password" name="password" type="password" autocomplete="current-password" maxlength="64" placeholder="请输入服务方提供的密码" required></div><button class="primary-link access-submit" type="submit">查看订单进度${arrowIcon()}</button></form><p class="access-help">没有订单信息？请联系为你提供打印服务的服务方。<br><a href="/">了解 sohun 耗材工作台${arrowIcon()}</a></p></section></main>${siteFooter()}</body></html>`;
}

export function renderMessagePage(title, message) {
  const platform = title === '下载地址尚未配置' ? 'Windows'
    : title === 'Android 安装包正在准备中' ? 'Android' : null;
  const download = platform !== null || title === '下载入口无效';
  const visibleTitle = platform ? `${platform} 安装包正在准备中` : title;
  const description = platform
    ? `${platform} 安装包尚未开放下载，请稍后再来。你也可以返回下载区，查看其他平台的版本。`
    : message;
  return `${head(`${title} · sohun`, description)}<body class="utility-page">${siteHeader()}<main class="message-main" id="main-content"><section class="message-panel glass"><div class="message-symbol">${icon(platform === 'Android' ? 'phone' : download ? 'windows' : 'box')}</div><h1>${escape(visibleTitle)}</h1><p>${escape(description)}</p><div class="message-actions"><a class="primary-link" href="${download ? '/#download' : '/orders'}">${download ? '返回下载区' : '返回订单入口'}${arrowIcon()}</a><a class="secondary-link" href="${download ? '/parameters' : '/'}">${download ? '浏览参数广场' : '返回首页'}</a></div><div class="message-caption">${platform ? 'sohun · ' + platform + ' 客户端' : 'sohun 耗材工作台'}</div></section></main>${siteFooter()}</body></html>`;
}
