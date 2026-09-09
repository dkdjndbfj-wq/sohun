import {
  baseTokens, glassButtonStyles, arrowIcon, siteHeader, siteFooter, icon,
} from './site_theme.js';

export { renderHomePage, renderOrderAccessPage, renderMessagePage } from './marketing_site.js';
export { renderParameterPlazaPage } from './parameter_site.js';
export { renderNotFoundPage } from './not_found.js';

const STATUS_LABELS = {
  draft: '准备中', confirmed: '已确认', production: '生产中',
  completed: '已完成', delivered: '已交付', cancelled: '已取消',
  queued: '排队中', assigned: '已分配', printing: '打印中',
  paused: '已暂停', failed: '需要处理',
};

export function escapeHtml(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;').replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;').replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

const orderStyles = `
  .order-main{width:min(1120px,calc(100% - 48px));margin:0 auto;padding:46px 0 64px}
  .order-context{display:flex;align-items:center;justify-content:space-between;gap:24px;margin-bottom:31px}
  .order-breadcrumb{min-width:0;color:var(--muted);font-size:12px}.order-breadcrumb strong{font-weight:500}.order-breadcrumb span{margin-left:12px;padding-left:12px;border-left:1px solid #d6e1da}
  .connection{display:flex;align-items:center;gap:8px;flex:0 0 auto;color:var(--green-dark);font-size:12px}
  .connection i{width:7px;height:7px;border-radius:50%;background:var(--green);box-shadow:0 0 0 4px rgba(0,180,42,.08)}
  .order-summary{padding:31px 34px;border:1px solid rgba(255,255,255,.95);border-radius:24px;background:rgba(255,255,255,.66);backdrop-filter:blur(24px);box-shadow:0 12px 42px rgba(28,73,50,.04)}
  .summary-top{display:flex;align-items:flex-end;justify-content:space-between;gap:30px}
  .summary-copy{min-width:0}.workspace{margin-bottom:12px;color:var(--muted);font-size:12px}
  .summary-copy h1{margin:0;color:var(--text);font-size:34px;line-height:1.4;font-weight:700;letter-spacing:-.025em;overflow-wrap:anywhere}
  .summary-copy p{margin:10px 0 0;color:var(--muted);font-size:13px;line-height:1.7}
  .overall{text-align:right;flex:0 0 auto}.overall-label{display:block;margin-bottom:9px;color:var(--muted);font-size:11px}
  .overall-number{font-size:53px;font-weight:600;letter-spacing:-.04em;line-height:1.05;color:var(--green-dark);font-variant-numeric:tabular-nums}.overall-number small{font-size:21px;margin-left:3px}
  .overall-bar{height:7px;overflow:hidden;margin-top:28px;border-radius:6px;background:#e1eae4}.overall-bar i{display:block;height:100%;width:0;background:linear-gradient(90deg,var(--green-dark),var(--green));border-radius:inherit;transition:width .35s ease}
  .fact-strip{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:24px;margin-top:25px;padding-top:24px;border-top:1px solid #dfe8e2}
  .fact{padding-left:24px;border-left:1px solid #dfe8e2}.fact:first-child{padding-left:0;border-left:0}
  .fact span,.fact strong{display:block}.fact span{margin-bottom:8px;color:var(--muted);font-size:11px}.fact strong{font-size:16px;line-height:1.5;font-weight:600;font-variant-numeric:tabular-nums}
  .live-section{margin-top:38px}.section-heading{display:flex;align-items:center;justify-content:space-between;gap:20px;margin-bottom:19px}.section-heading h2{margin:0;font-size:19px;font-weight:650}.section-heading>span{color:var(--muted);font-size:12px}
  .video-frame{width:100%;aspect-ratio:16/9;position:relative;display:grid;place-items:center;overflow:hidden;border:1px solid #1e3227;border-radius:20px;background:#0c1410;box-shadow:0 19px 50px rgba(14,40,24,.1);pointer-events:none}
  .video-frame img,.video-frame video{display:none;width:100%;height:100%;object-fit:contain}
  .video-bar{position:absolute;z-index:2;top:0;left:0;right:0;display:flex;align-items:center;justify-content:space-between;gap:20px;padding:20px 23px;background:linear-gradient(to bottom,rgba(0,0,0,.4),transparent);color:#e7eee9;font-size:12px}
  .video-bar>span:first-child{font-weight:550}.video-live{display:flex;align-items:center;gap:7px;color:#c0d4c7;font-size:11px}.video-live i{width:6px;height:6px;border-radius:50%;background:#54cb86}
  .video-empty{display:flex;align-items:center;flex-direction:column;padding:35px;text-align:center}
  .video-empty>svg{width:38px;height:38px;margin-bottom:20px;fill:none;stroke:#71907c;stroke-width:1.6;stroke-linejoin:round;stroke-linecap:round}
  .video-empty strong{font-size:17px;font-weight:500;color:#d9e5dd}.video-empty span{margin-top:10px;color:#88a392;font-size:12px;line-height:1.8}
  .printer-rail{display:grid;grid-template-columns:1fr minmax(260px,1.4fr) auto;align-items:center;gap:22px;margin-top:14px;padding:22px 24px;border:1px solid rgba(255,255,255,.95);border-radius:16px;background:rgba(255,255,255,.62)}
  .printer-label{display:flex;align-items:center;gap:13px}.printer-label svg{width:24px;height:24px;flex:0 0 auto;color:var(--green-dark)}.printer-label strong,.printer-label span{display:block}.printer-label strong{font-size:13px;font-weight:600}.printer-label span{margin-top:6px;font-size:11px;color:var(--muted)}
  .select-wrap{position:relative;min-width:0}.select-wrap select{width:100%;height:44px;appearance:none;padding:0 38px 0 13px;border:1px solid #d7e3dc;border-radius:10px;background:rgba(255,255,255,.72);color:var(--text);outline:none;font-size:13px}
  .select-wrap select:focus{border-color:var(--green-dark);box-shadow:0 0 0 3px rgba(0,180,42,.1)}.select-wrap select:disabled{background:rgba(230,237,232,.5);color:#86988c}
  .select-wrap::after{content:"";position:absolute;right:16px;top:16px;width:7px;height:7px;border-right:1.5px solid #647d6d;border-bottom:1.5px solid #647d6d;transform:rotate(45deg);pointer-events:none}
  .printer-now{text-align:right;color:var(--muted);font-size:11px}.printer-now strong{display:block;margin-top:6px;color:var(--green-dark);font-size:20px;font-weight:600;font-variant-numeric:tabular-nums}
  .content-grid{display:grid;grid-template-columns:minmax(0,1.3fr) minmax(280px,.7fr);gap:30px;align-items:start;margin-top:38px}
  .section-title{margin:0 0 19px;font-size:19px;font-weight:650}
  .work-list{padding:4px 24px;border:1px solid rgba(255,255,255,.95);border-radius:20px;background:rgba(255,255,255,.61)}
  .work-row{display:grid;grid-template-columns:minmax(0,1fr) 104px;gap:16px;padding:22px 0;border-bottom:1px solid #dfe8e2}.work-row:last-child{border-bottom:0}
  .work-row>div:first-child{min-width:0}.work-row.selected>div:first-child strong::before{content:"";display:inline-block;width:6px;height:6px;margin:0 8px 2px 0;border-radius:50%;background:var(--green)}
  .work-row strong,.work-row small{display:block}.work-row strong{font-size:13px;font-weight:600;line-height:1.65;overflow-wrap:anywhere}.work-row small{margin-top:7px;color:var(--muted);font-size:11px;line-height:1.7}
  .row-progress{align-self:center}.row-progress b{display:block;text-align:right;font-size:13px;font-weight:550;font-variant-numeric:tabular-nums;color:var(--green-dark)}
  .mini-bar{height:5px;overflow:hidden;margin-top:9px;border-radius:4px;background:#dfe9e3}.mini-bar i{display:block;height:100%;border-radius:inherit;background:var(--green);transition:width .35s ease}
  .row-facts{grid-column:1/-1;margin-top:-7px;color:var(--muted);font-size:11px;line-height:1.7}.row-facts:empty{display:none}
  .empty-row{padding:30px 0;color:var(--muted);font-size:13px;line-height:1.8}
  .side-section+.side-section{margin-top:30px}.item-list{padding:3px 22px;border:1px solid rgba(255,255,255,.95);border-radius:20px;background:rgba(255,255,255,.6)}
  .item{padding:19px 0;border-bottom:1px solid #dfe8e2}.item:last-child{border-bottom:0}.item-top{display:flex;justify-content:space-between;gap:15px;font-size:13px;line-height:1.7}.item-top strong{font-weight:550;overflow-wrap:anywhere}.item-top span{flex:0 0 auto;color:var(--green-dark);font-variant-numeric:tabular-nums}
  .item .mini-bar{margin-top:12px}.public-note{margin:0;padding:21px 23px;border:1px solid rgba(255,255,255,.95);border-radius:18px;background:rgba(255,255,255,.48);color:var(--muted);font-size:13px;line-height:1.95;white-space:pre-wrap;overflow-wrap:anywhere}
  .privacy{display:flex;align-items:flex-start;gap:10px;margin:35px 0 0;padding-top:24px;border-top:1px solid #dfe8e2;color:var(--muted);font-size:11px;line-height:1.9}
  .privacy svg{flex:0 0 auto;width:17px;height:17px;margin-top:2px;color:var(--green-dark)}.hidden{display:none!important}
  @media(prefers-reduced-motion:reduce){.overall-bar i,.mini-bar i{transition:none}}
  @media(max-width:860px){.printer-rail{grid-template-columns:1fr minmax(230px,1fr)}.printer-now{display:none}.content-grid{grid-template-columns:1fr;gap:30px}.content-grid aside{display:grid;grid-template-columns:1fr 1fr;gap:24px}.side-section+.side-section{margin-top:0}.order-summary{padding:28px}.fact-strip{gap:18px}.fact{padding-left:18px}}
  @media(max-width:600px){.order-main{width:calc(100% - 32px);padding:27px 0 45px}.order-context{align-items:flex-start;gap:12px;margin-bottom:22px}.order-breadcrumb{font-size:11px;line-height:1.8}.order-breadcrumb strong{display:none}.order-breadcrumb span{margin:0;padding:0;border:0}.connection{font-size:11px;margin-top:4px}.order-summary{padding:24px 21px;border-radius:20px}.summary-top{align-items:flex-start;gap:20px}.summary-copy h1{font-size:24px}.summary-copy p{font-size:11px}.workspace{margin-bottom:9px;font-size:11px}.overall{padding-top:2px}.overall-label{font-size:10px}.overall-number{font-size:35px}.overall-number small{font-size:15px}.overall-bar{margin-top:22px}.fact-strip{grid-template-columns:1fr 1fr;gap:0;margin-top:23px;padding-top:4px}.fact{padding:17px 0;border-left:0;border-bottom:1px solid #dfe8e2}.fact:nth-child(even){padding-left:17px}.fact:nth-last-child(-n+2){border-bottom:0;padding-bottom:0}.fact strong{font-size:14px}.live-section,.content-grid{margin-top:29px}.section-heading{margin-bottom:15px}.section-heading h2,.section-title{font-size:17px}.section-heading>span{font-size:10px}.video-frame{border-radius:15px}.video-bar{padding:13px 15px;font-size:10px}.video-live{font-size:9px}.video-empty{padding:22px 16px}.video-empty>svg{width:26px;height:26px;margin-bottom:11px}.video-empty strong{font-size:13px}.video-empty span{margin-top:7px;font-size:10px}.printer-rail{grid-template-columns:1fr;gap:15px;padding:19px;margin-top:11px}.printer-label span{font-size:10px}.select-wrap select{font-size:12px}.content-grid aside{grid-template-columns:1fr;gap:28px}.work-list{padding:2px 20px}.work-row{grid-template-columns:minmax(0,1fr) 82px}.privacy{margin-top:27px;font-size:10px}}
`;

