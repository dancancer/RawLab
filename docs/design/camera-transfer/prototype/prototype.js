// 设计原型只操作内存中的示例状态，不访问相机、文件系统或凭据存储。
const icons = {
  camera: 'M3 7h4l2-3h6l2 3h4v13H3zM16 13a4 4 0 1 1-8 0 4 4 0 0 1 8 0',
  wifi: 'M3 8a15 15 0 0 1 18 0M6 12a10 10 0 0 1 12 0M9 16a5 5 0 0 1 6 0M12 20h.01',
  folder: 'M3 6h6l2 2h10v12H3z',
  calendar: 'M4 5h16v16H4zM4 10h16M8 3v4M16 3v4',
  check: 'm5 12 4 4L19 6',
  close: 'm6 6 12 12M18 6 6 18',
  search: 'M17 10a7 7 0 1 1-14 0 7 7 0 0 1 14 0m-2 5 6 6',
  refresh: 'M20 8a8 8 0 0 0-14-3L3 8m0-5v5h5M4 16a8 8 0 0 0 14 3l3-3m0 5v-5h-5',
  info: 'M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0M12 11v6m0-10h.01',
  arrow: 'M5 12h14m-5-5 5 5-5 5',
  left: 'm14 5-7 7 7 7',
  right: 'm10 5 7 7-7 7',
  down: 'm6 9 6 6 6-6',
  sort: 'M7 4v16m-3-3 3 3 3-3M17 20V4m-3 3 3-3 3 3',
  download: 'M12 3v12m-4-4 4 4 4-4M4 17v4h16v-4',
  photo: 'M3 4h18v16H3zM4 16l5-5 4 4 3-3 4 4M16 8h.01',
  warning: 'm12 3 10 18H2zM12 9v5m0 3h.01',
  clock: 'M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0M12 7v5l3 2',
  lock: 'M5 10h14v11H5zM8 10V7a4 4 0 0 1 8 0v3',
  grid: 'M3 3h7v7H3zM14 3h7v7h-7zM3 14h7v7H3zM14 14h7v7h-7z',
  edit: 'm4 16 12-12 4 4L8 20H4zM13 7l4 4',
  eye: 'M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12m13 0a3 3 0 1 1-6 0 3 3 0 0 1 6 0',
};
const icon = (name) => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${icons[name] || icons.photo}"/></svg>`;
const esc = (s) => String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const dates = ['2026-11-08', '2026-11-07', '2026-11-06'];
const sizes = [46.3, 41.8, 48.6, 39.2, 42.7, 45.8, 38.1, 44.5, 12.4, 11.6, 37.9, 43.2];
const photos = sizes.map((size, i) => ({
  id: i + 1,
  name: `DSC${String(4101 + i).padStart(5, '0')}.${i === 8 || i === 9 ? 'HIF' : 'ARW'}`,
  format: i === 8 || i === 9 ? 'HEIF' : 'RAW',
  size,
  date: dates[i < 6 ? 0 : i < 10 ? 1 : 2],
  time: `${i < 6 ? '16' : '09'}:${String(48-i*2).padStart(2,'0')}:12`,
  image: `assets/landscape-${(i % 6) + 1}.jpg`,
}));
const app = document.querySelector('#app');
const preview = document.querySelector('#preview-dialog');
const guard = document.querySelector('#guard-dialog');
const scenario = document.querySelector('#scenario');
const cameraPopover = document.querySelector('#camera-popover');
const state = {
  view: 'browse', phase: 'idle', connectionStep: 'address', connected: true,
  selected: new Set([1, 3, 5]), local: new Set([8]), date: 'all', format: 'RAW', query: '',
  onlySelected: false, newest: true, queue: [], taskOpen: false, lastSelected: null,
  previewID: null, editorID: 1, editorItems: [], thumbMissing: false, empty: false,
  storageLow: false, draft: false, progress: 0,
};
let timer;
let toastTimer;
let beforeDoubleClick;
let lastPhotoClick = {id:null, time:0};
const getPhoto = id => photos.find(p => p.id === Number(id));
const sum = items => items.reduce((n, p) => n + p.size, 0);
const mb = n => `${n.toFixed(1)} MB`;
const dateLabel = date => `${Number(date.slice(5,7))} 月 ${Number(date.slice(8))} 日`;

function filteredPhotos() {
  if (state.empty) return [];
  return photos.filter(p => (state.onlySelected || state.date === 'all' || p.date === state.date)
    && (state.onlySelected || state.format === 'all' || p.format === state.format)
    && (state.onlySelected ? state.selected.has(p.id) : p.name.toLowerCase().includes(state.query.toLowerCase())))
    .sort((a,b) => (a.date+a.time).localeCompare(b.date+b.time) * (state.newest ? -1 : 1));
}

