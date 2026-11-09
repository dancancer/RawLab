// 原型状态完全位于内存中，不发起相机请求或保存凭据。
const mobileIcons = {
  camera: 'M3 7h4l2-3h6l2 3h4v13H3zM16 13a4 4 0 1 1-8 0 4 4 0 0 1 8 0',
  back: 'm14 5-7 7 7 7',
  arrowBack: 'M20 12H4m7-7-7 7 7 7',
  next: 'm10 5 7 7-7 7',
  more: 'M5 12h.01M12 12h.01M19 12h.01',
  moreVertical: 'M12 5v.01M12 12v.01M12 19v.01',
  down: 'm7 10 5 5 5-5',
  check: 'm5 12 4 4L19 6',
  close: 'm6 6 12 12M18 6 6 18',
  wifi: 'M3 8a15 15 0 0 1 18 0M6 12a10 10 0 0 1 12 0M9 16a5 5 0 0 1 6 0M12 20h.01',
  signal: 'M4 18v2M9 13v7M14 8v12M19 3v17',
  battery: 'M2 6h17v12H2zM22 10v4M5 9h11v6H5z',
  expand: 'M9 4H4v5M15 4h5v5M4 15v5h5m6 0h5v-5',
  folder: 'M3 6h6l2 2h10v12H3z',
  refresh: 'M20 8a8 8 0 0 0-14-3L3 8m0-5v5h5M4 16a8 8 0 0 0 14 3l3-3m0 5v-5h-5',
  download: 'M12 3v12m-4-4 4 4 4-4M4 17v4h16v-4',
  clock: 'M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0M12 7v5l3 2',
  warning: 'm12 3 10 18H2zM12 9v5m0 3h.01',
  lock: 'M5 10h14v11H5zM8 10V7a4 4 0 0 1 8 0v3',
  phone: 'M7 2h10v20H7zM11 18h2',
  photo: 'M3 4h18v16H3zM4 16l5-5 4 4 3-3 4 4M16 8h.01',
  grid: 'M3 3h7v7H3zM14 3h7v7h-7zM3 14h7v7H3zM14 14h7v7h-7z',
  edit: 'm4 16 12-12 4 4L8 20H4zM13 7l4 4',
};
const mi = name => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${mobileIcons[name] || mobileIcons.photo}"/></svg>`;
const escapeText = s => String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const photoSizes = [46.3,41.8,48.6,39.2,42.7,45.8,38.1,44.5,12.4,11.6,37.9,43.2];
const mobilePhotos = photoSizes.map((size,i) => ({
  id: i+1,
  name: `DSC${String(4101+i).padStart(5,'0')}.${i===8||i===9?'HIF':'ARW'}`,
  format: i===8||i===9?'HEIF':'RAW',
  size,
  date: i<6?'today':i<10?'yesterday':'earlier',
  image: `assets/landscape-${i%6+1}.jpg`,
}));
const mobilePhoto = id => mobilePhotos.find(p => p.id===Number(id));
const sizeText = n => `${n.toFixed(1)} MB`;
const totalSize = items => items.reduce((n,p)=>n+p.size,0);
const dateNames = {all:'全部日期',today:'今天 · 11 月 8 日',yesterday:'昨天 · 11 月 7 日',earlier:'11 月 6 日'};

class MobileCameraDemo {
  constructor(root,os) {
    this.root=root;
    this.os=os;
    this.timer=null;
    this.messageTimer=null;
    this.pointerStart=null;
    root.addEventListener('click',event=>{
      const action=event.target.closest('[data-action]');
      if(action&&!action.disabled)this.act(action.dataset.action,action.dataset);
    });
    root.addEventListener('submit',event=>{event.preventDefault();this.act('connect-next');});
    root.addEventListener('change',event=>{
      if(event.target.dataset.field==='trust'){this.state.trust=event.target.checked;this.render();}
    });
    root.addEventListener('input',event=>{
      const field=event.target.dataset.field;
      if(['address','user','password'].includes(field)){
        this.state[field]=event.target.value;
        this.state.formError='';
        const connectButton=root.querySelector('[data-action="connect-next"]');
        if(connectButton&&this.state.connectionStep==='auth')connectButton.disabled=!this.state.trust||!this.state.user.trim()||!this.state.password;
      }
      if(field==='exposure'){
        const n=Number(event.target.value);
        root.querySelector('[data-output="exposure"]').textContent=(n>0?'+':'')+n.toFixed(2)+' EV';
        root.querySelector('.editor-demo-photo').style.filter=`brightness(${Math.pow(2,n*.35)})`;
      }
    });
    root.addEventListener('keydown',event=>{
      if(event.key==='Escape'){event.preventDefault();this.back();}
      if(this.state.sheet&&event.key==='Tab'){
        const focusable=[...root.querySelectorAll('.mobile-sheet button:not(:disabled), .mobile-sheet input')];
        const first=focusable[0],last=focusable.at(-1);
        if(event.shiftKey&&document.activeElement===first){event.preventDefault();last?.focus();}
        if(!event.shiftKey&&document.activeElement===last){event.preventDefault();first?.focus();}
      }
    });
    root.addEventListener('pointerdown',event=>{
      const image=event.target.closest('.preview-image');
      if(image&&event.clientX-image.getBoundingClientRect().left>24){this.pointerStart={x:event.clientX,y:event.clientY};}
    });
    root.addEventListener('pointerup',event=>{
      if(this.pointerStart&&this.state.screen==='preview'){
        const dx=event.clientX-this.pointerStart.x,dy=event.clientY-this.pointerStart.y;
        if(Math.abs(dx)>60&&Math.abs(dx)>Math.abs(dy)*1.5)this.movePreview(dx<0?1:-1);
      }
      this.pointerStart=null;
    });
    root.addEventListener('pointercancel',()=>{this.pointerStart=null;});
    this.setScene('browse');
  }