export function renderPublicPage(data, nonce, {
  dataUrl = '/v1/studio/public/order',
  eventsUrl = '/v1/studio/public/order/events',
  videoUrl = '/v1/studio/public/order/video.jpg',
  liveVideo = false,
  liveTransport = 'tencent',
} = {}) {
  const initial = JSON.stringify(data).replaceAll('<', '\\u003c');
  const endpoints = JSON.stringify({ dataUrl, eventsUrl, videoUrl }).replaceAll('<', '\\u003c');
  const labels = JSON.stringify(STATUS_LABELS);
  const safeNonce = escapeHtml(nonce);
  const cameraMedia = liveVideo
    ? '<video id="cameraVideo" preload="none" autoplay muted playsinline webkit-playsinline></video>'
    : '<img id="cameraImage" alt="当前打印机的实时画面">';
  const playerAssets = liveVideo && liveTransport === 'tencent'
    ? '<link href="https://tcsdk.com/player/tcplayer/release/v5.3.4/tcplayer.min.css" rel="stylesheet"><script src="https://tcsdk.com/player/tcplayer/release/v5.3.4/tcplayer.v5.3.4.min.js"></script>'
    : liveVideo
      ? `<script src="https://cdn.jsdelivr.net/npm/hls.js@1.6.2/dist/hls.min.js"></script><script nonce="${safeNonce}">(function(){window.TCPlayer=function(id,options){const video=document.getElementById(id);let hls=null;const attach=(url)=>{if(hls){hls.destroy();hls=null}if(!url){video.removeAttribute('src');video.load();return}if(window.Hls&&Hls.isSupported()){hls=new Hls({lowLatencyMode:true});hls.loadSource(url);hls.attachMedia(video)}else{video.src=url;video.play().catch(()=>{})}};attach(options&&options.sources&&options.sources[0]?options.sources[0].src:'');return{pause(){if(hls){hls.destroy();hls=null}video.pause()},src(url){attach(url)}}};})();</script>`
      : '';
  const liveVideoJson = JSON.stringify(liveVideo);
  return `<!doctype html>
<html lang="zh-CN"><head>
  <meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
  <link rel="icon" href="/favicon.ico" sizes="any"><title>${escapeHtml(data.order.title)} · 订单实时进度</title>
  <style>${baseTokens}${orderStyles}</style>${playerAssets}
</head><body>
  ${siteHeader({ orderPage: true })}
  <main class="order-main" id="main-content">
    <div class="order-context"><div class="order-breadcrumb"><strong id="headerTitle">订单实时进度</strong><span id="headerOrderNo"></span></div><div class="connection"><i></i><span id="liveText" role="status">正在连接实时数据</span></div></div>
    <section class="order-summary" aria-labelledby="title">
      <div class="summary-top"><div class="summary-copy"><div class="workspace" id="workspace"></div><h1 id="title">订单</h1><p id="orderMeta"></p></div><div class="overall"><span class="overall-label">整体完成度</span><div class="overall-number"><span id="percent">0</span><small>%</small></div></div></div>
      <div class="overall-bar"><i id="overallBar"></i></div>
      <div class="fact-strip"><div class="fact"><span>订单状态</span><strong id="status">准备中</strong></div><div class="fact"><span>当前层数</span><strong id="layer">--</strong></div><div class="fact"><span>预计剩余</span><strong id="remaining">--</strong></div><div class="fact"><span>数据更新</span><strong id="updated">--</strong></div></div>
    </section>
    <section class="live-section" aria-label="实时打印画面">
      <div class="section-heading"><h2>每一步，都看得见。</h2><span>当前订单的打印现场</span></div>
      <div class="video-frame" id="camera"><div class="video-bar"><span id="cameraLabel">当前打印画面</span><span class="video-live"><i></i><span id="cameraState">实时画面</span></span></div>${cameraMedia}<div class="video-empty" id="cameraEmpty"><svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3" y="6" width="12" height="12" rx="2"/><path d="m15 10 6-3v10l-6-3"/></svg><strong id="cameraEmptyTitle">正在读取打印状态</strong><span id="cameraEmptyDetail">画面会随生产状态自动更新</span></div></div>
      <div class="printer-rail"><div class="printer-label">${icon('printer')}<div><strong>正在打印的设备</strong><span>选择设备，查看对应画面</span></div></div><div class="select-wrap"><select id="printerSelect" aria-label="选择正在打印的打印机"><option>正在读取</option></select></div><div class="printer-now">当前工单<strong id="selectedProgress">--</strong></div></div>
    </section>
    <section class="content-grid">
      <div><h2 class="section-title">生产工单</h2><div class="work-list" id="jobs"></div></div>
      <aside><section class="side-section"><h2 class="section-title">生产清单</h2><div class="item-list" id="items"></div></section><section class="side-section"><h2 class="section-title">项目说明</h2><p class="public-note" id="note">暂无公开说明</p></section></aside>
    </section>
    <p class="privacy">${icon('shield')}<span>此页面仅展示当前订单的进度与实时画面。视频在打印期间临时转接，不提供历史回放或打印机控制。</span></p>
  </main>
  ${siteFooter()}
  <script nonce="${safeNonce}">
const endpoints=${endpoints};const liveVideo=${liveVideoJson};let data=${initial};let selectedWorkOrderId=null;let videoObjectUrl=null;let videoBusy=false;let livePlayer=null;let livePlayerWorkOrderId=null;let livePlayerSessionId=null;const labels=${labels};const $=id=>document.getElementById(id);function text(id,value){$(id).textContent=value??''}function esc(value){return String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}function label(value){return labels[value]||value||'进行中'}function clamp(value){return Math.max(0,Math.min(100,Number(value)||0))}function activePrinters(){return(data.workOrders||[]).filter(item=>item.status==='printing'&&item.activePrint&&item.printerName)}function selectedWork(){return(data.workOrders||[]).find(item=>item.id===selectedWorkOrderId)||null}function cameraMedia(){return liveVideo?$('cameraVideo'):$('cameraImage')}function stopLivePlayer(){if(livePlayer){try{livePlayer.pause();livePlayer.src('')}catch{}}livePlayerWorkOrderId=null;livePlayerSessionId=null;const media=cameraMedia();if(media)media.style.display='none'}function showBlack(title,detail,state='无画面'){const media=cameraMedia();if(media)media.style.display='none';$('cameraEmpty').classList.remove('hidden');text('cameraEmptyTitle',title);text('cameraEmptyDetail',detail);text('cameraState',state)}function render(value){data=value;const active=activePrinters();if(!active.some(item=>item.id===selectedWorkOrderId))selectedWorkOrderId=active[0]?.id??null;const selected=selectedWork();text('workspace',[value.workspaceName,value.customerName].filter(Boolean).join(' · '));text('title',value.order.title||'订单');text('headerTitle',value.order.title||'订单实时进度');text('headerOrderNo',value.order.orderNo||'');text('status',label(value.order.status));const pct=Math.round(clamp((value.completion||0)*100));text('percent',pct);$('overallBar').style.width=pct+'%';text('orderMeta',(value.order.orderNo||'')+(value.order.dueAt?' · 预计 '+value.order.dueAt+' 交付':''));text('updated',new Date(value.updatedAt).toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'}));text('note',value.order.note||'暂无公开说明');const select=$('printerSelect');select.innerHTML='';if(active.length===0){if(liveVideo)stopLivePlayer();const option=document.createElement('option');option.textContent='暂无打印机正在打印';option.value='';select.append(option);select.disabled=true;showBlack('暂无打印机正在打印','有工单开始打印后，画面会自动出现在这里');text('cameraLabel','当前打印画面')}else{for(const work of active){const option=document.createElement('option');option.value=work.id;option.textContent=work.printerName+(work.title?' · '+work.title:'');option.selected=work.id===selectedWorkOrderId;select.append(option)}select.disabled=false;text('cameraLabel',selected?.printerName||'当前打印画面')}text('selectedProgress',selected?Math.round(clamp(selected.progressPercent))+'%':'--');text('layer',selected?.totalLayers?selected.currentLayer+' / '+selected.totalLayers:'--');text('remaining',selected?.remainingMinutes?selected.remainingMinutes+' 分钟':'--');$('jobs').innerHTML=(value.workOrders||[]).length?(value.workOrders||[]).map(work=>'<div class="work-row '+(work.id===selectedWorkOrderId?'selected':'')+'"><div><strong>'+esc(work.title||'生产工单')+'</strong><small>'+esc(label(work.status))+(work.printerName?' · '+esc(work.printerName):'')+'</small></div><div class="row-progress"><b>'+Math.round(clamp(work.progressPercent))+'%</b><div class="mini-bar"><i style="width:'+clamp(work.progressPercent)+'%"></i></div></div><div class="row-facts">'+(work.totalLayers?esc(work.currentLayer+' / '+work.totalLayers+' 层'):'')+(work.remainingMinutes?(work.totalLayers?' · ':'')+esc(work.remainingMinutes+' 分钟'):'')+'</div></div>').join(''):'<div class="empty-row">工单正在准备中。</div>';$('items').innerHTML=(value.items||[]).length?(value.items||[]).map(item=>{const itemPct=item.requiredQuantity?clamp(item.completedQuantity/item.requiredQuantity*100):0;return'<div class="item"><div class="item-top"><strong>'+esc(item.name||'成品')+'</strong><span>'+item.completedQuantity+' / '+item.requiredQuantity+'</span></div><div class="mini-bar"><i style="width:'+itemPct+'%"></i></div></div>'}).join(''):'<div class="empty-row">暂无生产清单。</div>';if(!value.order.videoEnabled){if(liveVideo)stopLivePlayer();showBlack('此订单未开放实时画面','你仍然可以查看下面的生产进度')}else if(active.length===0){}else refreshVideo()}async function refreshVideo(){if(document.hidden||videoBusy||!data.order.videoEnabled||!selectedWorkOrderId)return;videoBusy=true;try{const url=endpoints.videoUrl+'?workOrderId='+encodeURIComponent(selectedWorkOrderId)+'&t='+Date.now();const response=await fetch(url,{cache:'no-store'});if(response.status!==200){if(!liveVideo||!livePlayer)showBlack('正在等待打印画面','打印机已在生产，视频流暂未建立','等待视频');return}if(liveVideo){const playback=await response.json();if(typeof TCPlayer!=='function')throw new Error('视频播放器组件未加载');const changed=livePlayerWorkOrderId!==selectedWorkOrderId||livePlayerSessionId!==playback.sessionId;if(!livePlayer){livePlayer=TCPlayer('cameraVideo',{sources:[{src:playback.url}],licenseUrl:playback.licenseUrl,autoplay:true,muted:true,controls:false,live:true});livePlayerWorkOrderId=selectedWorkOrderId;livePlayerSessionId=playback.sessionId}else if(changed){livePlayer.src(playback.url);livePlayerWorkOrderId=selectedWorkOrderId;livePlayerSessionId=playback.sessionId}const media=cameraMedia();if(media)media.style.display='block';$('cameraEmpty').classList.add('hidden');text('cameraState','实时直播')}else{const blob=await response.blob();if(videoObjectUrl)URL.revokeObjectURL(videoObjectUrl);videoObjectUrl=URL.createObjectURL(blob);const media=cameraMedia();media.src=videoObjectUrl;media.style.display='block';$('cameraEmpty').classList.add('hidden');text('cameraState','实时画面')}}catch{showBlack('实时视频暂时中断','系统会自动重新连接','正在重连')}finally{videoBusy=false}}$('printerSelect').addEventListener('change',event=>{if(liveVideo)stopLivePlayer();selectedWorkOrderId=event.target.value||null;showBlack('正在切换打印画面','请稍候','切换中');render(data)});render(data);const events=new EventSource(endpoints.eventsUrl);events.onmessage=event=>{try{render(JSON.parse(event.data));text('liveText','实时更新')}catch{}};events.onerror=()=>text('liveText','正在重新连接');document.addEventListener('visibilitychange',()=>{if(document.hidden){if(liveVideo)stopLivePlayer();showBlack('实时视频已暂停','返回此页面后会自动重新连接','已暂停')}else{refreshVideo()}});setInterval(refreshVideo,liveVideo?5000:1500);
  </script>
</body></html>`;
}