function titlebar(title = '从相机导入') {
  return `<header class="titlebar">
    <div class="window-controls"><button class="close" data-action="hide-window" aria-label="关闭导入窗口，返回编辑器"></button><span class="dot" aria-hidden="true"></span><span class="dot" aria-hidden="true"></span></div>
    <div class="titlebar-title">${icon(state.view === 'editor' ? 'edit' : 'camera')}<span>${title}</span></div>
    <div class="titlebar-end">${state.view === 'browse' || state.view === 'records' ? `<button class="camera-details" data-action="details">${icon('info')}相机详情</button>` : ''}${state.view === 'editor' || state.view === 'collection' ? `<button class="secondary" data-action="return-import">${icon('camera')}${state.phase === 'running' ? '正在导入' : '相机导入'}</button>` : ''}</div>
  </header>`;
}

function sidebar() {
  return `<aside class="sidebar" aria-label="相机与日期">
    <div class="nav-group"><p class="sidebar-label">设备</p>
      <div class="device-row">${icon('camera')}<div><strong>α7C II</strong><small>${icon('wifi')}${state.connected ? '已连接 · 存储卡 1' : '连接已断开'}</small></div></div>
      <button class="nav-row ${state.view==='browse'&&state.date==='all'?'active':''}" data-action="date" data-date="all">${icon('grid')}相机中的照片<span class="count">12</span></button>
    </div>
    <div class="nav-group"><p class="sidebar-label">拍摄日期</p>
      ${dates.map(d => `<button class="nav-row ${state.date===d&&state.view==='browse'?'active':''}" data-action="date" data-date="${d}">${icon('calendar')}${dateLabel(d)}<span class="count">${photos.filter(p=>p.date===d).length}</span></button>`).join('')}
    </div>
    <div class="nav-group"><p class="sidebar-label">本机</p><button class="nav-row ${state.view==='records'?'active':''}" data-action="records">${icon('folder')}导入记录<span class="count">${state.local.size}</span></button></div>
    <div class="sidebar-bottom"><p>${icon('lock')}原照片保留在相机中</p><button data-action="connection-settings">连接设置…</button></div>
  </aside>`;
}

function photoCard(p) {
  const selected = state.selected.has(p.id);
  return `<div class="photo-card ${selected?'selected':''}" tabindex="0" role="button" aria-pressed="${selected}" aria-label="${p.name}，${p.format}，${mb(p.size)}${state.local.has(p.id)?'，已导入':''}" data-photo="${p.id}">
    <div class="photo-frame">${state.thumbMissing&&p.id===2 ? `<div class="no-preview">${icon('photo')}<span>预览不可用</span></div>` : `<img src="${p.image}" alt="山林与湖泊的示例照片" draggable="false">`}
      <span class="select-mark" aria-hidden="true">${icon('check')}</span>
      ${state.local.has(p.id)?`<span class="local-mark">${icon('check')}已导入</span>`:''}
    </div>
    <div class="photo-caption"><strong>${p.name}</strong><span>${p.format}</span></div>
    <p class="photo-detail">${p.time.slice(0,5)} · ${mb(p.size)}</p>
  </div>`;
}

function gallery() {
  const items = filteredPhotos();
  if (!items.length) return `<div class="empty">${icon(state.empty?'camera':'search')}<h2>${state.empty?'相机中还没有照片':'没有符合条件的照片'}</h2><p>${state.empty?'拍摄后点击刷新，即可在这里挑选并导入。':'换一个日期或文件类型，已选中的照片仍然保留。'}</p><button class="secondary" data-action="${state.empty?'refresh':'clear-filters'}">${icon('refresh')}${state.empty?'刷新照片':'清除筛选'}</button></div>`;
  return `<div class="gallery" id="gallery">${[...new Set(items.map(p=>p.date))].map(date => {
    const group=items.filter(p=>p.date===date);
    return `<section><div class="day-label"><h3>${dateLabel(date)}<span> · ${date===dates[0]?'今天':date===dates[1]?'昨天':'前天'}</span></h3><span>${group.length} 张</span></div><div class="photo-grid">${group.map(photoCard).join('')}</div></section>`;
  }).join('')}</div>`;
}