  setScene(scene) {
    clearInterval(this.timer);
    clearTimeout(this.messageTimer);
    this.state={
      screen:'browse',phase:'idle',connected:true,selected:new Set([1,3,5]),local:new Set([8]),
      format:'RAW',date:'all',onlySelected:false,sheet:null,pending:null,queue:[],progress:0,
      previewID:1,previewOrigin:'browse',editorID:11,editorFrom:'browse',reason:'',message:'',
      connectionStep:'address',address:'192.168.1.100',user:'camera',password:'demo-only',
      trust:false,remember:false,formError:'',empty:false,hasDraft:false,collection:[],pendingOpen:null,
    };
    if(scene==='connect')this.state.screen='connect';
    if(scene==='empty'){this.state.empty=true;this.state.selected.clear();}
    if(scene==='restricted')this.state.screen='restricted';
    if(['transfer','background','offline','partial','complete','draft'].includes(scene)){
      this.state.queue=[1,3,5].map((id,i)=>({id,status:'pending'}));
      if(scene==='transfer'){
        this.state.phase='running';this.state.screen='transfer';this.state.progress=.42;
        this.state.queue[0].status='saved';this.state.queue[1].status='running';
      }else if(scene==='background'||scene==='offline'){
        this.state.phase='interrupted';this.state.screen='transfer';this.state.reason=scene;
        this.state.connected=false;this.state.queue[0].status='saved';
      }else if(scene==='partial'){
        this.state.phase='partial';this.state.screen='result';
        this.state.queue[0].status='saved';this.state.queue[1].status='failed';this.state.queue[2].status='saved';
      }else{
        this.state.phase='complete';this.state.screen='result';this.state.queue.forEach(q=>q.status='saved');
        this.state.hasDraft=scene==='draft';
      }
      this.finished().forEach(q=>this.state.local.add(q.id));
    }
    this.render();
  }

  finished() { return this.state.queue.filter(q=>q.status==='saved'||q.status==='reused'); }
  filterPhotos(filters=this.state) {
    if(this.state.empty)return [];
    return mobilePhotos.filter(p=>(filters.onlySelected?this.state.selected.has(p.id):
      (filters.format==='all'||p.format===filters.format)&&(filters.date==='all'||p.date===filters.date)));
  }
  statusBar() {
    return `<div class="status-bar" aria-hidden="true"><span>9:41</span><span class="status-icons">${mi('signal')}${mi('wifi')}<svg class="battery" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><path d="${mobileIcons.battery}"/></svg></span></div>`;
  }
  nav(title,backLabel='返回',right='more') {
    return `<header class="mobile-nav"><button class="back-button" data-action="back" aria-label="${backLabel}">${mi(this.os==='ios'?'back':'arrowBack')}${this.os==='ios'?backLabel:''}</button><h1>${title}</h1><button class="nav-end" data-action="${right==='more'?'menu':right==='import'?'browse':'close-sheet'}" aria-label="${right==='more'?'更多操作':right==='import'?'相机导入':'关闭'}">${mi(right==='more'?(this.os==='ios'?'more':'moreVertical'):right==='import'?'camera':'close')}</button></header>`;
  }
  primary(label,action,disabled=false) { return `<button class="primary-button" data-action="${action}" ${disabled?'disabled':''}>${label}</button>`; }
  secondary(label,action) { return `<button class="secondary-button" data-action="${action}">${label}</button>`; }
  text(label,action,extra='') { return `<button class="text-button ${extra}" data-action="${action}">${label}</button>`; }
  footer(content) { return `<footer class="mobile-footer">${content}</footer>`; }

