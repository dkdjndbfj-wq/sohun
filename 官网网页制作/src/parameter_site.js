import {
  baseTokens, glassButtonStyles, siteHeader, siteFooter, icon, arrowIcon,
} from './site_theme.js';

const parameterStyles = `
  body{display:flex;flex-direction:column;min-height:100vh}
  .parameter-main{width:min(1180px,calc(100% - 48px));flex:1;margin:0 auto;padding-bottom:88px}
  .parameter-hero{display:grid;grid-template-columns:1.2fr .8fr;align-items:center;gap:70px;padding:88px 0 58px}
  .parameter-hero h1{margin:0;font-size:clamp(38px,4.6vw,60px);line-height:1.22;letter-spacing:-.04em;font-weight:750}
  .parameter-hero h1 span{color:var(--green-dark)}
  .parameter-hero p{max-width:540px;margin:22px 0 0;color:var(--muted);font-size:16px;line-height:1.9}
  .parameter-visual{position:relative;overflow:hidden;padding:27px 30px;border:1px solid rgba(255,255,255,.94);border-radius:24px;background:rgba(255,255,255,.58);backdrop-filter:blur(24px);box-shadow:0 18px 54px rgba(37,80,62,.07)}
  .parameter-visual::before{content:"";position:absolute;z-index:-1;width:180px;height:180px;right:-34px;top:-25px;border-radius:50%;background:rgba(0,180,42,.08);filter:blur(38px)}
  .visual-heading{display:flex;align-items:center;gap:12px;padding-bottom:20px;border-bottom:1px solid var(--line);font-size:14px;font-weight:650}
  .visual-heading svg{width:27px;height:27px;color:var(--green-dark)}
  .visual-line{display:flex;justify-content:space-between;align-items:center;gap:18px;margin-top:20px;font-size:13px}
  .visual-line>span{color:var(--muted)}.visual-line strong{font-size:14px;font-weight:600}
  .visual-materials{display:flex;align-items:center;gap:8px}
  .visual-dot{width:10px;height:10px;border-radius:50%;background:#72c8a6}
  .visual-dot.cyan{background:#75bac6;margin-left:8px}
  .filter-form{padding:24px;border:1px solid rgba(255,255,255,.94);border-radius:24px;background:rgba(255,255,255,.68);backdrop-filter:blur(24px);box-shadow:0 12px 44px rgba(28,73,50,.045)}
  .search-line{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:12px;margin-bottom:19px;align-items:end}
  .filter-field{min-width:0}.filter-field label{display:block;margin-bottom:8px;color:var(--muted);font-size:12px;font-weight:550}
  .search-field{position:relative}.search-field>svg{position:absolute;left:16px;top:43px;width:19px;height:19px;color:var(--muted);pointer-events:none}
  .filter-field input,.filter-field select{width:100%;height:46px;padding:0 13px;border:1px solid #dce5e0;border-radius:12px;background:rgba(255,255,255,.7);color:var(--text);font-size:13px;font-weight:400;outline:none;transition:border-color .2s,box-shadow .2s}
  .search-field input{height:50px;padding-left:46px;font-size:14px}
  .filter-field input::placeholder{color:#829289}
  .filter-field input:focus,.filter-field select:focus{border-color:var(--green-dark);box-shadow:0 0 0 3px rgba(0,180,42,.1)}
  .filter-submit{display:flex;align-items:center;justify-content:center;gap:10px;height:50px;padding:0 23px;border-radius:12px;font-size:14px;font-weight:650;cursor:pointer}
  .filter-submit svg{width:17px;height:17px}
  .filter-options{display:grid;grid-template-columns:repeat(4,minmax(0,1fr)) auto;gap:13px;align-items:end}
  .filter-reset{height:46px;padding:0 15px;border-radius:12px;font-size:13px;cursor:pointer}
  .parameter-layout{display:grid;grid-template-columns:minmax(0,1fr) 236px;gap:42px;align-items:start;padding-top:40px}
  .result-bar{display:flex;align-items:center;justify-content:space-between;gap:16px;margin:0 0 20px;color:var(--muted);font-size:12px}
  .result-bar h2{margin:0;color:var(--text);font-size:19px;font-weight:650}
  .preset-list{display:grid;gap:12px}
  .preset-row{display:grid;grid-template-columns:minmax(0,1fr) 44px;gap:22px;padding:24px 26px;border:1px solid rgba(255,255,255,.95);border-radius:18px;background:rgba(255,255,255,.64);box-shadow:0 6px 18px rgba(27,67,46,.025);transition:background .2s,box-shadow .2s}
  .preset-row:hover{background:rgba(255,255,255,.92);box-shadow:0 12px 25px rgba(27,67,46,.05)}
  .preset-row-main{min-width:0}.preset-topline{display:flex;flex-wrap:wrap;gap:9px 14px;align-items:center;color:var(--muted);font-size:11px}
  .preset-material{display:inline-flex;align-items:center;padding:4px 9px;border-radius:6px;background:#e9f5ef;color:var(--green-dark);font-weight:650}
  .preset-row h3{margin:12px 0 0;font-size:19px;line-height:1.5;font-weight:650;overflow-wrap:anywhere}
  .preset-row p{display:-webkit-box;overflow:hidden;margin:7px 0 0;color:var(--muted);font-size:13px;line-height:1.85;-webkit-box-orient:vertical;-webkit-line-clamp:2}
  .preset-meta{display:flex;flex-wrap:wrap;gap:8px 17px;margin:15px 0 0;padding:0;list-style:none;color:var(--muted);font-size:11px}
  .preset-tags{display:flex;flex-wrap:wrap;gap:7px;margin-top:14px}
  .preset-tag{padding:4px 8px;border:1px solid #e1e9e4;border-radius:6px;color:var(--muted);font-size:11px;overflow-wrap:anywhere}
  .preset-action{align-self:center;display:grid;place-items:center;width:42px;height:42px;border-radius:50%;cursor:pointer}
  .preset-action svg{width:17px;height:17px;fill:none;stroke:currentColor;stroke-width:1.7;stroke-linecap:round;stroke-linejoin:round}
  .parameter-aside{padding:2px 0}.parameter-aside h2{margin:0 0 23px;font-size:15px;font-weight:650}
  .usage-step{display:grid;grid-template-columns:26px minmax(0,1fr);gap:11px;margin-top:23px}
  .usage-step>span{display:grid;place-items:center;width:23px;height:23px;border:1px solid #d9e7de;border-radius:50%;color:var(--green-dark);font-size:11px}
  .usage-step strong{display:block;margin:1px 0 7px;font-size:13px;font-weight:600}.usage-step p{margin:0;color:var(--muted);font-size:12px;line-height:1.85}
  .aside-download{display:inline-flex;align-items:center;gap:8px;min-height:36px;padding:6px 10px;margin:29px 0 0 37px;border-radius:10px;font-size:12px;font-weight:600}.aside-download svg{width:15px;height:15px}
  .result-state{display:flex;align-items:center;flex-direction:column;justify-content:center;min-height:260px;padding:38px 28px;border:1px solid rgba(255,255,255,.95);border-radius:20px;background:rgba(255,255,255,.5);color:var(--muted);font-size:13px;line-height:1.8;text-align:center}
  .result-state::before{content:"";width:40px;height:40px;margin-bottom:20px;border:1px solid #d0e2d7;border-radius:50%;box-shadow:inset 0 0 0 10px rgba(225,241,230,.65)}
  .result-state strong{display:block;margin-bottom:9px;color:var(--text);font-size:18px;font-weight:600}
  .result-state button,.load-more{height:40px;margin-top:22px;padding:0 19px;border-radius:11px;font-size:13px;font-weight:550;cursor:pointer}
  .load-more-wrap{text-align:center}.load-more[hidden]{display:none}
  .preset-dialog{width:min(620px,calc(100% - 32px));max-height:calc(100dvh - 40px);padding:0;border:1px solid rgba(255,255,255,.95);border-radius:24px;background:rgba(247,251,248,.94);backdrop-filter:blur(30px);color:var(--text);box-shadow:0 36px 100px rgba(15,47,30,.2)}
  .preset-dialog::backdrop{background:rgba(17,39,28,.32);backdrop-filter:blur(7px)}
  .dialog-inner{position:relative;padding:35px}
  .dialog-close{position:absolute;right:20px;top:20px;display:grid;place-items:center;width:35px;height:35px;border-radius:50%;cursor:pointer}.dialog-close svg{width:17px;height:17px}
  ${glassButtonStyles('.filter-submit,.filter-reset,.preset-action,.aside-download,.result-state button,.load-more,.dialog-close', { primarySelector: '.filter-submit' })}
  .dialog-kicker{padding-right:35px;color:var(--green-dark);font-size:12px;font-weight:600}
  .dialog-inner h2{margin:13px 0 0;padding-right:16px;font-size:28px;line-height:1.4;overflow-wrap:anywhere}
  .dialog-description{margin:16px 0 0;color:var(--muted);font-size:14px;line-height:1.85;white-space:pre-wrap;overflow-wrap:anywhere}
  .dialog-details{display:grid;grid-template-columns:1fr 1fr;gap:0 24px;margin-top:27px;border-top:1px solid #dce6df}
  .dialog-details div{min-width:0;padding:16px 0;border-bottom:1px solid #dce6df}
  .dialog-details span,.dialog-details strong{display:block}.dialog-details span{margin-bottom:6px;color:var(--muted);font-size:11px}.dialog-details strong{font-size:13px;font-weight:550;line-height:1.7;overflow-wrap:anywhere}
  .dialog-footnote{display:flex;align-items:flex-start;gap:10px;margin:24px 0 0;color:var(--muted);font-size:12px;line-height:1.8}.dialog-footnote svg{flex:0 0 auto;width:17px;height:17px;margin-top:2px;color:var(--green-dark)}
  @media(max-width:960px){.parameter-hero{gap:34px;padding:64px 0 42px}.parameter-layout{grid-template-columns:minmax(0,1fr) 210px;gap:26px}.filter-options{grid-template-columns:repeat(4,minmax(0,1fr))}.filter-reset{grid-column:1/-1;justify-self:end;height:28px;margin-top:-3px}.parameter-visual{padding:23px}}
  @media(max-width:720px){.parameter-main{width:calc(100% - 32px);padding-bottom:52px}.parameter-hero{grid-template-columns:1fr;gap:29px;padding:44px 0 32px}.parameter-hero h1{font-size:39px;letter-spacing:-.04em}.parameter-hero p{margin-top:18px;font-size:14px}.parameter-visual{padding:22px 24px}.visual-heading{padding-bottom:15px}.visual-line{margin-top:15px}.filter-form{padding:18px;border-radius:20px}.search-line{grid-template-columns:1fr;gap:10px;margin-bottom:18px}.filter-submit{height:45px}.filter-options{grid-template-columns:1fr 1fr;gap:13px}.filter-reset{height:30px}.parameter-layout{grid-template-columns:1fr;padding-top:28px;gap:33px}.parameter-aside{border-top:1px solid #dce6df;padding-top:28px}.parameter-aside h2{margin-bottom:19px}.usage-step{margin-top:18px}.aside-download{margin-top:22px}.preset-row{padding:20px;gap:13px;grid-template-columns:minmax(0,1fr) 36px}.preset-row h3{font-size:18px}.preset-action{width:36px;height:36px}.result-state{min-height:240px;padding:30px 22px}.dialog-inner{padding:28px 22px}.dialog-inner h2{font-size:24px}.dialog-details{grid-template-columns:1fr}.dialog-close{right:15px;top:15px}}
`;