function banner() {
  if (!state.connected) return `<div class="banner" role="status">${icon('wifi')}<div><strong>与相机的连接已断开</strong><p>已导入的照片保留在本机。让相机保持唤醒，然后重新连接。</p></div></div>`;
  if (state.storageLow) return `<div class="banner error" role="status">${icon('warning')}<div><strong>本机空间不足，暂时无法导入</strong><p>还需要约 100 MB。释放空间或更改保存位置后，选片结果仍然保留。</p><button class="text" data-action="change-location">更改保存位置…</button></div></div>`;
  return '';
}

function browser() {
  const items=filteredPhotos();
  const title=state.onlySelected?'已选照片':state.date==='all'?'最近拍摄':dateLabel(state.date);
  return `${titlebar()}<div class="layout ${state.taskOpen?'has-task':''}">${sidebar()}<main class="browser">
    <div class="browse-heading"><div><h2>${title}</h2><p>${items.length} 张${state.format==='RAW'&&!state.onlySelected?' RAW':''} · α7C II</p></div>
      <div class="tools"><label class="search">${icon('search')}<input id="search" type="search" aria-label="搜索文件名" placeholder="搜索文件名" value="${esc(state.query)}" ${state.onlySelected?'disabled':''}></label><button class="icon" data-action="refresh" title="刷新照片" aria-label="刷新照片">${icon('refresh')}</button></div>
    </div>
    <div class="filters"><select id="format" aria-label="文件类型" ${state.onlySelected?'disabled':''}><option value="all" ${state.format==='all'?'selected':''}>所有格式</option><option value="RAW" ${state.format==='RAW'?'selected':''}>RAW</option><option value="HEIF" ${state.format==='HEIF'?'selected':''}>HEIF</option></select>
      <select class="date-filter" id="date-filter" aria-label="拍摄日期"><option value="all">全部日期</option>${dates.map(d=>`<option value="${d}" ${state.date===d?'selected':''}>${dateLabel(d)}</option>`).join('')}</select>
      <button class="filter-selected" data-action="selected" aria-pressed="${state.onlySelected}">查看已选${state.selected.size?` · ${state.selected.size}`:''}</button>
      <button class="sort" data-action="sort">${icon('sort')}${state.newest?'最新在前':'最早在前'}</button>
    </div>
    ${banner()}${gallery()}</main>${state.taskOpen?taskPane():''}</div>${footer()}`;
}

function records() {
  const items=photos.filter(p=>state.local.has(p.id));
  return `${titlebar()}<div class="layout">${sidebar()}<main class="browser"><div class="browse-heading"><div><h2>导入记录</h2><p>已保存在本机 · 无需连接相机</p></div><button class="text" data-action="show-folder">${icon('folder')}在 Finder 中显示</button></div>
    <div class="gallery records-list">${items.map(p=>`<article class="record-row"><img src="${p.image}" alt=""><div><strong>${p.name}</strong><p>${p.format} · ${mb(p.size)} · 来自 α7C II</p></div><button class="secondary" data-action="open-one" data-id="${p.id}">${icon('edit')}打开编辑</button></article>`).join('')}</div></main></div>
    <div class="import-footer"><div class="footer-main"><strong>${items.length} 张原文件保存在本机</strong><div class="sub">重新打开照片会恢复原有调整。</div></div><button class="secondary" data-action="browse">返回相机照片</button></div>`;
}

function taskPane() {
  const names={pending:'等待导入',running:'正在导入',saved:'已保存',failed:'连接中断，尚未完成',reused:'已在本机'};
  return `<aside class="task-pane" aria-label="逐张导入进度"><div class="task-head"><h3>本次导入</h3><button class="icon" data-action="task" aria-label="收起任务详情">${icon('close')}</button></div><div class="task-list">${state.queue.map(item=>{
    const p=getPhoto(item.id);
    return `<div class="task-item ${item.status==='failed'?'failed':''}"><img src="${p.image}" alt=""><div><strong>${p.name}</strong><p>${names[item.status]}</p></div><span class="status-icon">${item.status==='running'?'<span class="spinner"></span>':icon(item.status==='saved'||item.status==='reused'?'check':item.status==='failed'?'warning':'clock')}</span></div>`;
  }).join('')}</div><p class="task-tip">${state.phase==='running'?'关闭此窗口后，导入仍会继续。相机中的照片不会删除。':'成功项已保留。重试只处理未完成的照片。'}</p></aside>`;
}