  tile(p) {
    const selected=this.state.selected.has(p.id);
    return `<article class="photo-tile ${selected?'is-selected':''}"><button class="photo-select" data-action="select-photo" data-id="${p.id}" aria-pressed="${selected}" aria-label="${selected?'取消选中':'选中'} ${p.name}"><img src="${p.image}" alt="山林与湖泊示例照片" draggable="false"><span class="selection-square" aria-hidden="true">${mi('check')}</span>${this.state.local.has(p.id)?`<span class="imported-mark">${mi('check')}已导入</span>`:''}</button><div class="tile-info"><div><strong>${p.name}</strong><p>${p.format} · ${sizeText(p.size)}</p></div><button class="tile-preview" data-action="preview" data-id="${p.id}" aria-label="放大预览 ${p.name}">${mi('expand')}</button></div></article>`;
  }
  tabletSidebar() {
    return `<aside class="tablet-sidebar"><h2>拍摄日期</h2>${['all','today','yesterday','earlier'].map(date=>`<button class="tablet-date ${this.state.date===date?'active':''}" data-action="tablet-date" data-date="${date}">${dateNames[date]}</button>`).join('')}<button class="tablet-date records-link" data-action="records">导入记录</button></aside>`;
  }
  browse() {
    const s=this.state,items=this.filterPhotos(),selected=mobilePhotos.filter(p=>s.selected.has(p.id));
    const hidden=selected.length-items.filter(p=>s.selected.has(p.id)).length;
    const running=s.phase==='running';
    let task='';
    if(s.phase!=='idle'){
      const label=running?`正在导入 ${Math.min(this.finished().length+1,s.queue.length)}/${s.queue.length}`:s.phase==='complete'?'导入已完成，查看结果':'上次导入未完成';
      task=`<button class="task-entry" data-action="task">${mi(running?'download':s.phase==='complete'?'check':'clock')}<span>${label}</span>${mi('next')}</button>`;
    }
    const grid=items.length?`<main class="screen-scroll">${['today','yesterday','earlier'].map(date=>{
      const group=items.filter(p=>p.date===date);
      return group.length?`<section><div class="day-heading"><h2>${dateNames[date]}</h2><span>${group.length} 张</span></div><div class="photo-grid">${group.map(p=>this.tile(p)).join('')}</div></section>`:'';
    }).join('')}</main>`:`<main class="empty-state">${mi('camera')}<h2>${s.empty?'相机中还没有照片':'没有符合条件的照片'}</h2><p>${s.empty?'拍摄后刷新列表，就能在这里挑选并导入。':'换一个筛选条件，已选照片仍然保留。'}</p>${this.text(s.empty?'刷新照片':'清除筛选',s.empty?'refresh':'clear-filters')}</main>`;
    return `${this.nav('从相机导入')}<div class="screen-workspace">${this.tabletSidebar()}<div class="phone-content"><div class="camera-strip">${mi('camera')}<div><strong>α7C II</strong><p>存储卡 1 · ${items.length} 张${s.format==='RAW'&&!s.onlySelected?' RAW':''}</p></div><span class="connected-label">${mi('wifi')}${s.connected?'已连接':'已断开'}</span></div><div class="mobile-filterbar"><button class="filter-button" data-action="filters" aria-label="筛选文件类型"><span class="${this.os==='android'?'chip-fill':''}">${s.format==='all'?'全部格式':s.format}${mi('down')}</span></button><button class="filter-button date-chip" data-action="filters" aria-label="筛选拍摄日期">${s.date==='all'?'全部日期':s.date==='today'?'今天':s.date==='yesterday'?'昨天':'11 月 6 日'}${mi('down')}</button><button class="filter-button selected-filter" data-action="only-selected" aria-pressed="${s.onlySelected}">${s.onlySelected?'返回全部':'已选'}${s.onlySelected?'':` ${s.selected.size}`}</button></div>${task}${grid}</div></div>${this.footer(`<div class="selection-summary"><div><strong>${selected.length?`已选 ${selected.length} 张`:'选择要导入的照片'}</strong><p>${selected.length?sizeText(totalSize(selected)):'点照片选择，点放大按钮预览'}${hidden>0?` · ${hidden} 张不在当前筛选中`:''}</p></div>${this.text('清空','clear-selection','quiet-button')}</div>${this.primary(running?'查看导入进度':s.connected?`导入${selected.length?' '+selected.length+' 张':'照片'}`:'重新连接',running?'task':s.connected?'start':'reconnect',!running&&s.connected&&(!selected.length||s.empty))}`)}`;
  }