const loginStyles = `
  body{display:flex;flex-direction:column;min-height:100vh}
  .login-main{display:grid;place-items:center;flex:1;padding:72px 24px 90px}
  .login-panel{width:min(460px,100%);padding:38px;border:1px solid rgba(255,255,255,.95);border-radius:24px;background:rgba(255,255,255,.66);backdrop-filter:blur(28px);box-shadow:0 24px 66px rgba(34,81,57,.08)}
  .login-symbol{display:grid;place-items:center;width:54px;height:54px;margin-bottom:26px;border:1px solid #dcebe2;border-radius:16px;background:rgba(239,248,241,.8);color:var(--green-dark)}.login-symbol svg{width:26px;height:26px}
  .login-panel h1{margin:0;font-size:29px;line-height:1.4;letter-spacing:-.035em}
  .login-panel>p{margin:16px 0 28px;color:var(--muted);font-size:14px;line-height:1.85}
  .login-panel label{display:block;margin-bottom:9px;color:var(--muted);font-size:12px;font-weight:550}
  .login-panel input{width:100%;height:48px;padding:0 14px;border:1px solid #d7e3dc;border-radius:12px;background:rgba(255,255,255,.8);color:var(--text);font-size:14px;outline:none}
  .login-panel input:focus{border-color:var(--green-dark);box-shadow:0 0 0 3px rgba(0,180,42,.1)}
  .login-panel button{display:flex;align-items:center;justify-content:center;gap:10px;width:100%;height:48px;margin-top:16px;border-radius:12px;font-size:14px;font-weight:600;cursor:pointer}
  .login-panel button svg{width:17px;height:17px}
  .login-error{margin-bottom:19px;padding:12px 14px;border:1px solid #efccc7;border-radius:12px;background:var(--danger-soft);color:var(--danger);font-size:12px;line-height:1.8}
  .login-meta{margin-top:22px;padding-top:20px;border-top:1px solid #dfe8e2;color:var(--muted);font-size:11px;line-height:1.9}
  .login-other{display:inline-flex;align-items:center;gap:8px;min-height:36px;padding:6px 12px;margin-top:20px;border-radius:10px;font-size:12px}.login-other svg{width:14px;height:14px}
  ${glassButtonStyles('.login-panel button,.login-other', { primarySelector: '.login-panel button' })}
  @media(max-width:600px){.login-main{padding:42px 16px 56px}.login-panel{padding:28px 24px}.login-panel h1{font-size:26px}.login-panel>p{font-size:13px}}
`;