function completed() { return state.queue.filter(q=>q.status==='saved'||q.status==='reused'); }
function footer() {
  const picked=photos.filter(p=>state.selected.has(p.id));
  const done=completed();
  let content;
  if (state.phase==='running') {
    const active=state.queue.find(q=>q.status==='running');
    const total=sum(state.queue.map(q=>getPhoto(q.id)));
    const received=sum(done.map(q=>getPhoto(q.id)))+(active?getPhoto(active.id).size*state.progress:0);
    content=`<div class="footer-main"><div class="footer-count"><strong>正在导入 ${Math.min(done.length+1,state.queue.length)} / ${state.queue.length}</strong><span class="mono" id="byte-count">${mb(received)} / ${mb(total)}</span></div><div class="progress-track" role="progressbar" aria-label="本次导入字节进度" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${Math.round(received/total*100)}"><div class="progress-fill" style="width:${received/total*100}%"></div></div><div class="sub">${active?getPhoto(active.id).name:'正在完成保存'} · 已保存 ${done.length} 张</div></div><div class="footer-actions"><button class="text" data-action="task">${state.taskOpen?'收起详情':'查看任务'}</button><button class="secondary" data-action="stop">停止导入</button></div>`;
  } else if (state.phase==='interrupted'||state.phase==='stopped') {
    const remaining=state.queue.length-done.length;
    content=`<div class="footer-main"><strong>${state.phase==='stopped'?'已停止导入':'导入已中断'} · ${done.length} 张照片已保留</strong><div class="sub">剩余 ${remaining} 张未完成，继续时不会重下成功项。</div></div><div class="footer-actions">${done.length?'<button class="text" data-action="handoff">编辑已导入照片</button>':''}<button class="primary" data-action="resume">${state.connected?'继续未完成':'重新连接并继续'}</button></div>`;
  } else if (state.phase==='partial') {
    content=`<div class="footer-main"><div class="footer-count">${icon('warning')}<strong>已导入 ${done.length} 张，${state.queue.length-done.length} 张未完成</strong></div><div class="sub">已保存的照片可以先编辑，失败项可单独重试。</div></div><div class="footer-actions"><button class="text" data-action="handoff">编辑已导入照片</button><button class="primary" data-action="resume">重试未完成</button></div>`;
  } else if (state.phase==='complete') {
    content=`<div class="footer-main"><div class="footer-count">${icon('check')}<strong>已导入 ${done.length} 张照片</strong></div><div class="sub">原文件已保存在本机，相机中的照片仍然保留。</div></div><div class="footer-actions"><button class="text" data-action="continue-selecting">继续选片</button><button class="primary" data-action="handoff">${icon(done.length===1?'edit':'grid')}${done.length===1?'打开编辑':'加入选片集合'}</button></div>`;
  } else {
    const hidden=picked.length-filteredPhotos().filter(p=>state.selected.has(p.id)).length;
    content=`<div class="footer-main"><div class="footer-count"><strong>${picked.length?`已选 ${picked.length} 张`:'选择要导入的照片'}</strong>${picked.length?`<span class="mono">${mb(sum(picked))}</span>`:''}</div><div class="sub">${hidden>0?`其中 ${hidden} 张不在当前筛选中 · `:''}<button data-action="show-folder">${icon('folder')}保存到 RawLab 相机导入</button></div></div><div class="footer-actions"><button class="text" data-action="clear" ${picked.length?'':'disabled'}>清空选择</button><button class="primary" data-action="import" ${picked.length&&!state.storageLow?'':'disabled'}>${icon('download')}${!state.connected?'重新连接':picked.length?`导入 ${picked.length} 张`:'导入照片'}</button></div>`;
  }
  return `<footer class="import-footer" id="import-footer">${content}</footer>`;
}