  preview() {
    const s=this.state,p=mobilePhoto(s.previewID);
    const items=this.filterPhotos(),index=items.findIndex(item=>item.id===p.id);
    return `${this.nav('照片预览','照片')}<main class="screen-scroll preview-scroll"><div class="preview-image"><img src="${p.image}" alt="${p.name} 的相机预览"></div><div class="preview-meta"><div><h2>${p.name}</h2><p>${p.format} · ${sizeText(p.size)} · 相机预览</p></div><div class="preview-paging"><button class="text-button" data-action="previous" aria-label="上一张">${mi('back')}</button><span>${index+1} / ${items.length}</span><button class="text-button" data-action="next" aria-label="下一张">${mi('next')}</button></div></div></main>${this.footer(this.primary(`${mi(s.selected.has(p.id)?'check':'photo')}${s.selected.has(p.id)?'取消选中':'选中照片'}`,'preview-select',s.phase==='running'))}`;
  }

  connect() {
    const s=this.state,auth=s.connectionStep==='auth',busy=s.connectionStep==='busy';
    let body;
    if(busy){
      body=`<h2 class="page-title">正在连接相机</h2><p class="page-intro">让相机保持唤醒。</p><div class="busy-line"><span class="spinner"></span>正在${s.trust?'验证连接':'查找相机'}…</div>`;
    }else if(auth){
      body=`<div class="connection-top">${mi('camera')}<div><strong>α7C II</strong><p>${escapeText(s.address)}</p></div></div><label class="mobile-field"><span>用户名</span><input data-field="user" value="${escapeText(s.user)}" autocomplete="off"></label><label class="mobile-field"><span>密码</span><input data-field="password" type="password" value="${escapeText(s.password)}" autocomplete="off"></label><div class="mobile-field"><span>相机指纹</span><div class="fingerprint">SHA256:7x9iB2kL4mN6pQ8rS0tU2vW4yZ6aC8dE0fG2hI4jK6L</div><p class="field-help">与相机屏幕上显示的指纹完整核对。</p></div><label class="mobile-check"><input type="checkbox" data-field="trust" ${s.trust?'checked':''}>指纹与相机显示的一致</label><div class="remember-row"><div><strong>记住密码</strong><p>${this.os==='ios'?'保存在钥匙串':'仅保存在此设备'}</p></div><button class="native-switch" data-action="remember" role="switch" aria-label="记住密码" aria-checked="${s.remember}"><span></span></button></div>`;
    }else{
      body=`<h2 class="page-title">连接你的 Sony 相机</h2><p class="page-intro">从存储卡挑几张照片，带进 RawLab 编辑。</p><ol class="connection-steps"><li>手机与相机连接到同一 Wi-Fi。</li><li>在相机上开启「PC 遥控」。</li><li>保持相机唤醒，结束其他应用的相机连接。</li></ol><label class="mobile-field"><span>相机 IP 地址</span><input data-field="address" inputmode="decimal" value="${escapeText(s.address)}" placeholder="例如 192.168.1.100" autocomplete="off"></label>${s.formError?`<p class="form-error" role="alert">${s.formError}</p>`:''}<details class="connection-help"><summary>在相机上哪里设置？</summary><p>网络 → 连接/PC 遥控 → PC 遥控功能。<br>认证信息位于网络选项中的「访问认证信息」。</p></details>`;
    }
    return `${this.nav(auth?'访问认证':'连接相机')}<main class="screen-scroll connection-page">${body}</main>${this.footer(`${this.primary(busy?'正在连接…':auth?'连接相机':'查找相机','connect-next',busy||(auth&&(!s.trust||!s.user.trim()||!s.password)))}<p class="footer-note">照片只保存在本机，相机中的原片不变。</p>`)}`;
  }