export function renderParameterPlazaPage(nonce = '') {
  const escapedNonce = String(nonce).replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
  const nonceAttr = nonce ? ` nonce="${escapedNonce}"` : '';
  return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="description" content="浏览 sohun 社区公开的打印参数，按材料、用途与打印机查找适合下一次打印的配置。">
  <link rel="icon" href="/favicon.ico" sizes="any"><title>参数广场 · sohun</title>
  <style>${baseTokens}${parameterStyles}</style>
</head>
<body>
  ${siteHeader({ parameterPage: true })}
  <main class="parameter-main" id="main-content">
    <section class="parameter-hero">
      <div><h1>找到下一次打印的<br><span>好参数。</span></h1><p>来自社区的打印经验，在这里汇集。<br>按材料、用途和机型查找，让每一次尝试更有把握。</p></div>
      <div class="parameter-visual" aria-label="参数筛选信息示意">
        <div class="visual-heading">${icon('spool')}<span>让经验，找到合适的材料。</span></div>
        <div class="visual-line"><span>按材料</span><strong class="visual-materials"><i class="visual-dot"></i>PLA<i class="visual-dot cyan"></i>PETG</strong></div>
        <div class="visual-line"><span>按用途</span><strong>从日常小物，到功能零件</strong></div>
        <div class="visual-line"><span>按机型</span><strong>查找与你的设备适配的参数</strong></div>
      </div>
    </section>
    <form class="filter-form" id="presetFilters" role="search" aria-label="搜索公开打印参数">
      <div class="search-line">
        <div class="filter-field search-field"><label for="presetSearch">搜索参数</label>${icon('search')}<input id="presetSearch" name="q" type="search" maxlength="120" placeholder="输入参数名称、说明或标签"></div>
        <button class="filter-submit" type="submit">搜索参数${arrowIcon()}</button>
      </div>
      <div class="filter-options">
        <div class="filter-field"><label for="presetMaterial">材料</label><input id="presetMaterial" name="material" list="materialOptions" maxlength="80" placeholder="全部材料"><datalist id="materialOptions"></datalist></div>
        <div class="filter-field"><label for="presetScene">用途</label><input id="presetScene" name="scene" list="sceneOptions" maxlength="80" placeholder="全部用途"><datalist id="sceneOptions"></datalist></div>
        <div class="filter-field"><label for="presetPrinter">适配机型</label><input id="presetPrinter" name="printer" list="printerOptions" maxlength="120" placeholder="全部机型"><datalist id="printerOptions"></datalist></div>
        <div class="filter-field"><label for="presetSort">排序方式</label><select id="presetSort" name="sort"><option value="recommended">推荐</option><option value="newest">最新发布</option><option value="popular">应用较多</option><option value="mostLiked">点赞较多</option><option value="name">名称</option></select></div>
        <button class="filter-reset" type="button" id="resetFilters">清除筛选</button>
      </div>
    </form>
    <div class="parameter-layout">
      <section aria-labelledby="presetResultsTitle">
        <div class="result-bar"><h2 id="presetResultsTitle">公开参数</h2><span id="presetStatus" aria-live="polite">正在读取...</span></div>
        <div class="preset-list" id="presetResults" aria-live="polite" aria-busy="true"></div>
        <div class="load-more-wrap"><button class="load-more" type="button" id="loadMore" hidden>继续加载</button></div>
      </section>
      <aside class="parameter-aside"><h2>让好参数用起来</h2>
        <div class="usage-step"><span>1</span><div><strong>找到合适的配置</strong><p>先确认材料、用途和适配机型，再查看发布者的说明。</p></div></div>
        <div class="usage-step"><span>2</span><div><strong>在工作台中应用</strong><p>打开桌面软件的参数广场，导入或应用你选中的参数。</p></div></div>
        <div class="usage-step"><span>3</span><div><strong>分享你的打印经验</strong><p>在桌面软件发布公开参数，让下一位创作者少走弯路。</p></div></div>
        <a class="aside-download" href="/download">下载桌面客户端${arrowIcon()}</a>
      </aside>
    </div>
  </main>
  ${siteFooter()}
  <dialog class="preset-dialog" id="presetDialog" aria-labelledby="dialogTitle">
    <div class="dialog-inner">
      <button class="dialog-close" type="button" id="dialogClose" aria-label="关闭参数详情">${icon('close')}</button>
      <div class="dialog-kicker" id="dialogKicker">公开参数</div><h2 id="dialogTitle"></h2><p class="dialog-description" id="dialogDescription"></p>
      <div class="preset-tags" id="dialogTags"></div><div class="dialog-details" id="dialogDetails"></div>
      <p class="dialog-footnote">${icon('download')}<span>打开 sohun 桌面软件的参数广场，即可导入或应用此参数。</span></p>
    </div>
  </dialog>
  <script${nonceAttr}>
(function(){
    const form=document.getElementById('presetFilters'),results=document.getElementById('presetResults'),status=document.getElementById('presetStatus'),moreButton=document.getElementById('loadMore'),dialog=document.getElementById('presetDialog'),dialogTitle=document.getElementById('dialogTitle'),dialogKicker=document.getElementById('dialogKicker'),dialogDescription=document.getElementById('dialogDescription'),dialogTags=document.getElementById('dialogTags'),dialogDetails=document.getElementById('dialogDetails');
    const fields={q:document.getElementById('presetSearch'),material:document.getElementById('presetMaterial'),scene:document.getElementById('presetScene'),printer:document.getElementById('presetPrinter'),sort:document.getElementById('presetSort')},optionLists={material:document.getElementById('materialOptions'),scene:document.getElementById('sceneOptions'),printer:document.getElementById('printerOptions')};
    const state={items:[],nextCursor:null,controller:null};const text=value=>typeof value==='string'?value.trim():'';const sourceOf=item=>item&&item.preset&&item.preset.preset?item.preset.preset:(item&&item.preset?item.preset:{});const listOf=value=>Array.isArray(value)?value.map(text).filter(Boolean):[];const numberOf=value=>Number.isFinite(Number(value))?Number(value):0;const dateOf=value=>{const date=new Date(value);return Number.isNaN(date.getTime())?'未标注时间':new Intl.DateTimeFormat('zh-CN',{year:'numeric',month:'short',day:'numeric'}).format(date)};const clear=node=>{while(node.firstChild)node.removeChild(node.firstChild)};function create(tag,className,content){const node=document.createElement(tag);if(className)node.className=className;if(content)node.textContent=content;return node}
    function currentFilters(){return{q:text(fields.q.value),material:text(fields.material.value),scene:text(fields.scene.value),printer:text(fields.printer.value),sort:fields.sort.value}}function setUrl(filters){const params=new URLSearchParams();Object.entries(filters).forEach(([key,value])=>{if(value&&!(key==='sort'&&value==='recommended'))params.set(key,value)});const query=params.toString();history.replaceState(null,'',query?'/parameters?'+query:'/parameters')}
    function setState(kind,message,retry=false){clear(results);const panel=create('div','result-state');panel.appendChild(create('strong','',kind));panel.appendChild(create('span','',message));if(retry){const button=create('button','','重新读取');button.type='button';button.addEventListener('click',()=>load());panel.appendChild(button)}results.appendChild(panel)}
    function updateOptions(items){const values={material:new Set(),scene:new Set(),printer:new Set()};items.forEach(item=>{const preset=sourceOf(item),material=text(preset.material),scene=text(preset.scene);if(material)values.material.add(material);if(scene)values.scene.add(scene);listOf(preset.compatiblePrinters).forEach(value=>values.printer.add(value))});Object.entries(optionLists).forEach(([key,list])=>{clear(list);[...values[key]].sort((a,b)=>a.localeCompare(b,'zh-CN')).forEach(value=>{const option=document.createElement('option');option.value=value;list.appendChild(option)})})}
    function presetRow(item){const preset=sourceOf(item),material=text(preset.material)||'未标注材料',row=create('article','preset-row'),main=create('div','preset-row-main'),topline=create('div','preset-topline');topline.appendChild(create('span','preset-material',material));const scene=text(preset.scene);if(scene)topline.appendChild(create('span','',scene));const owner=item&&item.owner?text(item.owner.displayName)||text(item.owner.handle):'';if(owner)topline.appendChild(create('span','',owner));main.appendChild(topline);main.appendChild(create('h3','',text(preset.name)||'未命名参数'));const description=text(preset.description);if(description)main.appendChild(create('p','',description));const meta=create('ul','preset-meta'),printers=listOf(preset.compatiblePrinters);if(printers.length)meta.appendChild(create('li','',printers.join('、')));meta.appendChild(create('li','',numberOf(item.applicationCount||item.downloads)+' 次应用'));meta.appendChild(create('li','',numberOf(item.likes)+' 个赞'));meta.appendChild(create('li','',dateOf(item.publishedAt||item.updatedAt)));main.appendChild(meta);const tags=listOf(preset.tags).slice(0,5);if(tags.length){const tagList=create('div','preset-tags');tags.forEach(tag=>tagList.appendChild(create('span','preset-tag',tag)));main.appendChild(tagList)}row.appendChild(main);const button=create('button','preset-action');button.type='button';button.setAttribute('aria-label','查看参数详情');button.innerHTML='<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 12h14M13 6l6 6-6 6"/></svg>';button.addEventListener('click',()=>showDetail(item));row.appendChild(button);return row}
    function renderItems(){clear(results);if(!state.items.length){const filtered=Object.entries(currentFilters()).some(([key,value])=>key!=='sort'&&value);setState(filtered?'没有找到匹配的参数':'还没有公开参数',filtered?'换一个关键词，或清除筛选再试试。':'在桌面软件中发布参数并设为公开后，会显示在这里。');return}state.items.forEach(item=>results.appendChild(presetRow(item)))}
    function renderDetail(item){const preset=sourceOf(item),owner=item&&item.owner?text(item.owner.displayName)||text(item.owner.handle):'';dialogKicker.textContent=[text(preset.material),text(preset.scene)].filter(Boolean).join(' / ')||'公开参数';dialogTitle.textContent=text(preset.name)||'未命名参数';dialogDescription.textContent=text(preset.description)||'发布者没有补充说明。';clear(dialogTags);listOf(preset.tags).forEach(tag=>dialogTags.appendChild(create('span','preset-tag',tag)));clear(dialogDetails);[['发布者',owner||'未标注'],['适配机型',listOf(preset.compatiblePrinters).join('、')||'未标注'],['应用次数',numberOf(item.applicationCount||item.downloads)+' 次'],['发布时间',dateOf(item.publishedAt||item.updatedAt)]].forEach(([label,value])=>{const line=create('div');line.appendChild(create('span','',label));line.appendChild(create('strong','',value));dialogDetails.appendChild(line)})}
    async function showDetail(initial){renderDetail(initial);if(typeof dialog.showModal==='function'&&!dialog.open)dialog.showModal();const id=text(initial&&initial.id);if(!id)return;try{const response=await fetch('/api/presets/'+encodeURIComponent(id),{headers:{Accept:'application/json'}});if(response.ok)renderDetail(await response.json())}catch{}}
    async function load({append=false}={}){if(state.controller)state.controller.abort();const filters=currentFilters(),params=new URLSearchParams();Object.entries(filters).forEach(([key,value])=>{if(value)params.set(key,value)});params.set('limit','20');if(append&&state.nextCursor)params.set('cursor',state.nextCursor);state.controller=new AbortController();const controller=state.controller;results.setAttribute('aria-busy','true');moreButton.hidden=true;status.textContent='正在读取...';if(!append)setState('正在读取','正在获取公开参数。');try{const response=await fetch('/api/presets?'+params.toString(),{headers:{Accept:'application/json'},signal:controller.signal});if(!response.ok)throw new Error('request failed');const data=await response.json();if(controller!==state.controller)return;const incoming=Array.isArray(data.items)?data.items:[];state.items=append?state.items.concat(incoming):incoming;state.nextCursor=typeof data.nextCursor==='string'&&data.nextCursor?data.nextCursor:null;renderItems();updateOptions(state.items);status.textContent=state.items.length?'已显示 '+state.items.length+' 条':'暂无结果';moreButton.hidden=!state.nextCursor;setUrl(filters)}catch(error){if(error.name==='AbortError')return;state.items=[];state.nextCursor=null;setState('暂时无法读取参数','社区服务暂时没有响应，请稍后重试。',true);status.textContent='读取失败'}finally{if(controller===state.controller)results.setAttribute('aria-busy','false')}}
    const query=new URLSearchParams(location.search);['q','material','scene','printer'].forEach(key=>{if(query.has(key))fields[key].value=query.get(key).slice(0,fields[key].maxLength||120)});if(query.has('sort')&&[...fields.sort.options].some(option=>option.value===query.get('sort')))fields.sort.value=query.get('sort');form.addEventListener('submit',event=>{event.preventDefault();load()});fields.sort.addEventListener('change',()=>load());document.getElementById('resetFilters').addEventListener('click',()=>{form.reset();load()});moreButton.addEventListener('click',()=>load({append:true}));document.getElementById('dialogClose').addEventListener('click',()=>dialog.close());dialog.addEventListener('click',event=>{if(event.target===dialog)dialog.close()});load()
  })();
  </script>
</body></html>`;
}