function connection() {
  const auth=state.connectionStep==='auth';
  const busy=state.connectionStep==='finding'||state.connectionStep==='authenticating';
  return `${titlebar()}<div class="connect-layout"><section class="connect-intro">${icon('camera')}<h1>连接你的 Sony 相机</h1><p>从存储卡挑选照片，直接带进 RawLab 编辑。</p><ol class="setup-steps"><li>让相机与 Mac 连接到同一 Wi-Fi。</li><li>在相机上开启「PC 遥控」。</li><li>保持相机唤醒，并结束其他应用的相机连接。</li></ol><details><summary>相机上怎么设置</summary><p>网络 → 连接/PC 遥控 → PC 遥控功能。<br>认证信息位于：网络 → 网络选项 → 访问认证信息。</p></details></section>
    <form class="connection-form ${auth?'authentication':''}" id="connection-form"><h2>${auth?'α7C II 访问认证':busy?'正在连接…':'添加相机'}</h2><p>${auth?'192.168.1.100 · 输入相机显示的认证信息。':'使用相机网络设置中显示的 IP 地址。'}</p>
      ${busy?`<div class="connected-name"><span class="spinner"></span>正在${state.connectionStep==='finding'?'查找相机':'验证连接'}…</div><div class="form-actions"><button type="button" class="secondary" data-action="cancel-connect">取消</button></div>`:auth?`
      <label class="field">用户名<input id="camera-user" autocomplete="off" value="camera" required></label>
      <label class="field">密码<div class="password-wrap"><input id="camera-password" type="password" autocomplete="off" value="demo-only" required><button type="button" class="icon secondary" data-action="show-password" aria-label="显示或隐藏密码">${icon('eye')}</button></div></label>
      <div class="field">相机指纹<div class="fingerprint">SHA256:7x9iB2kL4mN6pQ8rS0tU2vW4yZ6aC8dE0fG2hI4jK6L</div><p class="form-help">请与相机屏幕上的指纹完整核对。</p></div>
      <label class="checkbox-row"><input id="trust-camera" type="checkbox">与相机上显示的指纹一致</label>
      <label class="checkbox-row"><input type="checkbox" id="remember-camera">记住密码，保存在钥匙串</label>
      <div class="form-actions"><button type="button" class="text" data-action="back-address">返回</button><button class="primary" type="submit" id="connect-submit" disabled>连接相机</button></div>`:`
      <label class="field">相机 IP 地址<input id="camera-address" inputmode="decimal" value="192.168.1.100" placeholder="例如 192.168.1.100" required></label><p class="form-help">首次连接需要核对相机身份，之后可使用最近连接的相机。</p><div class="form-actions"><button type="button" class="text" data-action="browse">取消</button><button class="primary" type="submit">查找相机${icon('arrow')}</button></div>`}
    </form></div><div class="connect-footer">${icon('lock')}照片只保存到本机。连接相机不会更改拍摄设置。</div>`;
}

function editor() {
  const ids=state.editorItems.length?state.editorItems:[1,3,5];
  const p=getPhoto(state.editorID)||getPhoto(ids[0]);
  return `${titlebar('RawLab · 编辑')}<div class="editor-layout"><aside class="editor-filmstrip"><h3>${state.editorItems.length?'本次相机导入':'当前选片'}</h3>${ids.map(id=>{const item=getPhoto(id);return `<button class="editor-thumb ${p.id===id?'active':''}" data-action="editor-photo" data-id="${id}"><img src="${item.image}" alt=""><span>${item.name}</span></button>`;}).join('')}</aside><main class="editor-canvas"><img id="editing-photo" src="${p.image}" alt="正在编辑的示例照片"><div class="editor-info"><strong>${p.name}</strong><br>7008 × 4672 · RAW</div></main><aside class="editor-inspector"><h3>调整</h3><p class="editor-toolbar-label">光线</p>${[['exposure','曝光','0.00','-4','4','.1'],['contrast','对比度','0','-100','100','1'],['shadows','阴影','0','-100','100','1']].map(([id,name,value,min,max,step])=>`<div class="adjustment"><label for="${id}">${name}<output id="${id}-value">${value}</output></label><input id="${id}" type="range" min="${min}" max="${max}" step="${step}" value="0"></div>`).join('')}<p class="handoff-note">原件已在本机，编辑无需保持相机连接。<br>多张照片交给已有选片集合继续处理。</p></aside></div><div class="import-footer"><div class="footer-main"><strong>${p.name}</strong><div class="sub">${state.phase==='running'?'相机导入仍在后台进行。':'此处演示已保存照片进入编辑器的交接。'}</div></div><button class="secondary" data-action="return-import">返回相机导入</button></div>`;
}

function collection() {
  const items=state.editorItems.map(getPhoto);
  return `${titlebar('RawLab · 选片集合')}<main class="browser"><div class="browse-heading"><div><h2>相机导入的照片</h2><p>${items.length} 张照片已加入选片集合 · 来自 α7C II</p></div></div><p class="state-caption">继续使用现有选片集合。打开单张照片进行调整，或稍后统一处理。</p><div class="gallery records-list">${items.map(p=>`<article class="record-row"><img src="${p.image}" alt=""><div><strong>${p.name}</strong><p>${p.format} · ${mb(p.size)} · 已保存在本机</p></div><button class="secondary" data-action="edit-collection-photo" data-id="${p.id}">${icon('edit')}单张微调</button></article>`).join('')}</div></main><footer class="import-footer"><div class="footer-main"><strong>${items.length} 张照片可以离线编辑</strong><div class="sub">此页演示接入已有集合，不创建另一套相册。</div></div><button class="secondary" data-action="return-import">返回相机导入</button></footer>`;
}