  queueList() {
    const labels={pending:'等待导入',running:'正在导入',saved:'已保存',failed:'尚未完成，可重试',reused:'已在本机'};
    return `<div class="queue-list">${this.state.queue.map(q=>{const p=mobilePhoto(q.id);return `<div class="queue-row ${q.status==='failed'?'failed':''}"><img src="${p.image}" alt=""><div><strong>${p.name}</strong><p>${labels[q.status]}</p></div>${q.status==='running'?'<span class="spinner"></span>':mi(q.status==='saved'||q.status==='reused'?'check':q.status==='failed'?'warning':'clock')}</div>`;}).join('')}</div>`;
  }
  progressValues() {
    const active=this.state.queue.find(q=>q.status==='running');
    const total=totalSize(this.state.queue.map(q=>mobilePhoto(q.id)));
    const received=totalSize(this.finished().map(q=>mobilePhoto(q.id)))+(active?mobilePhoto(active.id).size*this.state.progress:0);
    return {active,total,received,percent:total?received/total*100:0};
  }
  transfer() {
    const s=this.state,done=this.finished(),v=this.progressValues(),running=s.phase==='running';
    const title=running?'正在导入':s.phase==='stopped'?'已停止导入':'导入未完成';
    let content;
    if(running){
      const p=mobilePhoto(v.active?.id||s.queue[0]?.id||1);
      content=`<img class="transfer-photo" src="${p.image}" alt="正在导入的照片"><div class="transfer-heading"><h2>正在导入 ${Math.min(done.length+1,s.queue.length)} / ${s.queue.length}</h2><span data-progress="percent">${Math.round(v.percent)}%</span></div><div class="progress-track" role="progressbar" aria-label="导入进度" aria-valuenow="${Math.round(v.percent)}" aria-valuemin="0" aria-valuemax="100"><div class="progress-fill" style="width:${v.percent}%"></div></div><div class="progress-label"><span>${p.name}</span><span data-progress="bytes">${sizeText(v.received)} / ${sizeText(v.total)}</span></div><p class="foreground-note">${mi('phone')}导入时请保持 RawLab 在前台。</p>`;
    }else{
      const background=s.reason==='background';
      content=`<div class="resume-title">${mi(background?'phone':s.phase==='stopped'?'clock':'wifi')}<h2>${s.phase==='stopped'?'已停止导入':background?'继续上次的导入':'相机连接已断开'}</h2><p>${background?'离开应用后，传输未能完成。':s.phase==='stopped'?'你可以稍后继续剩余照片。':'让相机保持唤醒，并确认仍在同一 Wi-Fi。'}<br>已保存的 ${done.length} 张照片都在本机。</p></div><p class="inline-message">继续时只处理未完成项，当前未完成的照片会重新下载。</p>`;
    }
    return `${this.nav(title,'照片')}<main class="screen-scroll transfer-page">${content}${this.queueList()}</main>${this.footer(running?`${this.secondary('返回照片','browse')}<div class="footer-links">${this.text('停止导入','stop','quiet-button')}</div>`:`${this.primary(s.connected?'继续未完成':'重新连接并继续','resume')}<div class="footer-links">${this.text('查看已导入','records')}${this.text('结束本次任务','end-task','quiet-button')}</div>`)}`;
  }

  result() {
    const s=this.state,done=this.finished(),failed=s.queue.length-done.length;
    const reused=done.filter(q=>q.status==='reused').length;
    return `${this.nav('导入结果','照片')}<main class="screen-scroll result-page"><div class="result-photos">${done.slice(0,3).map(q=>`<img src="${mobilePhoto(q.id).image}" alt="已保存照片">`).join('')}</div><div class="result-title">${mi(failed?'warning':'check')}<h2>${failed?`${done.length} 张已导入，${failed} 张未完成`:`${done.length} 张照片已导入`}</h2></div><p class="result-description">${failed?'已保存的照片可以先编辑，未完成项可单独重试。':'原文件已保存在本机。现在可以断开相机，继续编辑。'}${reused?`其中 ${reused} 张已在本机，保留原有调整。`:''}</p>${this.queueList()}</main>${this.footer(`${this.primary(failed?'重试未完成':done.length===1?'打开编辑':'加入选片集合',failed?'resume':'handoff',!done.length&&!failed)}<div class="footer-links">${this.text(failed?'编辑已导入照片':'继续选片',failed?'handoff':'new-selection')}${this.text('导入记录','records','quiet-button')}</div>`)}`;
  }

  records(collection=false) {
    const s=this.state,ids=collection?s.collection:[...s.local];
    const rows=mobilePhotos.filter(p=>ids.includes(p.id));
    return `${this.nav(collection?'选片集合':'导入记录','照片')}<main class="screen-scroll records-page"><p class="local-title">${collection?'本次导入的照片已加入集合，可逐张编辑。':'照片已保存在本机，无需连接相机。'}</p>${rows.map(p=>`<button class="record-row" data-action="open-local" data-id="${p.id}"><img src="${p.image}" alt=""><div><strong>${p.name}</strong><p>${p.format} · ${sizeText(p.size)} · 已保存</p></div>${mi('next')}</button>`).join('')}</main>${this.footer(`<p class="footer-note">${rows.length} 张原文件保留在本机。重新打开会恢复已有调整。</p>${this.secondary('返回相机照片','browse')}`)}`;
  }

  editor() {
    const s=this.state,p=mobilePhoto(s.editorID);
    return `${this.nav('RawLab',s.editorFrom==='collection'?'集合':'返回','import')}<main class="screen-scroll editor-demo-body"><img class="editor-demo-photo" src="${p.image}" alt="已打开的本地示例照片"><div class="editor-demo-name">${p.name} · 调整已保存</div><div class="editor-controls"><h2>光线</h2><label>曝光<output data-output="exposure">0.00 EV</output></label><input data-field="exposure" type="range" min="-4" max="4" step="0.1" value="0" aria-label="曝光"></div></main>${this.footer(`${this.secondary(s.phase==='running'?'查看正在进行的导入':'返回相机导入',s.phase==='running'?'task':'browse')}`)}`;
  }

