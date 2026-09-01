import Foundation

/// The esh 2.0 Web Experience — the primary browser interface served at `GET /web` by `esh web`.
/// A faithful implementation of the approved prototype (warm paper aesthetic, graphite ink, IBM Plex
/// Mono for technical data, inline SVG icons — no emoji). It is a **thin client**: all routing, fit,
/// scheduler, capability and runtime logic lives in esh and is read over canonical endpoints
/// (`/v1/engine`, `/v1/schedule`, `/v1/catalog`, `/v1/config`, `/v1/models`, `/v1/chat/completions`,
/// `/v1/audio/*`). Single self-contained file, no build step — packages into the notarized binary.
public enum WebChatPage {
    public static let contentType = "text/html; charset=utf-8"

    public static func html(toolVersion: String?) -> String {
        let version = toolVersion.map { "v\($0)" } ?? ""
        return page.replacingOccurrences(of: "__VERSION__", with: version)
    }

    private static let page = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>esh — Local Chat</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500&display=swap" rel="stylesheet">
<style>
  :root{ --paper:#fbfaf8; --ink:#201e1b; --panel:#f7f4ee; --panel2:#f3f1ec; --userbubble:#efede8;
         --line:rgba(32,30,27,.08); --line2:rgba(32,30,27,.14); --muted:rgba(32,30,27,.55);
         --faint:rgba(32,30,27,.4); --amber:#b0761f; --mono:'IBM Plex Mono',ui-monospace,monospace; }
  *{ box-sizing:border-box; }
  html,body{ margin:0; height:100%; }
  body{ font:14px/1.5 -apple-system,system-ui,sans-serif; color:var(--ink); background:var(--paper); overflow:hidden; }
  button,input,textarea,select{ font-family:inherit; color:var(--ink); }
  a{ color:var(--ink); text-decoration:none; } a:hover{ opacity:.7; }
  .mono{ font-family:var(--mono); }
  .app{ height:100vh; display:flex; flex-direction:column; background:var(--paper); position:relative; overflow:hidden; }
  .hidden{ display:none !important; }
  .icon{ display:flex; }
  @keyframes eshblink{0%,49%{opacity:1}50%,100%{opacity:0}}
  @keyframes eshpulse{0%,100%{transform:scale(1);opacity:.9}50%{transform:scale(1.12);opacity:1}}
  @keyframes eshbar{0%,100%{transform:scaleY(.35)}50%{transform:scaleY(1)}}
  @keyframes eshtype{0%,80%,100%{transform:scale(.55);opacity:.4}40%{transform:scale(1);opacity:1}}
  /* Header */
  .topbar{ display:flex; align-items:center; gap:14px; padding:12px 20px; border-bottom:1px solid rgba(32,30,27,.06); }
  .topbar .brand{ font-weight:600; font-size:15px; letter-spacing:-.01em; }
  .topbar .sp{ flex:1; }
  .iconbtn{ color:var(--faint); cursor:pointer; display:flex; padding:4px; border:none; background:none; border-radius:6px; }
  .iconbtn:hover{ color:var(--ink); }
  .modelbtn{ font-size:13px; color:rgba(32,30,27,.8); padding:5px 10px; border-radius:7px; cursor:pointer; white-space:nowrap; display:flex; align-items:center; gap:5px; border:none; background:none; }
  .modelbtn:hover{ background:rgba(32,30,27,.05); }
  /* Layout */
  .body{ flex:1; display:flex; min-height:0; position:relative; }
  .sidebar{ width:220px; border-right:1px solid rgba(32,30,27,.06); padding:14px 10px; display:flex; flex-direction:column; gap:2px; flex-shrink:0; overflow-y:auto; }
  .newchat{ display:flex; align-items:center; justify-content:center; gap:8px; padding:7px 12px; border-radius:8px; font-size:13px; font-weight:500; cursor:pointer; border:1px solid var(--line2); margin-bottom:10px; background:none; }
  .newchat:hover{ background:rgba(32,30,27,.03); }
  .sgroup{ padding:4px 12px; margin-top:8px; font:500 9.5px var(--mono); letter-spacing:.1em; text-transform:uppercase; color:var(--faint); }
  .chatitem{ padding:7px 12px; border-radius:8px; font-size:13px; color:rgba(32,30,27,.75); cursor:pointer; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
  .chatitem:hover{ background:rgba(32,30,27,.04); }
  .chatitem.active{ background:rgba(32,30,27,.05); color:var(--ink); }
  .main{ flex:1; display:flex; flex-direction:column; min-width:0; position:relative; }
  .empty{ flex:1; display:flex; align-items:center; justify-content:center; padding-bottom:60px; font-size:26px; font-weight:500; letter-spacing:-.02em; }
  .log{ flex:1; overflow-y:auto; padding:28px 24px; }
  .thread{ max-width:640px; margin:0 auto; display:flex; flex-direction:column; gap:22px; }
  .msg{ display:flex; flex-direction:column; gap:10px; }
  .userrow{ display:flex; justify-content:flex-end; }
  .userbubble{ background:var(--userbubble); border-radius:14px; padding:10px 14px; font-size:14px; line-height:1.5; max-width:70%; white-space:pre-wrap; overflow-wrap:anywhere; }
  .asst{ display:flex; flex-direction:column; gap:9px; }
  .reason{ font-size:12px; color:var(--muted); }
  .reason summary{ cursor:pointer; list-style:none; color:var(--faint); }
  .reason summary::-webkit-details-marker{ display:none; }
  .reason summary::before{ content:"▸ "; } .reason[open] summary::before{ content:"▾ "; }
  .reason summary.live{ color:var(--ink); animation:eshpulse 1.5s ease-in-out infinite; }
  .reason .rc{ color:var(--muted); white-space:pre-wrap; border-left:2px solid var(--line2); padding-left:10px; margin-top:6px; line-height:1.5; }
  .asttext{ font-size:14px; line-height:1.6; white-space:pre-wrap; overflow-wrap:anywhere; }
  .asttext pre{ background:var(--panel2); padding:10px 12px; border-radius:8px; overflow-x:auto; }
  .asttext code{ background:var(--panel2); padding:1px 4px; border-radius:4px; font-family:var(--mono); font-size:12.5px; }
  .asttext img{ max-width:100%; border-radius:10px; margin:6px 0; display:block; } .asttext audio{ width:100%; margin:6px 0; }
  .metaline{ font:400 11px var(--mono); color:var(--faint); cursor:pointer; align-self:flex-start; }
  .metaline:hover{ color:var(--ink); text-decoration:underline; }
  .caret{ display:inline-block; width:8px; height:15px; background:var(--ink); vertical-align:-2px; margin-left:2px; animation:eshblink 1s infinite; }
  .typing{ display:inline-flex; gap:5px; align-items:center; padding:3px 2px; }
  .typing i{ width:7px; height:7px; border-radius:50%; background:var(--faint); animation:eshtype 1.2s infinite ease-in-out both; }
  .typing i:nth-child(2){ animation-delay:.16s } .typing i:nth-child(3){ animation-delay:.32s }
  .errcard{ border:1px solid var(--line2); border-radius:12px; padding:16px 18px; }
  .errcard .t{ font-size:13.5px; font-weight:600; } .errcard .d{ font-size:12.5px; line-height:1.55; color:rgba(32,30,27,.7); margin-top:5px; }
  /* Composer */
  .composer{ padding:0 24px 10px; flex-shrink:0; }
  .cbox{ max-width:640px; margin:0 auto; background:#fff; border:1px solid var(--line2); border-radius:15px; box-shadow:0 1px 2px rgba(32,30,27,.04); padding:11px 14px; display:flex; align-items:center; gap:10px; position:relative; }
  .cround{ width:26px; height:26px; border:1px solid var(--line2); border-radius:50%; display:flex; align-items:center; justify-content:center; color:var(--muted); cursor:pointer; flex-shrink:0; background:none; }
  .cround:hover{ background:rgba(32,30,27,.05); }
  .cinput{ flex:1; border:none; outline:none; font-size:14px; background:transparent; color:var(--ink); resize:none; max-height:160px; line-height:1.4; }
  .send{ width:28px; height:28px; border-radius:50%; display:flex; align-items:center; justify-content:center; color:#fff; cursor:pointer; flex-shrink:0; border:none; }
  .statusrow{ display:flex; justify-content:center; margin-top:8px; }
  .statusbtn{ display:flex; align-items:center; gap:7px; font:400 11px var(--mono); color:var(--muted); cursor:pointer; border:none; background:none; }
  .statusbtn:hover{ color:var(--ink); }
  .dot{ width:6px; height:6px; border-radius:50%; background:var(--ink); }
  /* Popups */
  .pop{ position:absolute; background:var(--paper); border:1px solid var(--line2); border-radius:12px; box-shadow:0 12px 36px rgba(32,30,27,.14); z-index:40; }
  .menuhead{ padding:10px 20px 4px; font:500 9.5px var(--mono); letter-spacing:.1em; text-transform:uppercase; color:var(--faint); }
  .menurow{ padding:7px 20px; font-size:13px; cursor:pointer; display:flex; align-items:center; gap:8px; }
  .menurow:hover{ background:rgba(32,30,27,.04); }
  .radio{ width:14px; height:14px; border-radius:50%; box-sizing:border-box; flex-shrink:0; border:1.5px solid rgba(32,30,27,.3); }
  .radio.on{ border:4.5px solid var(--ink); }
  .sep{ height:1px; background:rgba(32,30,27,.07); margin:4px 0; }
  /* Right panel (execution) — an overlay drawer so it never squeezes the chat at narrow widths */
  .rightpanel{ position:absolute; top:0; right:0; bottom:0; width:340px; max-width:88vw; border-left:1px solid var(--line2); overflow-y:auto; background:var(--paper); z-index:45; box-shadow:-12px 0 36px rgba(32,30,27,.10); }
  .kv{ display:flex; justify-content:space-between; font-size:12.5px; } .kv .k{ color:var(--muted); }
  .panelhead{ display:flex; align-items:center; padding:16px 20px 12px; font-size:14px; font-weight:600; }
  /* Views: models + settings */
  .viewhead{ display:flex; align-items:center; gap:16px; padding:16px 24px 0; }
  .backbtn{ font-size:13px; color:var(--muted); cursor:pointer; display:flex; align-items:center; gap:5px; border:none; background:none; }
  .backbtn:hover{ color:var(--ink); }
  .chip{ padding:5px 12px; border-radius:99px; font-size:12px; cursor:pointer; border:1px solid var(--line2); background:none; color:var(--muted); }
  .chip.on{ background:var(--ink); color:#fff; border-color:var(--ink); }
  .mrow{ display:flex; align-items:center; gap:14px; padding:14px 24px; border-bottom:1px solid var(--line); }
  .mrow:hover{ background:rgba(32,30,27,.02); }
  .mrow .mleft{ flex:1; min-width:0; cursor:pointer; }
  .mrow .mdesc{ font-size:11.5px; color:var(--muted); margin-top:2px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .mrow .mname{ font-size:13.5px; font-weight:600; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .mrow .mmeta{ display:flex; align-items:center; gap:14px; flex-shrink:0; }
  .mrow .mfit{ width:88px; font-size:12px; } .mrow .mmem{ width:74px; } .mrow .mspeed{ width:96px; } .mrow .maction{ min-width:78px; text-align:right; font-size:12px; }
  @media(max-width:720px){ .mrow .mmem, .mrow .mspeed{ display:none; } }
  .btn{ background:var(--ink); color:#fff; font-size:13px; font-weight:500; padding:9px 22px; border-radius:9px; border:none; cursor:pointer; }
  .btn.ghost{ background:none; border:1px solid var(--line2); color:rgba(32,30,27,.75); }
  .overlay{ position:absolute; inset:0; background:rgba(32,30,27,.22); display:flex; align-items:center; justify-content:center; z-index:50; }
  .modal{ background:var(--paper); border-radius:14px; box-shadow:0 24px 60px rgba(32,30,27,.25); }
  .toggle{ width:34px; height:20px; border-radius:10px; position:relative; cursor:pointer; transition:background .15s; }
  .toggle .knob{ position:absolute; top:2px; width:16px; height:16px; border-radius:50%; background:#fff; transition:left .15s; }
  .paneside{ width:190px; border-right:1px solid rgba(32,30,27,.07); padding:16px 8px; display:flex; flex-direction:column; gap:1px; flex-shrink:0; }
  .paneitem{ padding:7px 14px; font-size:13px; border-radius:7px; cursor:pointer; color:var(--muted); }
  .paneitem.on{ background:rgba(32,30,27,.06); font-weight:500; color:var(--ink); }
  .warnbox{ border:1px solid rgba(176,118,31,.35); border-radius:9px; padding:11px 14px; font-size:12.5px; line-height:1.5; color:rgba(32,30,27,.8); }
  .membar{ height:4px; background:rgba(32,30,27,.08); border-radius:2px; } .membar>div{ height:4px; background:var(--ink); border-radius:2px; transition:width .3s ease; }
  /* Fluid interactions */
  .iconbtn,.modelbtn,.newchat,.chatitem,.menurow,.chip,.cround,.send,.paneitem,.backbtn,.statusbtn,.mrow,.reason summary,.toggle,.btn{ transition:background .14s ease, color .14s ease, opacity .14s ease, border-color .14s ease, transform .12s ease, box-shadow .14s ease; }
  .send:active,.cround:active,.iconbtn:active{ transform:scale(.9); }
  .chip:active,.newchat:active,.btn:active{ transform:scale(.97); }
  .cbox{ transition:box-shadow .16s ease, border-color .16s ease; } .cbox:focus-within{ border-color:rgba(32,30,27,.28); box-shadow:0 2px 10px rgba(32,30,27,.07); }
  @keyframes eshpop{ from{opacity:0; transform:translateY(-6px) scale(.98)} to{opacity:1; transform:none} }
  .pop{ animation:eshpop .15s cubic-bezier(.2,.8,.2,1); transform-origin:top; }
  @keyframes eshdrawer{ from{opacity:0; transform:translateX(30px)} to{opacity:1; transform:none} }
  .rightpanel{ animation:eshdrawer .2s cubic-bezier(.2,.8,.2,1); }
  @keyframes eshfade{ from{opacity:0} to{opacity:1} }
  .overlay{ animation:eshfade .15s ease-out; }
  .modal{ animation:eshpop .2s cubic-bezier(.2,.8,.2,1); }
  @keyframes eshmsgin{ from{opacity:0; transform:translateY(8px)} to{opacity:1; transform:none} }
  .msgin{ animation:eshmsgin .26s cubic-bezier(.2,.8,.2,1); }
  details.reason[open] .rc{ animation:eshfade .22s ease-out; }
  .empty{ animation:eshfade .3s ease-out; }
  @media (prefers-reduced-motion:reduce){ *{ animation-duration:.001s !important; transition:none !important; } }
</style>
</head>
<body>
<div class="app" id="app"><!-- rendered by JS --></div>
<script>
const $=s=>document.querySelector(s), LS="esh.chats.v1", PREF="esh.prefs.v1";
const ICON={
  sidebar:'<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><rect x="3.5" y="4.5" width="17" height="15" rx="2.5"/><path d="M9.5 4.5v15"/></svg>',
  settings:'<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M4 7h16"/><path d="M4 17h16"/><circle cx="9.5" cy="7" r="2.4"/><circle cx="14.5" cy="17" r="2.4"/></svg>',
  plus:'<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M12 5v14"/><path d="M5 12h14"/></svg>',
  mic:'<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5.5 11.5a6.5 6.5 0 0 0 13 0"/><path d="M12 18v3"/></svg>',
  up:'<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 19V5"/><path d="M6 11l6-6 6 6"/></svg>',
  back:'<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M19 12H5"/><path d="M11 18l-6-6 6-6"/></svg>',
  stop:'<svg width="11" height="11" viewBox="0 0 24 24" fill="currentColor"><rect x="6" y="6" width="12" height="12" rx="2"/></svg>'
};
let S={ view:'chat', chats:{}, current:null, controller:null, streaming:false, streamText:'', streamThinkMs:undefined,
        models:[], modelSel:'Auto', optimize:'Balanced', pickerOpen:false, engineOpen:false, execOpen:false, attachOpen:false,
        engine:null, schedule:null, catalog:null, config:null, lastExec:null, execMsgId:null,
        modelsFilter:'Recommended', detail:null, settingsPane:'Privacy', pendingAtts:[], sidebarOpen:true,
        onbStep:0, voice:null, prefs:{} };

/* ---------- persistence ---------- */
function loadChats(){ try{S.chats=JSON.parse(localStorage.getItem(LS)||"{}")}catch(e){S.chats={}} }
function saveChats(){ try{localStorage.setItem(LS,JSON.stringify(S.chats))}catch(e){} }
function loadPrefs(){ try{S.prefs=JSON.parse(localStorage.getItem(PREF)||"{}")}catch(e){S.prefs={}} if(S.prefs.sidebarOpen!==undefined)S.sidebarOpen=S.prefs.sidebarOpen; }
function savePrefs(){ try{localStorage.setItem(PREF,JSON.stringify(S.prefs))}catch(e){} }
function uid(){ return Date.now().toString(36)+Math.random().toString(36).slice(2,6); }
function cur(){ return S.chats[S.current]; }
function newChat(){ const id=uid(); S.chats[id]={id,title:"New chat",messages:[],created:Date.now()}; S.current=id; S.pendingAtts=[]; S.draft=''; S.focusInput=true; saveChats(); render(); }

/* ---------- API ---------- */
async function api(path){ try{ const r=await fetch(path); if(!r.ok) return null; return await r.json(); }catch(e){ return null; } }
async function refreshEngine(){ S.engine=await api('/v1/engine'); render(); }
async function refreshModels(){ const d=await api('/v1/models'); S.models=(d&&d.data||[]).map(m=>m.id); }
async function refreshCatalog(){ S.catalog=await api('/v1/catalog'); render(); }
async function refreshConfig(){ S.config=await api('/v1/config'); }
async function refreshSchedule(){ const opt={Balanced:'balanced',Quality:'high',Speed:'fast','Low Memory':'balanced'}[S.optimize]||'balanced';
  S.schedule=await api('/v1/schedule?goal=general&quality='+opt); render(); }

/* ---------- markdown + math (self-contained) ---------- */
function esc(s){ return s.replace(/[&<>]/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[m])); }
function mathify(s){ return s
  .replace(/\\\[\s*([\s\S]*?)\s*\\\]/g,(m,x)=>' '+x.trim()+' ').replace(/\\\(\s*([\s\S]*?)\s*\\\)/g,(m,x)=>x.trim())
  .replace(/\$\$([\s\S]*?)\$\$/g,(m,x)=>' '+x.trim()+' ').replace(/\\boxed\{([^{}]*)\}/g,(m,x)=>'【 '+x+' 】')
  .replace(/\\frac\{([^{}]*)\}\{([^{}]*)\}/g,(m,a,b)=>'('+a+')/('+b+')').replace(/\\sqrt\{([^{}]*)\}/g,(m,x)=>'√('+x+')')
  .replace(/\\text\{([^{}]*)\}/g,(m,x)=>x)
  .replace(/\\(times|cdot|div|pm|leq|geq|neq|approx|infty|rightarrow|to|alpha|beta|pi|sum)\b/g,(m,c)=>({times:'×',cdot:'·',div:'÷',pm:'±',leq:'≤',geq:'≥',neq:'≠',approx:'≈',infty:'∞',rightarrow:'→',to:'→',alpha:'α',beta:'β',pi:'π',sum:'∑'}[c]||m))
  .replace(/\\left|\\right|\\,|\\;|\\quad/g,' ').replace(/\\\\/g,'\n'); }
function mdInline(s){ return esc(mathify(s)).replace(/`([^`]+)`/g,'<code>$1</code>').replace(/\*\*([^*]+)\*\*/g,'<b>$1</b>'); }
function md(t){ const parts=t.split(/```/); let o=""; parts.forEach((p,i)=>{ if(i%2){ const nl=p.indexOf('\n'); o+='<pre><code>'+esc(nl>=0?p.slice(nl+1):p)+'</code></pre>'; } else o+=mdInline(p).replace(/\n/g,'<br>'); }); return o; }
function splitThink(t,o){ o=o||{}; const c=t.indexOf('</think>');
  if(c>=0){ let st=t.indexOf('<think>'); st=st<0?0:st+7; return {reason:t.slice(st,c).trim(), answer:t.slice(c+8).trim(), thinking:false}; }
  // Explicit <think> anywhere: everything after it is live reasoning until </think> (content-based, so
  // a model that reasons despite not being flagged still renders correctly).
  const op=t.indexOf('<think>');
  if(op>=0) return {reason:t.slice(op+7), answer:t.slice(0,op).trim(), thinking:true};
  // Implicit-open reasoning (only a trailing </think>): show live while streaming when expected.
  if(o.expectReasoning&&t) return {reason:t,answer:'',thinking:!!o.streaming}; return {reason:'',answer:t,thinking:false}; }
function looksReasoning(id){ return /deepseek-?r1|(^|[^a-z])r1([^a-z]|$)|qwq|magistral|thinking|reason/i.test(id||''); }
function fitColor(f){ return (f==='tight'||f==='unlikely')?'var(--amber)':'rgba(32,30,27,.7)'; }
function fitLabel(f){ return {comfortable:'Comfortable',fits:'Fits',tight:'Tight',unlikely:'Unlikely',unsupported:'Unsupported',unknown:'Unknown'}[f]||f; }

/* ---------- render ---------- */
function render(){ const app=$('#app'); app.innerHTML='';
  if(S.view==='onboarding'){ app.appendChild(renderOnboarding()); return; }
  if(S.view==='models'){ app.appendChild(renderModels()); if(S.detail) app.appendChild(renderDetail()); return; }
  if(S.view==='settings'){ app.appendChild(renderSettings()); return; }
  app.appendChild(renderChat());
  if(S.voice) app.appendChild(renderVoice());
}
function el(tag,attrs,html){ const e=document.createElement(tag); if(attrs) for(const k in attrs){ if(k==='cls')e.className=attrs[k]; else if(k==='on')e.onclick=attrs[k]; else e.setAttribute(k,attrs[k]); } if(html!=null)e.innerHTML=html; return e; }

/* ---------- action delegation (thin client: handlers are named, wired by data-act) ---------- */
const ACT={
  toggleSidebar:()=>{ S.sidebarOpen=!S.sidebarOpen; S.prefs.sidebarOpen=S.sidebarOpen; savePrefs(); render(); },
  newChat, openSettings:()=>{ closeAll(); S.view='settings'; refreshConfig().then(render); render(); },
  openModels:()=>{ closeAll(); S.view='models'; refreshCatalog(); render(); },
  backChat:()=>{ S.view='chat'; S.detail=null; render(); },
  togglePicker:()=>{ closeAll('pickerOpen'); render(); },
  toggleEngine:()=>{ closeAll('engineOpen'); if(S.engineOpen)refreshEngine(); render(); },
  toggleAttach:()=>{ closeAll('attachOpen'); render(); },
  pickModel:(v)=>{ S.modelSel=v; closeAll(); if(v==='Auto')refreshSchedule(); render(); },
  pickOptimize:(v)=>{ S.optimize=v; refreshSchedule(); render(); },
  openExec:(id)=>{ S.execMsgId=id; S.execOpen=true; render(); },
  closeExec:()=>{ S.execOpen=false; render(); },
  copyExec:(id)=>{ const m=cur().messages.find(x=>x.id===id); if(m&&m.exec){ try{ navigator.clipboard.writeText(JSON.stringify(m.exec.profile||m.exec,null,2)); }catch(e){} } },
  send:()=>send(), stop:()=>{ if(S.controller)S.controller.abort(); },
  switchChat:(id)=>{ S.current=id; render(); },
  startVoice:()=>{ S.voice='listening'; render(); },
  endVoice:()=>{ S.voice=null; render(); },
  voiceNext:()=>{ S.voice=S.voice==='listening'?'speaking':null; render(); },
  speak:(id)=>{ const m=cur().messages.find(x=>x.id===id); if(m)speak(m.content); },
  pickPane:(p)=>{ S.settingsPane=p; render(); },
  pickFilter:(f)=>{ S.modelsFilter=f; refreshCatalog(); render(); },
  openDetail:(id)=>{ S.detail=id; render(); },
  closeDetail:()=>{ S.detail=null; render(); },
  install:(id)=>{ ACT.openDetail(id); },
  attach:()=>{ document.getElementById('filepick').click(); S.attachOpen=false; render(); },
  removeAtt:(i)=>{ S.pendingAtts.splice(+i,1); render(); },
  micUpload:()=>micUpload(),
  toggleTts:()=>{ S.prefs.autoTts=!S.prefs.autoTts; savePrefs(); render(); }
};
function closeAll(open){ S.pickerOpen=false; S.engineOpen=false; S.attachOpen=false; if(open)S[open]=true; }
document.addEventListener('click',e=>{ const t=e.target.closest('[data-act]'); if(!t)return; const a=t.getAttribute('data-act'); const arg=t.getAttribute('data-arg'); if(ACT[a]){ e.stopPropagation(); ACT[a](arg); } });

/* ---------- chat view ---------- */
function renderChat(){
  const wrap=el('div',{cls:'app-inner'}); wrap.style.cssText='flex:1;display:flex;flex-direction:column;min-height:0';
  // top bar
  const tb=el('div',{cls:'topbar'});
  tb.innerHTML=`<button class="iconbtn" data-act="toggleSidebar" title="Sidebar">${ICON.sidebar}</button>
    <span class="brand">esh</span><span class="sp"></span>
    <button class="modelbtn" data-act="togglePicker">${esch(S.modelSel)}<span style="font-size:9px;color:var(--faint)">▾</span></button>
    <button class="iconbtn" data-act="openSettings" title="Settings">${ICON.settings}</button>`;
  wrap.appendChild(tb);
  const body=el('div',{cls:'body'});
  if(S.sidebarOpen) body.appendChild(renderSidebar());
  const main=el('div',{cls:'main'});
  const c=cur(); const has=c&&(c.messages.length||S.streaming);
  if(!has){ main.appendChild(el('div',{cls:'empty'},'What can I help with?')); }
  else main.appendChild(renderLog());
  main.appendChild(renderComposer());
  if(S.pickerOpen) main.appendChild(renderPicker());
  if(S.engineOpen) main.appendChild(renderEngine());
  body.appendChild(main);
  if(S.execOpen) body.appendChild(renderExec());
  wrap.appendChild(body);
  return wrap;
}
function esch(s){ return (s||'').replace(/[&<>]/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[m])); }
function renderSidebar(){
  const sb=el('div',{cls:'sidebar'});
  let h=`<button class="newchat" data-act="newChat">${ICON.plus}New chat</button>`;
  const list=Object.values(S.chats).sort((a,b)=>b.created-a.created);
  if(list.length) h+='<div class="sgroup" style="margin-top:0">Recent</div>';
  list.forEach(ch=>{ h+=`<div class="chatitem ${ch.id===S.current?'active':''}" data-act="switchChat" data-arg="${ch.id}">${esch(ch.title||'New chat')}</div>`; });
  sb.innerHTML=h; return sb;
}
const _seen=new Set();
function streamInner(){ const s=splitThink(S.streamText,{streaming:true,expectReasoning:S.streamReason}); let inner='';
  if(s.reason||s.thinking) inner+=`<details class="reason" open><summary class="live">Thinking…</summary><div class="rc">${esch(s.reason)}</div></details>`;
  if(s.answer) inner+=`<div class="asttext">${md(s.answer)}<span class="caret"></span></div>`;
  else if(!s.reason) inner+='<div class="asttext"><span class="typing"><i></i><i></i><i></i></span></div>';
  return inner; }
function renderLog(){
  const log=el('div',{cls:'log'}); const th=el('div',{cls:'thread'}); const c=cur();
  (c?c.messages:[]).forEach(m=>{ th.appendChild(renderMsg(m)); });
  if(S.streaming){ const d=el('div',{cls:'msg'}); d.innerHTML=`<div class="asst" id="streamwrap">${streamInner()}</div>`; th.appendChild(d); }
  log.appendChild(th);
  setTimeout(()=>{ log.scrollTop=log.scrollHeight; },0);
  return log;
}
function renderMsg(m){
  const fresh=m.id&&!_seen.has(m.id); if(m.id)_seen.add(m.id);
  const d=el('div',{cls:'msg'+(fresh?' msgin':'')});
  if(m.isUser||m.role==='user'){ let a=''; (m.attachments||[]).forEach(x=>{ if(x.kind==='image')a+=`<img src="${x.dataURL}">`; else if(x.kind==='audio')a+=`<audio controls src="${x.dataURL}"></audio>`; });
    d.innerHTML=`<div class="userrow"><div class="userbubble">${md(m.content||'')}${a}</div></div>`; return d; }
  if(m.isError){ d.innerHTML=`<div class="errcard"><div class="t">${esch(m.title||'Something went wrong')}</div><div class="d">${esch(m.detail||'')}</div></div>`; return d; }
  const s=splitThink(m.content,{streaming:false,expectReasoning:m.reasoning});
  let h='<div class="asst">';
  if(s.reason){ const label=m.thinkMs?('Reasoning · '+Math.round(m.thinkMs)+'s'):'Reasoning';
    h+=`<details class="reason"><summary>${label}</summary><div class="rc">${esch(s.reason)}</div></details>`; }
  const ans=s.answer||(s.thinking?'':m.content);
  if(ans) h+=`<div class="asttext">${md(ans)}</div>`;
  if(m.truncated) h+=`<div class="reason" style="color:var(--amber)">⚠ Stopped at the token limit — raise Max tokens in Settings.</div>`;
  if(m.meta) h+=`<div class="metaline" data-act="openExec" data-arg="${m.id}">${esch(m.meta)}</div>`;
  h+='</div>'; d.innerHTML=h; return d;
}
function renderComposer(){
  const c=el('div',{cls:'composer'});
  const eng=S.engine; const statusLabel=eng?(eng.status==='ok'?'Local · Private · Ready':'Local · Degraded'):'Local · …';
  c.innerHTML=`<div class="cbox">
     ${S.pendingAtts.length?renderChips():''}
     <div style="display:flex;align-items:center;gap:10px">
       <button class="cround" data-act="attach" title="Attach">${ICON.plus}</button>
       <textarea class="cinput" id="input" rows="1" placeholder="Ask anything…"></textarea>
       <button class="cround" style="border:none" data-act="startVoice" title="Voice">${ICON.mic}</button>
       ${S.streaming?`<button class="send" data-act="stop" title="Stop" style="background:var(--ink)">${ICON.stop}</button>`:(()=>{ const on=!!((S.draft&&S.draft.trim())||S.pendingAtts.length); return `<button class="send" id="sendbtn" data-act="send" title="Send" style="background:${on?'var(--ink)':'#dedbd4'};cursor:${on?'pointer':'default'}">${ICON.up}</button>`; })()}
     </div>
     ${S.attachOpen?renderAttach():''}
     <input type="file" id="filepick" accept="image/*,audio/*,.txt,.md,.json,.csv,.pdf" multiple style="display:none">
   </div>
   <div class="statusrow"><button class="statusbtn" data-act="toggleEngine"><span class="dot"></span>${esch(statusLabel)}</button></div>`;
  setTimeout(()=>{ const ta=$('#input'); if(ta){ ta.value=S.draft||'';
     ta.oninput=()=>{ S.draft=ta.value; ta.style.height='auto'; ta.style.height=Math.min(160,ta.scrollHeight)+'px'; updateSendState(); };
     ta.onkeydown=e=>{ if(e.key==='Enter'&&!e.shiftKey){ e.preventDefault(); send(); } };
     const fp=$('#filepick'); if(fp) fp.onchange=onFiles; updateSendState();
     if(S.focusInput&&S.view==='chat'){ S.focusInput=false; ta.focus(); } } },0);
  return c;
}
function updateSendState(){ const b=document.querySelector('#sendbtn'); if(!b)return; const on=!!((S.draft&&S.draft.trim())||S.pendingAtts.length);
  b.style.background=on?'var(--ink)':'#dedbd4'; b.style.cursor=on?'pointer':'default'; b.setAttribute('aria-disabled',on?'false':'true'); }
function renderChips(){ let h='<div style="display:flex;flex-wrap:wrap;gap:8px;margin-bottom:9px">';
  S.pendingAtts.forEach((a,i)=>{ const ic=a.kind==='image'?'<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.8"><rect x="3" y="4" width="18" height="16" rx="2"/><circle cx="8.5" cy="9.5" r="1.6"/><path d="M4 17l5-4 4 3 3-2 4 3"/></svg>':a.kind==='audio'?'<svg width="15" height="15" viewBox="0 0 24 24" fill="#fff"><rect x="4" y="9" width="2.4" height="6" rx="1"/><rect x="8.4" y="6" width="2.4" height="12" rx="1"/><rect x="12.8" y="8" width="2.4" height="8" rx="1"/><rect x="17.2" y="10" width="2.4" height="4" rx="1"/></svg>':'<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.8"><path d="M7 3h7l4 4v14H7z"/><path d="M14 3v4h4"/></svg>';
    h+=`<div style="display:flex;align-items:center;gap:9px;background:var(--panel2);border:1px solid var(--line);border-radius:10px;padding:8px 10px 8px 8px">
      <span style="width:30px;height:30px;border-radius:7px;background:var(--ink);display:flex;align-items:center;justify-content:center;flex-shrink:0">${ic}</span>
      <span style="min-width:0"><div style="font-size:12.5px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:150px">${esch(a.name)}</div><div class="mono" style="font-size:10.5px;color:var(--muted)">${esch(a.size||'')}</div></span>
      <span class="iconbtn" data-act="removeAtt" data-arg="${i}" style="padding:2px;font-size:14px">✕</span></div>`; });
  return h+'</div>'; }
function renderAttach(){
  const note=S.modelSel==='Auto'?'Auto — resolved per request':S.modelSel;
  return `<div class="pop" style="left:0;bottom:56px;width:230px;padding:6px 0">
    <div class="menurow" data-act="attach"><span style="width:16px;height:16px;border:1.5px solid rgba(32,30,27,.35);border-radius:4px"></span>Photo or image</div>
    <div class="menurow" data-act="attach"><span style="width:16px;height:16px;border:1.5px solid rgba(32,30,27,.35);border-radius:2px"></span>Document or text</div>
    <div class="menurow" data-act="micUpload"><span style="width:16px;height:16px;border:1.5px solid rgba(32,30,27,.35);border-radius:50%"></span>Audio file (transcribe)</div>
    <div style="padding:8px 16px 6px;font-size:11px;color:var(--faint);border-top:1px solid var(--line);margin-top:4px">Shown for ${esch(note)}</div></div>`;
}
function renderPicker(){
  const p=el('div',{cls:'pop'}); p.style.cssText+='top:6px;right:48px;width:300px;padding:8px 0';
  const auto=S.modelSel==='Auto';
  let h=`<div class="menurow" style="margin:4px 8px;padding:10px 12px;border-radius:9px;background:${auto?'rgba(32,30,27,.06)':'transparent'}" data-act="pickModel" data-arg="Auto">
     <div style="width:100%"><div style="display:flex;align-items:center;gap:8px"><span style="font-size:13.5px;font-weight:600">Auto</span><span class="sp" style="flex:1"></span><span style="font-size:10.5px;color:var(--muted);font-weight:500">Recommended</span>${auto?'<span>✓</span>':''}</div>
     <div style="font-size:11.5px;color:var(--muted);margin-top:2px">${S.schedule&&S.schedule.selectedModelID?('esh picks per request — now: '+shortModel(S.schedule.selectedModelID)):'esh picks the best model for each request'}</div></div></div>
   <div class="menuhead">Optimize for</div><div style="padding:2px 20px 8px;display:flex;flex-direction:column;gap:8px;font-size:13px">`;
  ['Balanced','Quality','Speed','Low Memory'].forEach(o=>{ const on=o===S.optimize;
    h+=`<div style="display:flex;align-items:center;gap:9px;cursor:pointer;color:${on?'var(--ink)':'var(--muted)'}" data-act="pickOptimize" data-arg="${o}"><span class="radio ${on?'on':''}"></span>${o}</div>`; });
  h+='</div><div class="sep"></div><div class="menuhead">Installed</div>';
  S.models.forEach(id=>{ const sel=S.modelSel===id; h+=`<div class="menurow" data-act="pickModel" data-arg="${id}">${esch(shortModel(id))}<span class="sp" style="flex:1"></span>${sel?'<span>✓</span>':''}</div>`; });
  const apple=S.engine&&S.engine.appleIntelligence&&S.engine.appleIntelligence.available;
  if(apple){ h+='<div class="menuhead">Built into this Mac</div>'+`<div class="menurow" data-act="pickModel" data-arg="Apple Intelligence">Apple Intelligence<span class="sp" style="flex:1"></span>${S.modelSel==='Apple Intelligence'?'<span>✓</span>':''}</div>`; }
  h+='<div class="sep"></div><div class="menurow" data-act="openModels">Browse models…</div><div class="menurow" data-act="openModels">Manage models…</div>';
  p.innerHTML=h; return p;
}
function shortModel(id){ return id.replace(/^mlx-community--/,'').replace(/^bartowski--/,'').replace(/-4bit$/,'').replace(/-instruct/i,''); }
function renderEngine(){
  const e=S.engine; const p=el('div',{cls:'pop'}); p.style.cssText+='bottom:56px;left:50%;transform:translateX(-50%);width:330px';
  if(!e){ p.innerHTML='<div style="padding:20px;font-size:13px;color:var(--muted)">Loading engine status…</div>'; return p; }
  const mem=e.host||{}; const memGB=mem.totalMemoryGB||0; const storage=e.storage||{};
  const engines=(e.engines||[]).map(x=>`<span class="mono" style="font-size:11.5px">${x.id} ${x.ready?'✓':'—'}</span>`).join('');
  let h=`<div class="panelhead"><span class="dot"></span><span style="margin-left:8px">Engine</span><span class="sp" style="flex:1"></span><span class="iconbtn" data-act="toggleEngine" style="font-size:13px">✕</span></div>
    <div style="padding:0 20px 12px;display:flex;flex-direction:column;gap:8px">
      <div class="kv"><span class="k">Chip</span><span>${esch(mem.chipDescription||'Apple Silicon')}</span></div>
      <div class="kv"><span class="k">Unified memory</span><span class="mono" style="font-size:12px">${memGB} GB</span></div>
      <div class="kv"><span class="k">Inference</span><span>On this Mac</span></div>
      <div class="kv"><span class="k">Storage</span><span>${esch(storage.status||storage.assetsRoot||'—')}</span></div>
      <div class="kv"><span class="k">Apple Intelligence</span><span>${e.appleIntelligence&&e.appleIntelligence.available?'Available':'Unavailable'}</span></div>
      <div style="display:flex;gap:14px;margin-top:2px">${engines}</div>
    </div>`;
  p.innerHTML=h; return p;
}
function renderExec(){
  const m=cur()?cur().messages.find(x=>x.id===S.execMsgId):null;
  const p=el('div',{cls:'rightpanel'});
  const ex=m&&m.exec||{}; const pr=ex.profile||{}; const sch=ex.schedule||{}; const why=(sch.rationale||[]);
  const src=ex.profile?'server':'measured in-browser';
  let h=`<div class="panelhead">Execution<span class="sp" style="flex:1"></span><span class="iconbtn" data-act="closeExec" style="font-size:13px">✕</span></div>
    <div style="padding:0 20px 8px;display:flex;flex-direction:column;gap:9px">`;
  h+=kvrow('Model',ex.model||shortModel(S.modelSel));
  h+=kvrow('Backend',ex.backend||'—',true);
  h+=kvrow('Mode',(ex.schedule?('Auto · '+(ex.optimize||'Balanced')):'Manual'));
  if(ex.ttftMs) h+=kvrow('Time to first token',ex.ttftMs+' ms',true);
  h+=kvrow('Total time',((ex.totalMs||0)/1000).toFixed(1)+' s',true);
  if(ex.tps) h+=kvrow('Generation',ex.tps.toFixed(0)+' tok/s',true);
  h+=kvrow('Output tokens',ex.outTok||'—',true);
  if(pr.inputTokens!=null) h+=kvrow('Input tokens',pr.inputTokens,true);
  if(pr.reasoningTokens!=null) h+=kvrow('Reasoning tokens',pr.reasoningTokens,true);
  if(pr.cachedTokens!=null) h+=kvrow('Cached tokens',pr.cachedTokens,true);
  if(pr.contextTokens!=null) h+=kvrow('Context',pr.contextTokens+(pr.contextWindow?(' / '+pr.contextWindow):''),true);
  if(pr.residency) h+=kvrow('Residency',pr.residency);
  if(pr.promptCache) h+=kvrow('Prompt cache',pr.promptCache);
  if(pr.optimization||sch.performanceMode) h+=kvrow('Optimizer',pr.optimization||sch.performanceMode);
  h+=`<div style="font:400 10.5px var(--mono);color:var(--faint);margin-top:2px">${src} · $0 · on-device</div>`;
  h+='</div>';
  h+=`<div style="margin:10px 20px 0;border-top:1px solid rgba(32,30,27,.07);padding:14px 0 4px;font-size:13px;font-weight:600">Why this model?</div>
     <div style="padding:6px 20px 14px;display:flex;flex-direction:column;gap:7px;font-size:12.5px;line-height:1.45;color:rgba(32,30,27,.8)">`;
  if(why.length){ why.slice(0,6).forEach(r=>{ h+=`<div style="display:flex;gap:8px"><span>·</span>${esch(r)}</div>`; }); }
  else h+='<div style="color:var(--muted)">This response used the model you selected manually.</div>';
  h+='</div>';
  if(ex.profile) h+=`<div class="menurow" style="border-top:1px solid rgba(32,30,27,.07);font:400 11px var(--mono)" data-act="copyExec" data-arg="${m.id}">Copy ExecutionProfile JSON</div>`;
  p.innerHTML=h; return p;
}
function kvrow(k,v,mono){ return `<div class="kv"><span class="k">${k}</span><span ${mono?'class="mono" style="font-size:12px"':''}>${esch(String(v))}</span></div>`; }

/* ---------- models browser ---------- */
function renderModels(){
  const v=el('div'); v.style.cssText='flex:1;display:flex;flex-direction:column;min-height:0';
  const chips=['Recommended','Installed','Coding','Reasoning','Vision','Fast','Long Context','Low Memory','Maximum Quality'];
  let h=`<div class="viewhead"><button class="backbtn" data-act="backChat">${ICON.back}Chat</button><span style="font-size:17px;font-weight:600">Models</span><span class="sp" style="flex:1"></span></div>
    <div style="display:flex;gap:6px;padding:14px 24px 16px;flex-wrap:wrap">`;
  chips.forEach(c=>{ h+=`<button class="chip ${c===S.modelsFilter?'on':''}" data-act="pickFilter" data-arg="${c}">${c}</button>`; });
  h+='</div><div style="border-top:1px solid var(--line);overflow-y:auto;flex:1">';
  const cat=S.catalog; if(!cat){ h+='<div style="padding:24px;color:var(--muted);font-size:13px">Loading catalog…</div>'; }
  else { (cat.models||[]).forEach(m=>{
    const speed=m.measured?(m.tokensPerSecond?m.tokensPerSecond.toFixed(0)+' tok/s ●':'measured ●'):(m.status==='incompatible'?'—':'estimate');
    const right=m.installed?'<span style="font-size:12px;color:var(--muted);text-align:right">Installed ✓</span>':(m.status==='incompatible'?'<span style="font-size:12px;color:var(--amber);text-align:right">Incompatible</span>':`<span style="font-size:12px;text-align:right;font-weight:500;cursor:pointer;text-decoration:underline" data-act="install" data-arg="${m.id}">Install</span>`);
    const shortDesc=(m.capabilities||[]).map(cap=>({chat:'General',coding:'Coding',reasoning:'Reasoning',toolCalling:'Tools','tool-calling':'Tools',vision:'Vision'}[cap]||cap)).join(' · ');
    h+=`<div class="mrow">
      <div class="mleft" data-act="openDetail" data-arg="${m.id}"><div class="mname">${esch(m.name)} ${m.badge?`<span style="font-size:11px;font-weight:500;margin-left:6px;color:var(--muted)">★</span>`:''}</div><div class="mdesc">${esch(shortDesc)} · ${m.parameterSize}</div></div>
      <div class="mmeta">
        <span class="mfit" style="color:${fitColor(m.fitClass)}">${fitLabel(m.fitClass)}</span>
        <span class="mmem mono" style="font-size:12px;color:var(--muted)">~${m.estimatedMemoryGB} GB</span>
        <span class="mspeed mono" style="font-size:12px;color:var(--muted)">${esch(speed)}</span>
        <span class="maction">${right}</span>
      </div></div>`; });
    h+=`<div style="padding:10px 24px;font-size:11px;color:var(--faint)">${esch(cat.measuredNote||'')}</div>`;
  }
  h+='</div>'; v.innerHTML=h; return v;
}
function renderDetail(){
  const m=(S.catalog&&S.catalog.models||[]).find(x=>x.id===S.detail); if(!m) return el('div',{cls:'hidden'});
  const ov=el('div',{cls:'overlay',on:()=>{ S.detail=null; render(); }});
  const tight=m.fitClass==='tight'||m.fitClass==='unlikely';
  const md_=el('div',{cls:'modal'}); md_.style.width='520px'; md_.onclick=e=>e.stopPropagation();
  let h=`<div style="padding:22px 26px 0;display:flex;align-items:flex-start"><div><div style="font-size:18px;font-weight:600">${esch(m.name)}</div>
    <div style="display:flex;align-items:center;gap:8px;margin-top:10px"><span style="font-size:11px;color:var(--muted)">Fit for this Mac</span><span class="mono" style="font-size:10.5px;letter-spacing:.08em;color:${tight?'var(--amber)':'var(--ink)'};background:${tight?'rgba(176,118,31,.1)':'rgba(32,30,27,.07)'};padding:3px 8px;border-radius:5px">${fitLabel(m.fitClass).toUpperCase()}</span></div></div>
    <span class="sp" style="flex:1"></span><span class="iconbtn" data-act="closeDetail" style="font-size:13px">✕</span></div>
    <div style="display:flex;gap:36px;padding:18px 26px 4px">
      <div style="display:flex;flex-direction:column;gap:7px;font-size:12.5px;min-width:180px">
        <div class="kv"><span class="k">Capabilities</span><span>${esch((m.capabilities||[]).join(', '))}</span></div>
        <div class="kv"><span class="k">Backend</span><span class="mono" style="font-size:12px">${esch(m.backend)}</span></div>
        <div class="kv"><span class="k">Parameters</span><span>${esch(m.parameterSize)}</span></div>
        <div class="kv"><span class="k">Quantization</span><span>${esch(m.quantization)}</span></div>
      </div>
      <div style="display:flex;flex-direction:column;gap:7px;font-size:12.5px;flex:1">
        <div class="kv"><span class="k">Download</span><span class="mono" style="font-size:12px">${m.downloadGB} GB</span></div>
        <div class="kv"><span class="k">Expected memory</span><span class="mono" style="font-size:12px">~${m.estimatedMemoryGB} GB</span></div>
        <div class="kv"><span class="k">Your Mac</span><span class="mono" style="font-size:12px">${(S.engine&&S.engine.host&&S.engine.host.totalMemoryGB)||'?'} GB</span></div>
        <div class="kv"><span class="k">Recommended context</span><span class="mono" style="font-size:12px">${m.recommendedContext?(Math.round(m.recommendedContext/1024)+'K'):'—'}</span></div>
        <div class="kv"><span class="k">Speed</span><span class="mono" style="font-size:12px">${m.measured&&m.tokensPerSecond?(m.tokensPerSecond.toFixed(0)+' tok/s ●'):'estimated'}</span></div>
      </div></div>`;
  if(tight) h+=`<div class="warnbox" style="margin:14px 26px 0">Expected memory is high for this Mac. It will run, but generation may slow and other apps may be paged out. A lower-memory quantization is suggested first.</div>`;
  if(m.status==='incompatible') h+=`<div class="warnbox" style="margin:14px 26px 0;border-color:rgba(176,118,31,.5)">This model is not compatible with the current runtime and cannot be installed.</div>`;
  h+=`<div style="display:flex;align-items:center;gap:14px;padding:18px 26px 20px">`;
  if(m.installed) h+='<span style="font-size:13px;color:var(--muted)">Installed ✓</span>';
  else if(m.status!=='incompatible') h+=`<button class="btn" data-act="install" data-arg="${m.id}">${tight?'Install anyway':'Install'}</button><span style="font-size:12px;color:var(--muted)">${esch(storageDest())}</span>`;
  h+='<span class="sp" style="flex:1"></span></div>';
  md_.innerHTML=h; ov.appendChild(md_); return ov;
}
function storageDest(){ const s=S.engine&&S.engine.storage; return s&&s.assetsRoot?('→ '+s.assetsRoot):'to model storage'; }

/* ---------- settings ---------- */
function renderSettings(){
  const v=el('div'); v.style.cssText='flex:1;display:flex;flex-direction:column;min-height:0';
  const panes=['General','Intelligence','Models','Voice','Performance','Storage','Privacy','Advanced'];
  let side=''; panes.forEach(p=>{ side+=`<div class="paneitem ${p===S.settingsPane?'on':''}" data-act="pickPane" data-arg="${p}">${p}</div>`; });
  v.innerHTML=`<div class="viewhead" style="padding-bottom:16px"><button class="backbtn" data-act="backChat">${ICON.back}Chat</button><span style="font-size:17px;font-weight:600">Settings</span></div>
    <div style="flex:1;display:flex;border-top:1px solid var(--line);min-height:0">
      <div class="paneside">${side}</div>
      <div style="flex:1;padding:22px 32px;overflow-y:auto">${renderPane()}</div></div>`;
  return v;
}
function renderPane(){
  const p=S.settingsPane, e=S.engine||{}, host=e.host||{};
  if(p==='Privacy') return `<div style="font-size:15px;font-weight:600;margin-bottom:18px">Privacy</div>
    <div style="display:flex;flex-direction:column;gap:16px;max-width:440px">
      <div><div style="font-size:12px;color:var(--muted)">Inference</div><div style="display:flex;align-items:center;gap:7px;font-size:13.5px;margin-top:3px"><span class="dot"></span>On this Mac</div></div>
      <div><div style="font-size:12px;color:var(--muted)">Network access</div><div style="font-size:13.5px;margin-top:3px">Model downloads and update checks only</div></div>
      <div><div style="font-size:12px;color:var(--muted)">Conversation history</div><div style="font-size:13.5px;margin-top:3px">Stored locally in this browser, never uploaded</div></div>
      <div style="border-top:1px solid rgba(32,30,27,.07);padding-top:14px"><div style="font-size:12px;color:var(--muted)">Apple Intelligence</div><div style="font-size:13px;line-height:1.5;margin-top:3px;color:rgba(32,30,27,.75)">The built-in Apple model runs on-device. If a future Apple feature uses Private Cloud Compute, esh will label it before use — it is never assumed.</div></div></div>`;
  if(p==='Performance'){ const opts=['Auto','Speed','Balanced','Low Memory']; let h=`<div style="font-size:15px;font-weight:600;margin-bottom:14px">Performance</div><div style="display:flex;flex-direction:column;gap:8px;font-size:13.5px;max-width:440px">`;
    opts.forEach(o=>{ const on=o===S.optimize; h+=`<div style="display:flex;align-items:center;gap:9px;cursor:pointer;color:${on?'var(--ink)':'var(--muted)'}" data-act="pickOptimize" data-arg="${o}"><span class="radio ${on?'on':''}"></span>${o}</div>`; });
    h+=`</div><div style="font-size:12px;color:var(--muted);margin-top:10px;line-height:1.5;max-width:440px">${({Auto:'esh adapts per request — quality when you wait, speed when you type fast.',Speed:'Prefers smaller resident models and aggressive caching for the fastest replies.',Balanced:'Keeps one model warm and favors quality unless a fast reply is clearly better.','Low Memory':'Unloads models promptly and caps cache size to leave room for other apps.'}[S.optimize])||''}</div>`; return h; }
  if(p==='Storage'){ const s=e.storage||{}; return `<div style="font-size:15px;font-weight:600;margin-bottom:14px">Storage</div><div style="max-width:440px">
      <div style="display:flex;align-items:baseline;gap:10px"><span style="font-size:14px;font-weight:600">${esch(s.label||s.assetsRoot||'Model storage')}</span><span style="font-size:11.5px;color:var(--muted)">${esch(s.status||'')}</span><span class="sp" style="flex:1"></span><span class="mono" style="font-size:12px;color:var(--muted)">${esch(s.freeSpace||'')}</span></div>
      <div style="font-size:11.5px;color:var(--muted);margin-top:14px;line-height:1.5">If the drive disconnects, installed models pause — nothing re-downloads internally without asking.</div></div>`; }
  if(p==='Voice') return `<div style="font-size:15px;font-weight:600;margin-bottom:14px">Voice</div>
    <div style="display:flex;flex-direction:column;gap:12px;font-size:13.5px;max-width:440px">
      <div style="display:flex;justify-content:space-between;align-items:center"><span>Read responses aloud</span><span class="toggle" data-act="toggleTts" style="background:${S.prefs.autoTts?'var(--ink)':'rgba(32,30,27,.2)'}"><span class="knob" style="left:${S.prefs.autoTts?'16px':'2px'}"></span></span></div>
      <div style="display:flex;justify-content:space-between;align-items:center"><span>Speech-to-text model</span><span class="mono" style="font-size:12px;color:var(--muted)">${esch((S.config&&S.config.defaults&&S.config.defaults.sttModel)||'parakeet (default)')}</span></div>
      <div style="display:flex;justify-content:space-between;align-items:center"><span>Voice (TTS) model</span><span class="mono" style="font-size:12px;color:var(--muted)">${esch((S.config&&S.config.defaults&&S.config.defaults.ttsModel)||'Soprano (default)')}</span></div></div>`;
  if(p==='Advanced'){ const srv=(e.server&&e.server.endpoint)||'http://127.0.0.1:11435'; return `<div style="font-size:15px;font-weight:600;margin-bottom:14px">Advanced</div><div style="max-width:480px">
      <div style="display:flex;align-items:center;gap:9px"><span style="font-size:13.5px;font-weight:600">API server</span><span class="sp" style="flex:1"></span><span class="dot"></span><span style="font-size:12px;color:var(--muted)">Running</span></div>
      <div style="margin-top:12px;display:flex;align-items:center;gap:10px;background:var(--panel2);border:1px solid var(--line);border-radius:8px;padding:10px 14px"><span class="mono" style="font-size:12.5px">${esch(srv)}</span></div>
      <div style="padding:12px 0 0;display:flex;gap:14px;font-size:12px;color:rgba(32,30,27,.65)"><span>✓ Native esh</span><span>✓ OpenAI-compatible</span></div>
      <div style="margin-top:8px;font-size:12px;color:var(--muted);line-height:1.5">Structured output, capability resolution and the Request Inspector are surfaced per response in the Execution panel.</div></div>`; }
  return `<div style="font-size:15px;font-weight:600;margin-bottom:10px">${p}</div><div style="font-size:13px;color:var(--muted)">Designed in the canvas — more controls arrive in a later rc.</div>`;
}

/* ---------- onboarding ---------- */
function renderOnboarding(){
  const v=el('div'); v.style.cssText='flex:1;display:flex;align-items:center;justify-content:center';
  const e=S.engine, host=e&&e.host||{};
  if(S.onbStep===0){ v.innerHTML=`<div style="display:flex;flex-direction:column;align-items:center;gap:14px;width:400px">
      <span style="width:44px;height:44px;border-radius:12px;background:var(--ink);color:#fff;display:flex;align-items:center;justify-content:center;font-size:18px;font-weight:600">e</span>
      <div style="font-size:21px;font-weight:600">Welcome to esh</div><div style="font-size:13.5px;color:var(--muted)">Private AI running on your Mac.</div>
      <button class="btn" style="margin-top:8px" onclick="S.onbStep=1;render()">Continue</button></div>`; }
  else if(S.onbStep===1){ const eng=(e&&e.engines||[]); const apple=e&&e.appleIntelligence&&e.appleIntelligence.available;
    v.innerHTML=`<div style="width:340px"><div style="font-size:11px;color:var(--muted)">This Mac</div>
      <div style="font-size:21px;font-weight:600;margin-top:4px">${esch(host.chipDescription||'Apple Silicon')}</div>
      <div style="font-size:13.5px;color:var(--muted)">${host.totalMemoryGB||'?'} GB unified memory</div>
      <div style="display:flex;flex-direction:column;gap:8px;margin-top:20px;font-size:13px">
        ${apple?'<div style="display:flex;gap:9px;align-items:center"><span style="color:var(--ink)">✓</span>Apple Intelligence available</div>':''}
        ${eng.filter(x=>x.ready).map(x=>`<div style="display:flex;gap:9px;align-items:center"><span style="color:var(--ink)">✓</span>${esch(x.id)} ready</div>`).join('')}
        ${(S.engine&&S.engine.storage&&S.engine.storage.external)?`<div style="display:flex;gap:9px;align-items:center"><span style="color:var(--ink)">✓</span>${esch(S.engine.storage.label||'External SSD')} detected</div>`:''}</div>
      <button class="btn" style="margin-top:24px" onclick="S.onbStep=2;render()">Continue</button></div>`; }
  else { v.innerHTML=`<div style="width:380px"><div style="font-size:17px;font-weight:600;margin-bottom:16px">You're ready</div>
      <div style="font-size:13.5px;color:var(--muted);line-height:1.5;margin-bottom:18px">Apple Intelligence gives you a zero-download start. Browse and install local models any time from the model picker.</div>
      <button class="btn" onclick="S.prefs.onboarded=true;savePrefs();S.view='chat';S.onbStep=0;S.focusInput=true;render()">Start chatting</button></div>`; }
  return v;
}

/* ---------- voice ---------- */
function renderVoice(){
  const v=el('div'); v.style.cssText='position:absolute;inset:0;background:var(--paper);display:flex;flex-direction:column;align-items:center;justify-content:center;gap:18px;z-index:60';
  if(S.voice==='listening'){ v.innerHTML=`<span data-act="voiceNext" style="width:84px;height:84px;border-radius:50%;background:rgba(32,30,27,.08);display:flex;align-items:center;justify-content:center;cursor:pointer;animation:eshpulse 1.6s ease-in-out infinite"><span style="width:38px;height:38px;border-radius:50%;background:var(--ink)"></span></span>
    <div style="font-size:16px;font-weight:500">Listening…</div><div style="font-size:12px;color:var(--faint)">Tap the circle to finish</div>`; }
  else { let bars=''; [14,30,20,36,16,26,12].forEach((hh,i)=>bars+=`<span style="width:4px;height:${hh}px;border-radius:2px;background:var(--ink);animation:eshbar .9s ${i*.12}s ease-in-out infinite"></span>`);
    v.innerHTML=`<div data-act="voiceNext" style="display:flex;align-items:center;gap:4px;height:44px;cursor:pointer">${bars}</div><div style="font-size:16px;font-weight:500">Speaking</div>`; }
  v.innerHTML+=`<div style="display:flex;gap:14px;margin-top:6px;font-size:12px;color:var(--muted)"><span class="btn ghost" style="padding:6px 14px" data-act="endVoice">Back to text</span><span class="btn ghost" style="padding:6px 14px" data-act="endVoice">End voice chat</span></div>`;
  return v;
}

/* ---------- send + streaming ---------- */
async function send(){
  const ta=$('#input'); const text=ta?ta.value.trim():(S.draft||'').trim();
  if((!text&&!S.pendingAtts.length)||S.controller) return;
  const c=cur()||(newChat(),cur());
  const atts=S.pendingAtts.slice(); S.pendingAtts=[];
  c.messages.push({id:uid(),role:'user',content:text,attachments:atts});
  if(c.title==='New chat'&&text) c.title=text.slice(0,40);
  S.draft=''; if(ta)ta.value='';
  // Auto routing runs through the real Scheduler: send its chosen model explicitly so the server uses
  // the model the UI shows (and reasoning detection matches the actual model).
  let resolved=S.modelSel;
  if(resolved==='Auto'){ const opt={Balanced:'balanced',Quality:'high',Speed:'fast','Low Memory':'balanced'}[S.optimize]||'balanced';
    const sc=await api('/v1/schedule?goal=general&quality='+opt); if(sc){ S.schedule=sc; if(sc.selectedModelID) resolved=sc.selectedModelID; } }
  const reasoning=looksReasoning(resolved);
  S.streaming=true; S.streamText=''; S.streamReason=reasoning; S.streamThinkMs=undefined; saveChats(); render();
  S.controller=new AbortController(); const t0=performance.now();
  const msgs=c.messages.filter(m=>m.role).map(m=>({role:m.role,content:m.content}));
  const body={ model: resolved==='Auto'?undefined:resolved, messages:msgs, stream:true, max_tokens:2048 };
  let truncated=false, ttft=0, execProfile=null;
  try{
    const resp=await fetch('/v1/chat/completions',{method:'POST',headers:{'Content-Type':'application/json'},signal:S.controller.signal,body:JSON.stringify(body)});
    if(!resp.ok||!resp.body){ S.streamText='error: HTTP '+resp.status; }
    else{ const rd=resp.body.getReader(),dec=new TextDecoder(); let buf='';
      while(true){ const {value,done}=await rd.read(); if(done)break; buf+=dec.decode(value,{stream:true}); const lines=buf.split('\n'); buf=lines.pop();
        for(const line of lines){ const s=line.trim(); if(!s.startsWith('data:'))continue; const d=s.slice(5).trim(); if(d==='[DONE]')continue;
          try{ const j=JSON.parse(d); if(j.esh_execution){ execProfile=j.esh_execution; continue; }
            if(j.choices&&j.choices[0]&&j.choices[0].finish_reason==='length')truncated=true;
            const del=j.choices&&j.choices[0]&&j.choices[0].delta&&j.choices[0].delta.content||''; if(del){ if(!ttft)ttft=performance.now()-t0; S.streamText+=del;
              if(S.streamThinkMs===undefined&&reasoning&&S.streamText.includes('</think>'))S.streamThinkMs=(performance.now()-t0)/1000;
              throttleRender(); } }catch(e){} } } }
  }catch(e){ if(e.name!=='AbortError') S.streamText+='\n[error] '+e.message; }
  const totalMs=performance.now()-t0; const secs=(totalMs/1000).toFixed(1);
  const auto=S.modelSel==='Auto';
  // Per-response execution truth: prefer the server's real ExecutionProfile (esh_execution event);
  // fall back to client-measured timing. Snapshot the scheduler decision that actually ran.
  const answerLen=(splitThink(S.streamText).answer||S.streamText).length;
  const outTok=execProfile&&execProfile.outputTokens||Math.max(1,Math.round(S.streamText.length/4));
  const genMs=Math.max(1,totalMs-(ttft||0));
  const exec={ model:shortModel(resolved||S.modelSel), fullModel:resolved||S.modelSel,
    backend:(execProfile&&execProfile.backend)||(S.schedule&&S.schedule.backend)||'',
    ttftMs:(execProfile&&execProfile.ttftMs)||Math.round(ttft), totalMs:Math.round(totalMs), outTok:outTok,
    tps:execProfile&&execProfile.tokensPerSecond||(outTok/(genMs/1000)),
    profile:execProfile, schedule:auto?S.schedule:null, optimize:S.optimize };
  c.messages.push({id:uid(),role:'assistant',content:S.streamText,reasoning:reasoning,thinkMs:S.streamThinkMs,truncated:truncated,
    meta:secs+'s'+(auto?' · '+shortModel(resolved||''):''), exec:exec});
  S.streaming=false; S.streamText=''; S.controller=null; saveChats(); render();
  if(S.prefs.autoTts) speak(S.streamText);
}
let _rt; function throttleRender(){ if(_rt)return; _rt=setTimeout(()=>{ _rt=null;
  // Update only the streaming bubble during generation (smooth, no whole-app rebuild/flicker).
  const sw=document.querySelector('#streamwrap');
  if(S.streaming&&sw){ sw.innerHTML=streamInner(); const lg=document.querySelector('.log'); if(lg)lg.scrollTop=lg.scrollHeight; }
  else render();
},40); }

/* ---------- speech ---------- */
async function speak(text){ const clean=splitThink(text).answer||text; if(!clean.trim())return;
  try{ const r=await fetch('/v1/audio/speech',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({input:clean.slice(0,2000)})});
    if(!r.ok)return; const b=await r.blob(); new Audio(URL.createObjectURL(b)).play(); }catch(e){} }
function fmtSize(b){ if(b<1024)return b+' B'; if(b<1048576)return (b/1024).toFixed(0)+' KB'; return (b/1048576).toFixed(1)+' MB'; }
function onFiles(e){ const files=[...e.target.files]; let pending=files.length; if(!pending)return;
  files.forEach(f=>{ const r=new FileReader(); r.onload=()=>{ const kind=f.type.startsWith('image')?'image':f.type.startsWith('audio')?'audio':'document';
    S.pendingAtts.push({kind,name:f.name,size:fmtSize(f.size),mime:f.type,dataURL:r.result}); if(--pending===0)render(); }; r.readAsDataURL(f); }); e.target.value=''; }
function micUpload(){ const inp=document.createElement('input'); inp.type='file'; inp.accept='audio/*';
  inp.onchange=async ev=>{ const f=ev.target.files[0]; if(!f)return; const r=new FileReader(); r.onload=async()=>{ try{ const resp=await fetch('/v1/audio/transcriptions',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({audio:r.result.split(',')[1],filename:f.name})}); if(resp.ok){ const d=await resp.json(); const ta=$('#input'); if(ta){ta.value+=(d.text||'');S.draft=ta.value;} } }catch(e){} }; r.readAsDataURL(f); }; inp.click(); }


/* ---------- boot ---------- */
loadChats(); loadPrefs();
if(!Object.keys(S.chats).length) newChat(); else S.current=Object.values(S.chats).sort((a,b)=>b.created-a.created)[0].id;
S.focusInput=true;
// First run (no prior prefs and no history) → show onboarding once, then remember.
if(!S.prefs.onboarded && Object.values(S.chats).every(c=>!c.messages.length)){ S.view='onboarding'; S.onbStep=0; }
refreshModels(); refreshEngine(); refreshSchedule();
render();
</script>
</body>
</html>
"""#
}
