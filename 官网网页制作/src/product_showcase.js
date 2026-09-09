import { icon, arrowIcon } from './site_theme.js';

// Screenshots are captured from AuroraWorkspace by the existing Flutter visual
// test. Keep the image pixels intact: no substitute HTML chrome or color wash.
const desktopScreens = [
  { id: 'workspace', label: '工作台', glyph: 'box', file: 'personal-workspace-v4.png' },
  { id: 'inventory', label: '耗材库存', glyph: 'spool', file: 'personal-inventory-v4.png' },
];

export function workbenchPreview() {
  return `<div class="desktop-showcase intro-enter intro-delay" id="product">
    <div class="preview-tabs" role="tablist" aria-label="切换个人桌面端截图">
      ${desktopScreens.map((screen, index) => `<button class="preview-tab" id="tab-${screen.id}" type="button" role="tab" aria-controls="preview-${screen.id}" aria-selected="${index === 0}" tabindex="${index === 0 ? 0 : -1}">${icon(screen.glyph)}${screen.label}</button>`).join('')}
    </div>
    ${desktopScreens.map((screen, index) => `<section id="preview-${screen.id}" class="desktop-screen" role="tabpanel" aria-labelledby="tab-${screen.id}" tabindex="0"${index ? ' hidden' : ''}>
      <figure>
        <a class="desktop-image-link" href="/studio/assets/${screen.file}" target="_blank" rel="noopener" aria-label="查看${screen.label}截图原图（新窗口）">
          <img src="/studio/assets/${screen.file}" width="1360" height="900" alt="sohun 个人桌面端实际${screen.label}界面，浅色极光绿主题" ${index ? 'loading="lazy"' : 'fetchpriority="high"'}>
        </a>
        <figcaption><span>个人桌面端 · ${screen.label}<small>界面内为演示数据</small></span><a href="/studio/assets/${screen.file}" target="_blank" rel="noopener">查看原图${arrowIcon()}</a></figcaption>
      </figure>
    </section>`).join('')}
  </div>`;
}

export function workflowSection() {
  const steps = [
    ['01', '导入你的切片项目', '保留盘号与对象名称，信息不散落。'],
    ['02', '按实际产能安排', '先生产需要的盘，其余留待下一次。'],
    ['03', '跟进每一次打印', '让设备、耗材和任务保持关联。'],
  ];
  return `<section class="workflow-band" id="workflow"><div class="workflow-layout content-width"><div class="section-copy"><h2>把灵感，<br>安排成下一次打印。</h2><p>一个文件、多个打印盘，也可以有条不紊。<br>按自己的节奏，把想法一步步变成实物。</p></div><ol class="workflow-steps">${steps.map(([number, title, description]) => `<li><span class="step-number">${number}</span><div><strong>${title}</strong><p>${description}</p></div></li>`).join('')}</ol></div></section>`;
}

export function connectedSection() {
  return `<section class="connected-section content-width" id="customer-view"><div class="connected-heading"><h2>好经验，一起分享。<br>好作品，安心交付。</h2><p>从寻找合适的打印参数，到让客户随时了解进度。</p></div><div class="connected-grid"><article class="connected-card"><div class="feature-icon">${icon('layers')}</div><h3>让下一次打印，有经验可循。</h3><p>在参数广场按材质、用途和机型寻找公开参数，查看适配信息，再回到桌面软件应用。</p><a class="text-link" href="/parameters">探索参数广场${arrowIcon()}</a></article><article class="connected-card"><div class="feature-icon">${icon('shield')}</div><h3>进度看得见，交付更安心。</h3><p>客户凭订单号和访问密码，查看专属订单的生产进度。服务方开放后，还能查看实时打印画面。</p><a class="text-link" href="/orders">进入订单查询${arrowIcon()}</a></article></div></section>`;
}