  restricted() {
    const ios=this.os==='ios';
    return `${this.nav('连接相机')}<main class="empty-state">${mi(ios?'lock':'wifi')}<h2>${ios?'允许访问本地网络':'连接相机所在的 Wi-Fi'}</h2><p>${ios?'RawLab 需要在局域网中与相机连接。请在系统设置中允许本地网络访问，再回来重试。':'手机需要与相机处于同一个网络。相机网络没有互联网也可以传图。'}</p></main>${this.footer(`${this.primary(ios?'打开设置':'查看 Wi-Fi 设置','open-settings')}<div class="footer-links">${this.text('重新连接','retry-connect')}</div>`)}`;
  }

  sheet() {
    const s=this.state;
    if(!s.sheet)return '';
    let title='',content='',footer='';
    if(s.sheet==='filters'){
      title='筛选照片';
      const pending=s.pending;
      const row=(label,key,value)=>`<button class="option-row" data-action="filter-choice" data-key="${key}" data-value="${value}" role="radio" aria-checked="${pending[key]===value}"><span>${label}</span>${this.os==='android'?'<span class="radio-check"></span>':pending[key]===value?mi('check'):'<span class="empty-check"></span>'}</button>`;
      content=`<section class="sheet-section"><h3>拍摄日期</h3>${Object.entries(dateNames).map(([value,label])=>row(label,'date',value)).join('')}</section><section class="sheet-section"><h3>文件类型</h3>${this.os==='android'?`<div class="chip-options">${['all','RAW','HEIF'].map(value=>`<button class="material-chip" data-action="filter-choice" data-key="format" data-value="${value}" aria-pressed="${pending.format===value}">${pending.format===value?mi('check'):''}${value==='all'?'全部':value}</button>`).join('')}</div>`:['all','RAW','HEIF'].map(value=>row(value==='all'?'全部格式':value,'format',value)).join('')}</section>`;
      footer=this.primary(`显示 ${this.filterPhotos({...pending,onlySelected:false}).length} 张照片`,'apply-filters');
    }else if(s.sheet==='menu'){
      title='相机导入';
      content=`${[['folder','导入记录','records'],['camera','连接相机','connect'],['refresh','刷新照片','refresh']].map(([symbol,label,action])=>`<button class="sheet-menu-button" data-action="${action}">${mi(symbol)}${label}</button>`).join('')}<p class="field-help">α7C II · 存储卡 1<br>原照片保留在相机中。</p>`;
    }else{
      title='应用当前调整？';
      content=`<p class="guard-copy">当前照片还有未应用的几何调整。相机照片已经保存，可以稍后打开。</p><div class="guard-actions">${this.primary('应用并打开导入照片','apply-draft')}${this.secondary('放弃调整并打开','discard-draft')}${this.text('继续编辑当前照片','stay-editing')}</div>`;
    }
    return `<div class="sheet-scrim"><section class="mobile-sheet" role="dialog" aria-modal="true" aria-label="${title}"><div class="sheet-handle" aria-hidden="true"></div><header class="sheet-header"><button class="text-button reset" data-action="${s.sheet==='filters'?'reset-filters':'close-sheet'}">${s.sheet==='filters'?'重置':'关闭'}</button><h2>${title}</h2><button class="text-button" data-action="close-sheet" aria-label="关闭面板">${this.os==='ios'?'取消':mi('close')}</button></header><div class="sheet-scroll">${content}</div>${footer?`<footer class="sheet-footer">${footer}</footer>`:''}</section></div>`;
  }

  render() {
    const s=this.state;
    const scroller=this.root.querySelector('.screen-scroll');
    const oldScroll=this.lastScreen===s.screen?(scroller?.scrollTop||0):0;
    const newSheet=s.sheet&&s.sheet!==this.lastSheet;
    const screens={browse:()=>this.browse(),preview:()=>this.preview(),connect:()=>this.connect(),transfer:()=>this.transfer(),result:()=>this.result(),records:()=>this.records(),collection:()=>this.records(true),editor:()=>this.editor(),restricted:()=>this.restricted()};
    this.root.innerHTML=`${this.statusBar()}<div class="app-page" ${s.sheet?'inert':''}>${(screens[s.screen]||screens.browse)()}</div><div class="system-bottom" aria-hidden="true"><span></span></div>${this.sheet()}${s.message?`<div class="mobile-snackbar" role="status">${s.message}</div>`:''}`;
    const nextScroll=this.root.querySelector('.screen-scroll');
    if(nextScroll)nextScroll.scrollTop=oldScroll;
    if(newSheet)requestAnimationFrame(()=>this.root.querySelector('.sheet-header button')?.focus());
    this.lastScreen=s.screen;this.lastSheet=s.sheet;
  }