function render() {
  const active=document.activeElement;
  const focusID=active?.id;
  const photoFocus=active?.dataset.photo;
  const inputPosition=active?.selectionStart;
  const scroll=document.querySelector('#gallery')?.scrollTop||0;
  app.innerHTML=state.view==='connect'?connection():state.view==='records'?records():state.view==='editor'?editor():state.view==='collection'?collection():browser();
  const galleryElement=document.querySelector('#gallery');
  if(galleryElement)galleryElement.scrollTop=scroll;
  const restore=focusID?document.getElementById(focusID):photoFocus?document.querySelector(`[data-photo="${photoFocus}"]`):null;
  if(restore){restore.focus({preventScroll:true});if(typeof inputPosition==='number'&&restore.type==='search')restore.setSelectionRange(inputPosition,inputPosition);}
}

function notify(message) {
  const toast=document.querySelector('#toast');
  clearTimeout(toastTimer);toast.textContent=message;toast.classList.add('visible');
  toastTimer=setTimeout(()=>toast.classList.remove('visible'),3200);
}

function togglePhoto(id, extend=false) {
  if(state.phase==='running'){notify('导入过程中可以预览照片，完成后可继续选片。');return;}
  const items=filteredPhotos();
  if(extend&&state.lastSelected&&items.some(p=>p.id===state.lastSelected)){
    const indices=[items.findIndex(p=>p.id===id),items.findIndex(p=>p.id===state.lastSelected)].sort((a,b)=>a-b);
    items.slice(indices[0],indices[1]+1).forEach(p=>state.selected.add(p.id));
  }else if(state.selected.has(id)){state.selected.delete(id);}else{state.selected.add(id);}
  state.lastSelected=id;render();
}

function openPreview(id) {
  state.previewID=id;
  const p=getPhoto(id);
  preview.innerHTML=`<div class="preview-head"><strong>${p.name}</strong><button class="icon" data-preview="close" aria-label="关闭预览">${icon('close')}</button></div><div class="preview-stage"><button class="icon previous" data-preview="previous" aria-label="上一张">${icon('left')}</button>${state.thumbMissing&&id===2?`<div class="no-preview">${icon('photo')}<p>相机预览不可用，仍可导入原文件。</p></div>`:`<img src="${p.image}" alt="照片大图预览">`}<button class="icon next" data-preview="next" aria-label="下一张">${icon('right')}</button></div><div class="preview-bottom"><div><p>${p.format} · ${mb(p.size)} · ${dateLabel(p.date)} ${p.time.slice(0,5)}</p><small>相机预览 · 编辑时使用完整原文件</small></div><button class="${state.selected.has(id)?'secondary':'primary'}" data-preview="toggle">${icon(state.selected.has(id)?'check':'download')}${state.selected.has(id)?'取消选中':'选中照片'}</button></div>`;
  if(!preview.open)preview.showModal();
}

function movePreview(direction) {
  const items=filteredPhotos();
  const index=items.findIndex(p=>p.id===state.previewID);
  openPreview(items[(index+direction+items.length)%items.length].id);
}

function stopTimer(){clearInterval(timer);timer=null;}
function startTransfer(resume=false) {
  if(!resume){
    state.queue=photos.filter(p=>state.selected.has(p.id)).map(p=>({id:p.id,status:state.local.has(p.id)?'reused':'pending'}));
  }
  if(!state.queue.length)return;
  state.queue.forEach(q=>{if(q.status==='failed'||q.status==='running')q.status='pending';});
  state.connected=true;state.phase='running';state.progress=0;state.taskOpen=false;state.view='browse';
  stopTimer();
  advanceQueue();render();
  timer=setInterval(()=>{
    if(state.phase!=='running'){stopTimer();return;}
    state.progress=Math.min(1,state.progress+.11);
    if(state.progress>=1){
      const active=state.queue.find(q=>q.status==='running');
      if(active){active.status='saved';state.local.add(active.id);}
      state.progress=0;advanceQueue();render();
    }else if(state.view==='browse'){
      document.querySelector('#import-footer').outerHTML=footer();
    }
  },300);
}

function advanceQueue(){
  const next=state.queue.find(q=>q.status==='pending');
  if(next){next.status='running';}else{state.phase='complete';stopTimer();}
}

function handoff(){
  const ids=completed().map(q=>q.id);
  if(!ids.length)return;
  if(state.draft){
    guard.innerHTML=`<div class="guard-content"><h2>应用当前照片的调整？</h2><p>当前照片还有未应用的几何调整。相机照片已经保存，可以稍后打开。</p><div class="guard-actions"><button class="primary" data-guard="apply">应用并打开导入照片</button><button class="secondary" data-guard="discard">放弃调整并打开</button><button data-guard="stay">继续编辑当前照片</button></div></div>`;
    guard.showModal();return;
  }
  state.editorItems=ids;state.editorID=ids[0];state.view=ids.length>1?'collection':'editor';render();
  notify(ids.length===1?'已打开导入照片':'已加入选片集合，可逐张编辑');
}