export function renderPortalLogin(share, token, { error = null } = {}) {
  const lockedUntil = share.link.locked_until;
  const locked = lockedUntil && Date.parse(lockedUntil) > Date.now();
  return `<!doctype html><html lang="zh-CN"><head>
  <meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
  <link rel="icon" href="/favicon.ico" sizes="any"><title>验证订单访问密码 · sohun</title><style>${baseTokens}${loginStyles}</style>
</head><body>${siteHeader({ orderPage: true })}
  <main class="login-main" id="main-content"><section class="login-panel">
    <div class="login-symbol">${icon('shield')}</div><h1>你的订单，<br>正在变成实物。</h1><p>输入服务方提供的访问密码，<br>查看这份订单的打印画面与生产进度。</p>
    ${error ? `<div class="login-error" role="alert">${escapeHtml(error)}</div>` : ''}
    <form method="post" action="/studio/share/${encodeURIComponent(token)}/login">
      <label for="password">访问密码</label><input id="password" name="password" type="password" autocomplete="current-password" maxlength="64" placeholder="请输入访问密码" required ${locked ? 'disabled' : ''}>
      <button type="submit" ${locked ? 'disabled' : ''}>${locked ? '访问暂时受限，请稍后再试' : '验证并进入'}${locked ? '' : arrowIcon()}</button>
    </form>
    <div class="login-meta">这是服务方分享给你的专属订单链接。验证后仅显示当前订单，不提供打印机控制或其他客户信息。</div>
    <a class="login-other" href="/orders">使用订单号查询${arrowIcon()}</a>
  </section></main>${siteFooter()}
</body></html>`;
}