  notify(message) {
    clearTimeout(this.messageTimer);this.state.message=message;this.render();
    this.messageTimer=setTimeout(()=>{this.state.message='';this.render();},2800);
  }
  movePreview(direction) {
    const items=this.filterPhotos();
    if(!items.length)return;
    const index=items.findIndex(p=>p.id===this.state.previewID);
    this.state.previewID=items[(index+direction+items.length)%items.length].id;this.render();
  }
  toggle(id) {
    if(this.state.phase==='running'){this.notify('导入完成后可继续选片；现在仍可预览照片。');return;}
    if(this.state.selected.has(id))this.state.selected.delete(id);else this.state.selected.add(id);
    this.render();
  }

  startTransfer(resume=false) {
    const s=this.state;
    if(!resume)s.queue=mobilePhotos.filter(p=>s.selected.has(p.id)).map(p=>({id:p.id,status:s.local.has(p.id)?'reused':'pending'}));
    if(!s.queue.length)return;
    s.queue.forEach(q=>{if(q.status==='failed'||q.status==='running')q.status='pending';});
    clearInterval(this.timer);s.connected=true;s.phase='running';s.screen='transfer';s.progress=0;s.sheet=null;
    this.nextFile();this.render();
    if(s.phase==='complete')return;
    this.timer=setInterval(()=>{
      if(s.phase!=='running'){clearInterval(this.timer);return;}
      s.progress=Math.min(1,s.progress+.12);
      if(s.progress>=1){
        const active=s.queue.find(q=>q.status==='running');
        if(active){active.status='saved';s.local.add(active.id);}
        s.progress=0;this.nextFile();this.render();
      }else if(s.screen==='transfer'){
        const v=this.progressValues();
        const bar=this.root.querySelector('.progress-fill');if(bar)bar.style.width=v.percent+'%';
        const progress=this.root.querySelector('[role="progressbar"]');if(progress)progress.setAttribute('aria-valuenow',String(Math.round(v.percent)));
        const label=this.root.querySelector('[data-progress="percent"]');if(label)label.textContent=Math.round(v.percent)+'%';
        const bytes=this.root.querySelector('[data-progress="bytes"]');if(bytes)bytes.textContent=sizeText(v.received)+' / '+sizeText(v.total);
      }
    },320);
  }
  nextFile() {
    const next=this.state.queue.find(q=>q.status==='pending');
    if(next){next.status='running';return;}
    this.state.phase='complete';clearInterval(this.timer);
    // 只有用户停留在任务页时显示结果；在编辑器中不抢占正在看的照片。
    if(this.state.screen==='transfer')this.state.screen='result';
  }
  handoff() {
    const ids=this.finished().map(q=>q.id);if(!ids.length)return;
    this.openIDs(ids,'records');
  }
  openIDs(ids,from) {
    if(this.state.hasDraft){this.state.pendingOpen={ids,from};this.state.sheet='guard';this.render();return;}
    if(ids.length>1)this.state.collection=ids;
    if(ids.length===1){this.state.editorID=ids[0];this.state.editorFrom=from;this.state.screen='editor';}
    else{this.state.screen='collection';}
    this.render();
  }
  back() {
    const s=this.state;
    if(s.sheet){s.sheet=null;this.render();return;}
    if(s.screen==='preview'){s.screen=s.previewOrigin;}
    else if(s.screen==='connect'&&s.connectionStep!=='address'){s.connectionStep='address';}
    else if(s.screen==='editor'){s.screen=s.editorFrom==='collection'?'collection':'browse';}
    else if(s.screen==='browse'){s.screen='editor';s.editorID=11;s.editorFrom='browse';}
    else{s.screen='browse';}
    this.render();
  }
  act(action,data={}) {
    const s=this.state,id=Number(data.id);
    switch(action){
      case 'back':this.back();return;
      case 'browse':s.sheet=null;s.screen='browse';break;
      case 'menu':s.sheet='menu';break;
      case 'filters':s.pending={date:s.date,format:s.format};s.sheet='filters';break;
      case 'close-sheet':s.sheet=null;break;
      case 'filter-choice':s.pending[data.key]=data.value;break;
      case 'reset-filters':s.pending={date:'all',format:'RAW'};break;
      case 'apply-filters':Object.assign(s,s.pending);s.onlySelected=false;s.sheet=null;break;
      case 'tablet-date':s.date=data.date;s.onlySelected=false;break;
      case 'only-selected':s.onlySelected=!s.onlySelected;break;
      case 'clear-filters':s.format='all';s.date='all';s.onlySelected=false;break;
      case 'select-photo':this.toggle(id);return;
      case 'clear-selection':if(s.phase==='running'){this.notify('本次导入正在进行。');return;}s.selected.clear();break;
      case 'preview':s.previewID=id;s.previewOrigin=s.screen;s.screen='preview';break;
      case 'preview-select':this.toggle(s.previewID);return;
      case 'next':this.movePreview(1);return;
      case 'previous':this.movePreview(-1);return;
      case 'start':this.startTransfer();return;
      case 'resume':this.startTransfer(true);return;
      case 'task':s.screen=s.phase==='complete'||s.phase==='partial'?'result':'transfer';break;
      case 'stop':clearInterval(this.timer);s.phase='stopped';s.progress=0;s.queue.forEach(q=>{if(q.status==='running')q.status='pending';});break;
      case 'end-task':s.phase='idle';s.queue=[];s.selected.clear();s.screen='browse';break;
      case 'new-selection':s.phase='idle';s.queue=[];s.selected.clear();s.screen='browse';break;
      case 'records':s.sheet=null;s.screen='records';break;
      case 'open-local':this.openIDs([id],s.screen);return;
      case 'handoff':this.handoff();return;
      case 'apply-draft':case 'discard-draft':{
        s.hasDraft=false;s.sheet=null;
        const pending=s.pendingOpen;s.pendingOpen=null;
        if(pending)this.openIDs(pending.ids,pending.from);else this.handoff();return;
      }
      case 'stay-editing':s.sheet=null;s.screen='editor';s.editorID=11;s.editorFrom='browse';break;
      case 'connect':if(s.phase==='running'){s.sheet=null;this.notify('停止当前导入后再更改连接。');return;}s.sheet=null;s.screen='connect';s.connectionStep='address';break;
      case 'connect-next':{
        if(s.connectionStep==='address'){
          const parts=s.address.split('.');
          if(parts.length!==4||parts.some(p=>!/^\d{1,3}$/.test(p)||Number(p)>255)){s.formError='请输入相机显示的有效 IP 地址。';break;}
          s.connectionStep='busy';this.render();
          setTimeout(()=>{if(s.screen==='connect'&&s.connectionStep==='busy'){s.connectionStep='auth';this.render();}},650);return;
        }
        if(s.connectionStep==='auth'&&s.trust){
          s.connectionStep='busy';this.render();
          setTimeout(()=>{if(s.screen==='connect'&&s.connectionStep==='busy'){s.screen='browse';s.phase='idle';s.connected=true;s.selected.clear();this.render();}},650);return;
        }
        break;
      }
      case 'remember':s.remember=!s.remember;break;
      case 'reconnect':s.connected=true;this.notify('已模拟重新连接，选片结果保留。');return;
      case 'open-settings':this.notify(this.os==='ios'?'这里将打开 RawLab 的系统设置，返回后可重试。':'这里将打开系统 Wi-Fi 设置，返回后可重试。');return;
      case 'retry-connect':s.screen='connect';s.connectionStep='address';break;
      case 'refresh':s.sheet=null;this.notify(s.connected?'照片列表已刷新，选片结果保留。':'请先重新连接相机。');return;
    }
    this.render();
  }
}