const actions={
  clear(){state.selected.clear();render();},
  selected(){state.onlySelected=!state.onlySelected;render();},
  sort(){state.newest=!state.newest;render();},
  date(el){state.date=el.dataset.date;state.onlySelected=false;state.view='browse';render();},
  records(){state.view='records';render();},
  browse(){state.view='browse';render();},
  'clear-filters'(){state.date='all';state.format='all';state.query='';state.onlySelected=false;render();},
  refresh(){notify(state.connected?'照片列表已刷新，选片结果已保留。':'相机未连接，请先重新连接。');},
  details(){cameraPopover.innerHTML=`<h3>α7C II</h3><dl><dt>连接</dt><dd>${state.connected?'Wi-Fi · 已连接':'已断开'}</dd><dt>型号</dt><dd>ILCE-7CM2</dd><dt>固件</dt><dd>2.00</dd><dt>地址</dt><dd>192.168.1.100</dd></dl><button class="secondary" id="popover-settings">连接设置…</button>`;cameraPopover.showPopover();},
  'show-folder'(){notify('保存位置：RawLab / CameraImports。原型不打开本机目录。');},
  'change-location'(){state.storageLow=false;render();notify('已模拟更改保存位置，可以继续导入。');},
  'connection-settings'(){if(state.phase==='running'){notify('导入正在进行；停止导入后可以更改连接。');return;}state.view='connect';state.connectionStep='address';render();},
  'back-address'(){state.connectionStep='address';render();},
  'cancel-connect'(){state.connectionStep='address';render();},
  'show-password'(){const input=document.querySelector('#camera-password');input.type=input.type==='password'?'text':'password';},
  import(){if(!state.connected){state.connected=true;render();notify('相机已重新连接，选片结果已保留。');return;}startTransfer();},
  task(){state.taskOpen=!state.taskOpen;render();},
  stop(){stopTimer();state.phase='stopped';state.queue.forEach(q=>{if(q.status==='running')q.status='pending';});state.progress=0;render();},
  resume(){state.connected=true;startTransfer(true);},
  handoff,
  'continue-selecting'(){state.phase='idle';state.queue=[];state.selected.clear();state.taskOpen=false;render();},
  'hide-window'(){state.view='editor';state.editorItems=[];state.editorID=1;render();},
  'return-import'(){state.view='browse';render();},
  'editor-photo'(el){state.editorID=Number(el.dataset.id);render();},
  'edit-collection-photo'(el){state.editorID=Number(el.dataset.id);state.view='editor';render();},
  'open-one'(el){state.editorID=Number(el.dataset.id);state.editorItems=[state.editorID];state.view='editor';render();},
};

cameraPopover.addEventListener('click',event=>{
  if(event.target.closest('#popover-settings')){cameraPopover.hidePopover();actions['connection-settings']();}
});

