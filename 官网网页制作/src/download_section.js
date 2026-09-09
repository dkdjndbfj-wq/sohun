import { icon, arrowIcon } from './site_theme.js';

export function downloadSection({
  windowsDownloadAvailable = false,
  androidDownloadAvailable = false,
} = {}) {
  const platforms = [
    { id: 'windows', name: 'Windows', glyph: 'windows', edition: '个人桌面端', description: '整理耗材库存、打印机和切片项目。', format: 'Windows · EXE 安装包', url: '/download', available: windowsDownloadAvailable },
    { id: 'android', name: 'Android', glyph: 'phone', edition: '原生移动端', description: '在手机上管理个人耗材，随身查看库存。', format: 'Android · APK 安装包', url: '/download/android', available: androidDownloadAvailable },
  ];
  return `<section class="download-section" id="download" aria-labelledby="download-title"><div class="download-symbol">${icon('download')}</div><h2 id="download-title">选择适合你的工作台。</h2><p>在电脑上有序安排，在手机上随手查看。</p><div class="download-grid">${platforms.map(platform => `<article class="download-card" data-download-platform="${platform.id}" data-download-available="${platform.available}" data-download-url="${platform.url}" aria-labelledby="download-${platform.id}-title"><div class="download-card-heading"><div class="download-platform-icon">${icon(platform.glyph)}</div><div><h3 id="download-${platform.id}-title">${platform.name}</h3><span>${platform.edition}</span></div></div><p>${platform.description}</p><div class="download-format">${platform.format}</div>${platform.available ? `<a class="primary-link platform-download" href="${platform.url}">${icon('download')}下载 ${platform.name} 版${arrowIcon()}</a>` : `<div class="download-pending" role="status">${platform.name} 安装包正在准备中</div>`}</article>`).join('')}</div><p class="download-platform-note" id="platform-download-note">目前提供 Windows 与 Android 版本，暂未提供 iOS / iPadOS 安装包。</p></section>`;
}

// Use the operating system, not viewport width. An iPad can request a desktop
// user agent; touch-capable Macintosh identifies that case without hiding choices.
export function detectDownloadPlatform({ userAgent = '', platform = '', maxTouchPoints = 0 } = {}) {
  if (/android/i.test(platform) || /android/i.test(userAgent)) return 'android';
  if (/iphone|ipad|ipod/i.test(userAgent)
      || (/mac/i.test(platform + ' ' + userAgent) && maxTouchPoints > 1)) return 'ios';
  if (/win/i.test(platform) || /windows/i.test(userAgent)) return 'windows';
  return 'unknown';
}

function initializeDownloads(detectPlatform) {
  const platform = detectPlatform({
    userAgent: navigator.userAgent,
    platform: navigator.userAgentData?.platform || navigator.platform,
    maxTouchPoints: navigator.maxTouchPoints,
  });
  const primary = document.getElementById('primaryDownload');
  const note = document.getElementById('platform-download-note');
  if (!primary || !note) return;
  if (platform === 'ios') {
    primary.querySelector('[data-download-label]').textContent = '查看支持的平台';
    note.textContent = 'iPhone / iPad 暂无可安装的客户端。目前可选择 Windows 版或 Android 版。';
    return;
  }
  const card = document.querySelector('[data-download-platform="' + platform + '"]');
  if (!card) return;
  // Keep reading/tab order consistent with the recommended platform on screen.
  card.parentElement.prepend(card);
  card.setAttribute('data-current-platform', 'true');
  const name = platform === 'android' ? 'Android' : 'Windows';
  const available = card.dataset.downloadAvailable === 'true';
  primary.href = available ? card.dataset.downloadUrl : '#download';
  primary.querySelector('[data-download-label]').textContent = (available ? '下载 ' : '查看 ') + name + ' 版';
  note.textContent = platform === 'android'
    ? 'Android 版提供 APK 安装包。Windows 版需要在电脑上安装。'
    : 'Windows 版适用于电脑，Android 版可在手机上下载安装。';
}

export const downloadPlatformScript = `(${initializeDownloads.toString()})(${detectDownloadPlatform.toString()});`;