const mobileDemos=[new MobileCameraDemo(document.querySelector('#ios-demo'),'ios'),new MobileCameraDemo(document.querySelector('#android-demo'),'android')];
const mobileBoard=document.querySelector('#mobile-board');
const mobileScenario=document.querySelector('#mobile-scenario');
document.querySelectorAll('[data-view]').forEach(button=>{
  if(button.tagName!=='BUTTON')return;
  button.addEventListener('click',()=>{
    const view=button.dataset.view;mobileBoard.dataset.view=view;
    document.querySelectorAll('button[data-view]').forEach(b=>b.setAttribute('aria-pressed',String(b===button)));
    document.querySelector('#apple-label').textContent=view==='tablet'?'iPad / 宽窗口':'iPhone';
  });
});
document.querySelector('#large-type').addEventListener('change',event=>{
  document.querySelectorAll('.phone').forEach(phone=>phone.classList.toggle('large-text',event.target.checked));
});
mobileScenario.addEventListener('change',()=>mobileDemos.forEach(demo=>demo.setScene(mobileScenario.value)));
const params=new URLSearchParams(location.search);
if(['ios','android','tablet','compare'].includes(params.get('view')))document.querySelector(`button[data-view="${params.get('view')}"]`).click();
if([...mobileScenario.options].some(o=>o.value===params.get('state'))){mobileScenario.value=params.get('state');mobileDemos.forEach(demo=>demo.setScene(mobileScenario.value));}