app.addEventListener('click',event=>{
  const action=event.target.closest('[data-action]');
  if(action){actions[action.dataset.action]?.(action);return;}
  const card=event.target.closest('[data-photo]');
  if(card){
    const id=Number(card.dataset.photo);
    const now=performance.now();
    if(lastPhotoClick.id===id&&now-lastPhotoClick.time<350){
      if(beforeDoubleClick)state.selected=new Set(beforeDoubleClick);
      lastPhotoClick={id:null,time:0};render();openPreview(id);
    }else{
      beforeDoubleClick=new Set(state.selected);lastPhotoClick={id,time:now};togglePhoto(id,event.shiftKey);
    }
  }
});
app.addEventListener('input',event=>{
  if(event.target.id==='search'){state.query=event.target.value;render();}
  if(event.target.id==='camera-address')event.target.setCustomValidity('');
  if(['exposure','contrast','shadows'].includes(event.target.id)){
    const n=Number(event.target.value);document.querySelector(`#${event.target.id}-value`).textContent=(n>0?'+':'')+(event.target.id==='exposure'?n.toFixed(2):n);
    if(event.target.id==='exposure')document.querySelector('#editing-photo').style.filter=`brightness(${Math.pow(2,n*.35)})`;
  }
});
app.addEventListener('change',event=>{
  if(event.target.id==='format'){state.format=event.target.value;render();}
  if(event.target.id==='date-filter'){state.date=event.target.value;render();}
  if(event.target.id==='trust-camera')document.querySelector('#connect-submit').disabled=!event.target.checked;
});
app.addEventListener('submit',event=>{
  event.preventDefault();
  if(state.connectionStep==='address'){
    const address=document.querySelector('#camera-address');
    if(!/^\d{1,3}(\.\d{1,3}){3}$/.test(address.value)){address.setCustomValidity('请输入相机显示的 IP 地址。');address.reportValidity();return;}
    state.connectionStep='finding';render();setTimeout(()=>{if(state.connectionStep==='finding'){state.connectionStep='auth';render();}},800);
  }else if(state.connectionStep==='auth'){
    state.connectionStep='authenticating';render();setTimeout(()=>{if(state.connectionStep==='authenticating'){state.view='browse';state.phase='idle';state.connected=true;state.selected.clear();render();}},900);
  }
});
preview.addEventListener('click',event=>{
  const button=event.target.closest('[data-preview]');
  if(!button)return;
  switch(button.dataset.preview){
    case 'close':preview.close();break;
    case 'next':movePreview(1);break;
    case 'previous':movePreview(-1);break;
    case 'toggle':togglePhoto(state.previewID);openPreview(state.previewID);break;
  }
});
preview.addEventListener('close',()=>document.querySelector(`[data-photo="${state.previewID}"]`)?.focus());
guard.addEventListener('click',event=>{
  const button=event.target.closest('[data-guard]');if(!button)return;
  guard.close();
  if(button.dataset.guard==='stay'){notify('继续编辑当前照片；导入文件已保留。');return;}
  state.draft=false;handoff();
});
document.addEventListener('keydown',event=>{
  if(preview.open){if(event.key==='ArrowRight'){event.preventDefault();movePreview(1);}if(event.key==='ArrowLeft'){event.preventDefault();movePreview(-1);}return;}
  if(guard.open||['INPUT','TEXTAREA','SELECT'].includes(event.target.tagName))return;
  if(state.view!=='browse')return;
  if((event.metaKey||event.ctrlKey)&&event.key.toLowerCase()==='a'){event.preventDefault();filteredPhotos().forEach(p=>state.selected.add(p.id));render();}
  if((event.metaKey||event.ctrlKey)&&event.key.toLowerCase()==='d'){event.preventDefault();state.selected.clear();render();}
  const card=event.target.closest('[data-photo]');
  if(!card)return;
  if(event.key===' '){event.preventDefault();openPreview(Number(card.dataset.photo));}
  if(event.key==='Enter'){event.preventDefault();togglePhoto(Number(card.dataset.photo),event.shiftKey);}
  if(event.key.startsWith('Arrow')){
    const items=filteredPhotos();const index=items.findIndex(p=>p.id===Number(card.dataset.photo));
    const columns=getComputedStyle(card.parentElement).gridTemplateColumns.split(' ').length;
    const step=event.key==='ArrowRight'?1:event.key==='ArrowLeft'?-1:event.key==='ArrowDown'?columns:-columns;
    const next=items[Math.max(0,Math.min(items.length-1,index+step))];event.preventDefault();document.querySelector(`[data-photo="${next.id}"]`)?.focus();
  }
});

function setScenario(name){
  stopTimer();if(preview.open)preview.close();if(guard.open)guard.close();
  Object.assign(state,{view:'browse',phase:'idle',connected:true,connectionStep:'address',date:'all',format:'RAW',query:'',onlySelected:false,thumbMissing:false,empty:false,storageLow:false,draft:false,taskOpen:false,queue:[],progress:0,editorItems:[],editorID:1});
  state.selected=new Set([1,3,5]);state.local=new Set([8]);scenario.value=name;
  if(name==='connect'){state.view='connect';state.selected.clear();}
  if(name==='thumbnail')state.thumbMissing=true;
  if(name==='empty'){state.empty=true;state.selected.clear();}
  if(name==='storage')state.storageLow=true;
  if(['offline','partial','complete','draft'].includes(name)){
    state.queue=[1,3,5].map((id,i)=>({id,status:(name==='complete'||name==='draft'||i<2)?'saved':'failed'}));
    completed().forEach(q=>state.local.add(q.id));
    state.phase=name==='offline'?'interrupted':name==='partial'?'partial':'complete';
    state.connected=name!=='offline';state.taskOpen=name==='partial';state.draft=name==='draft';
  }
  if(name==='transfer'){startTransfer();return;}
  render();
}
scenario.addEventListener('change',()=>setScenario(scenario.value));
const initial=new URLSearchParams(location.search).get('state');
setScenario([...scenario.options].some(o=>o.value===initial)?initial:'browse');
