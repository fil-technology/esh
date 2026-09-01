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
  @keyframes eshdot{0%,100%{transform:translateY(0);opacity:.35}50%{transform:translateY(-4px);opacity:1}}
  /* Voice — full conversational loop (listening → thinking → speaking → listening) */
  .voicewrap{ position:absolute; inset:0; background:var(--paper); display:flex; flex-direction:column; z-index:60; animation:eshfade .2s ease-out; }
  .vstage{ flex:1; display:flex; flex-direction:column; align-items:center; justify-content:center; gap:20px; padding:0 40px; }
  .vlabel{ font:500 10px var(--mono); letter-spacing:.14em; text-transform:uppercase; color:var(--faint); }
  .vlive{ font-size:17px; font-weight:500; line-height:1.5; max-width:560px; text-align:center; letter-spacing:-.01em; }
  .vquote{ font-size:13px; color:var(--faint); line-height:1.5; max-width:520px; text-align:center; }
  .vanswer{ font-size:14.5px; line-height:1.65; max-width:560px; color:rgba(32,30,27,.85); text-align:center; }
  .vhint{ font-size:12px; color:var(--faint); min-height:16px; }
  .vorb{ height:96px; display:flex; align-items:center; justify-content:center; cursor:pointer; }
  .vpulse{ width:84px; height:84px; border-radius:50%; background:rgba(32,30,27,.07); display:flex; align-items:center; justify-content:center; animation:eshpulse 1.6s ease-in-out infinite; }
  .vpulse>span{ width:36px; height:36px; border-radius:50%; background:var(--ink); }
  .vdots{ display:flex; gap:8px; } .vdots i{ width:9px; height:9px; border-radius:50%; background:var(--ink); animation:eshdot 1.1s ease-in-out infinite; }
  .vwave{ display:flex; align-items:center; gap:4px; cursor:pointer; } .vwave i{ width:4px; border-radius:2px; background:var(--ink); animation:eshbar .9s ease-in-out infinite; }
  .vctrls{ display:flex; justify-content:center; gap:22px; padding-bottom:36px; }
  .vctrlcol{ display:flex; flex-direction:column; align-items:center; gap:7px; }
  .vctrl{ width:44px; height:44px; border-radius:50%; display:flex; align-items:center; justify-content:center; cursor:pointer; }
  .vctrl.line{ border:1px solid rgba(32,30,27,.14); color:rgba(32,30,27,.7); background:#fff; }
  .vctrl.line:hover{ background:rgba(32,30,27,.05); }
  .vctrl.solid{ background:var(--ink); color:var(--paper); } .vctrl.solid:hover{ opacity:.85; }
  .vctrllbl{ font-size:10.5px; color:var(--faint); }
  .vfoot{ position:absolute; bottom:14px; left:0; right:0; display:flex; justify-content:center; font:400 10px var(--mono); color:rgba(32,30,27,.35); }
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
  /* In-composer controls: model chip + effort chip + divider before mic/send (progressive disclosure lives here) */
  .cchip{ display:flex; align-items:center; gap:5px; font-size:12.5px; color:rgba(32,30,27,.75); padding:5px 11px; border-radius:8px; cursor:pointer; white-space:nowrap; flex-shrink:0; border:none; background:rgba(32,30,27,.05); }
  .cchip:hover{ background:rgba(32,30,27,.09); }
  .cchip .chev{ font-size:8px; color:var(--faint); }
  .cchip.ghost{ background:none; } .cchip.ghost:hover{ background:rgba(32,30,27,.05); }
  .cchip .lbl{ max-width:150px; overflow:hidden; text-overflow:ellipsis; }
  .cdiv{ width:1px; height:16px; background:var(--line2); flex-shrink:0; }
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
  /* Model picker — one consistent row pattern: rounded highlight + right-aligned check on the selected row */
  .pickrow{ margin:2px 8px; padding:8px 12px; border-radius:9px; font-size:13px; cursor:pointer; display:flex; align-items:center; gap:8px; }
  .pickrow:hover{ background:rgba(32,30,27,.04); }
  .pickrow.sel{ background:rgba(32,30,27,.06); }
  .ck{ font-size:12px; line-height:1; } .resdot{ width:5px; height:5px; border-radius:50%; background:var(--ink); flex-shrink:0; }
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
  stop:'<svg width="11" height="11" viewBox="0 0 24 24" fill="currentColor"><rect x="6" y="6" width="12" height="12" rx="2"/></svg>',
  keyboard:'<svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"><rect x="3" y="7" width="18" height="11" rx="2.5"/><path d="M7 11h.5"/><path d="M11.75 11h.5"/><path d="M16.5 11h.5"/><path d="M8 14.5h8"/></svg>',
  xmark:'<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M6 6l12 12"/><path d="M18 6L6 18"/></svg>'
};
let S={ view:'chat', chats:{}, current:null, controller:null, streaming:false, streamText:'', streamThinkMs:undefined,
        models:[], modelSel:'Auto', optimize:'Balanced', pickerOpen:false, engineOpen:false, execOpen:false, attachOpen:false,
        engine:null, schedule:null, catalog:null, config:null, lastExec:null, execMsgId:null,
        modelsFilter:'Recommended', detail:null, settingsPane:'Privacy', pendingAtts:[], sidebarOpen:true,
        onbStep:0, voice:null, prefs:{}, installing:{}, effortOpen:false };

/* ---------- persistence ---------- */
function loadChats(){ try{S.chats=JSON.parse(localStorage.getItem(LS)||"{}")}catch(e){S.chats={}} }
function saveChats(){ if(S.prefs&&S.prefs.saveHistory===false)return; try{localStorage.setItem(LS,JSON.stringify(S.chats))}catch(e){} }
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
async function refreshConfig(){ S.config=await api('/v1/config');
  // Cross-client settings live in esh config (not the browser): reflect the persisted performance mode.
  const pm=S.config&&S.config.defaults&&S.config.defaults.performanceMode;
  if(pm){ S.optimize={auto:'Balanced',balanced:'Balanced',quality:'Quality',speed:'Speed','low-memory':'Low Memory',memory:'Low Memory'}[pm.toLowerCase()]||S.optimize; } }
async function postConfig(patch){ try{ const r=await fetch('/v1/config',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(patch)}); if(r.ok)S.config=await r.json(); }catch(e){} }
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
function render(){ renderView(); a11yPass(); }
function renderView(){ const app=$('#app'); app.innerHTML='';
  if(S.view==='onboarding'){ app.appendChild(renderOnboarding()); return; }
  if(S.view==='models'){ app.appendChild(renderModels()); if(S.detail) app.appendChild(renderDetail()); return; }
  if(S.view==='settings'){ app.appendChild(renderSettings()); return; }
  app.appendChild(renderChat());
  if(S.voice) app.appendChild(renderVoice());
}
// Make non-native interactive controls reachable + labeled for keyboard and screen-reader users.
function a11yPass(){ document.querySelectorAll('[data-act]').forEach(e=>{ if(e.tagName!=='BUTTON'&&e.tagName!=='A'){
    if(!e.hasAttribute('tabindex'))e.setAttribute('tabindex','0'); if(!e.hasAttribute('role'))e.setAttribute('role','button'); }
  if(!e.getAttribute('aria-label')){ const t=e.getAttribute('title')||e.textContent.trim(); if(t)e.setAttribute('aria-label',t.slice(0,60)); } }); }
function el(tag,attrs,html){ const e=document.createElement(tag); if(attrs) for(const k in attrs){ if(k==='cls')e.className=attrs[k]; else if(k==='on')e.onclick=attrs[k]; else e.setAttribute(k,attrs[k]); } if(html!=null)e.innerHTML=html; return e; }

/* ---------- action delegation (thin client: handlers are named, wired by data-act) ---------- */
const ACT={
  toggleSidebar:()=>{ S.sidebarOpen=!S.sidebarOpen; S.prefs.sidebarOpen=S.sidebarOpen; savePrefs(); render(); },
  newChat, openSettings:()=>{ closeAll(); S.view='settings'; refreshConfig().then(render); render(); },
  openModels:()=>{ closeAll(); S.view='models'; refreshCatalog(); render(); },
  backChat:()=>{ S.view='chat'; S.detail=null; render(); },
  togglePicker:()=>{ closeAll('pickerOpen'); render(); },
  toggleEffort:()=>{ closeAll('effortOpen'); render(); },
  pickEffort:(v)=>{ if(v==='Off'){ S.prefs.reasoning='Off'; } else { S.prefs.reasoning='Auto'; S.prefs.effort=v; } savePrefs(); render(); },
  toggleEngine:()=>{ closeAll('engineOpen'); if(S.engineOpen)refreshEngine(); render(); },
  toggleAttach:()=>{ closeAll('attachOpen'); render(); },
  pickModel:(v)=>{ S.modelSel=v; closeAll(); if(v==='Auto')refreshSchedule(); render(); },
  pickOptimize:(v)=>{ S.optimize=v; postConfig({performanceMode:v.toLowerCase()}); refreshSchedule(); render(); },
  openExec:(id)=>{ S.execMsgId=id; S.execOpen=true; render(); },
  closeExec:()=>{ S.execOpen=false; render(); },
  copyExec:(id)=>{ const m=cur().messages.find(x=>x.id===id); if(m&&m.exec){ try{ navigator.clipboard.writeText(JSON.stringify(m.exec.profile||m.exec,null,2)); }catch(e){} } },
  send:()=>send(), stop:()=>{ if(S.controller)S.controller.abort(); },
  retryLast:(t)=>{ const c=cur(); if(c&&c.messages.length&&c.messages[c.messages.length-1].isError)c.messages.pop(); sendText(t); },
  continueAuto:(t)=>{ const c=cur(); if(c&&c.messages.length&&c.messages[c.messages.length-1].isError)c.messages.pop(); S.modelSel='Auto'; refreshSchedule(); sendText(t); },
  switchChat:(id)=>{ S.current=id; render(); },
  startVoice:()=>startVoice(),
  endVoice:()=>{ endVoiceLoop(); render(); },
  voiceText:()=>{ endVoiceLoop(); S.focusInput=true; render(); },
  voiceFinish:()=>{ stopListening(); },
  voiceInterrupt:()=>{ clearVoiceReveal(); if(S.voiceAudio){try{S.voiceAudio.pause()}catch(e){}} startVoice(); },
  voiceRetry:()=>startVoice(),
  speak:(id)=>{ const m=cur().messages.find(x=>x.id===id); if(m)speak(m.content); },
  pickPane:(p)=>{ S.settingsPane=p; render(); },
  pickFilter:(f)=>{ S.modelsFilter=f; refreshCatalog(); render(); },
  openDetail:(id)=>{ S.detail=id; render(); },
  closeDetail:()=>{ S.detail=null; render(); },
  install:(id)=>{ ACT.openDetail(id); },
  doInstall:(id)=>startInstall(id),
  cancelInstall:(id)=>{ const m=catModel(id); if(m){ fetch('/v1/models/install/cancel',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id})}); } delete S.installing[id]; render(); },
  attach:()=>{ document.getElementById('filepick').click(); S.attachOpen=false; render(); },
  removeAtt:(i)=>{ S.pendingAtts.splice(+i,1); render(); },
  micUpload:()=>micUpload(),
  toggleTts:()=>{ S.prefs.autoTts=!S.prefs.autoTts; savePrefs(); render(); },
  toggleEnter:()=>{ S.prefs.sendEnter=!(S.prefs.sendEnter!==false); savePrefs(); render(); },
  toggleHistory:()=>{ S.prefs.saveHistory=!(S.prefs.saveHistory!==false); savePrefs(); if(S.prefs.saveHistory)saveChats(); render(); },
  clearHistory:()=>{ if(!confirm('Clear all conversations stored in this browser?'))return; S.chats={}; try{localStorage.removeItem(LS)}catch(e){} newChat(); },
  toggleRouting:()=>{ S.prefs.autoRouting=!(S.prefs.autoRouting!==false); savePrefs(); render(); },
  pickReasoning:(v)=>{ S.prefs.reasoning=v; savePrefs(); render(); },
  goPane:(p)=>{ S.settingsPane=p; render(); },
  editSysInstr:()=>{ const t=$('#sysinstr'); if(t){ S.prefs.systemInstr=t.value; savePrefs(); } }
};
function closeAll(open){ S.pickerOpen=false; S.engineOpen=false; S.attachOpen=false; S.effortOpen=false; if(open)S[open]=true; }
document.addEventListener('click',e=>{ const t=e.target.closest('[data-act]'); if(!t)return; const a=t.getAttribute('data-act'); const arg=t.getAttribute('data-arg'); if(ACT[a]){ e.stopPropagation(); ACT[a](arg); } });
// Keyboard: Escape unwinds the most-nested surface; Enter/Space activate focused data-act controls.
document.addEventListener('keydown',e=>{
  if(e.key==='Escape'){
    if(S.detail){ S.detail=null; render(); }
    else if(S.execOpen){ S.execOpen=false; render(); }
    else if(S.pickerOpen||S.engineOpen||S.attachOpen||S.effortOpen){ closeAll(); render(); }
    else if(S.voice){ ACT.endVoice(); }
    else if(S.view==='models'||S.view==='settings'){ S.view='chat'; render(); }
    return;
  }
  if((e.key==='Enter'||e.key===' ')){ const t=document.activeElement; if(t&&t.getAttribute&&t.getAttribute('data-act')&&t.tagName!=='TEXTAREA'&&t.tagName!=='INPUT'){ e.preventDefault(); const a=t.getAttribute('data-act'); if(ACT[a])ACT[a](t.getAttribute('data-arg')); } }
});

/* ---------- chat view ---------- */
function renderChat(){
  const wrap=el('div',{cls:'app-inner'}); wrap.style.cssText='flex:1;display:flex;flex-direction:column;min-height:0';
  // top bar
  const tb=el('div',{cls:'topbar'});
  // Header stays minimal: sidebar + brand + settings. The model picker and effort control live in the
  // composer (progressive disclosure at the point of use), matching the approved design.
  tb.innerHTML=`<button class="iconbtn" data-act="toggleSidebar" title="Sidebar">${ICON.sidebar}</button>
    <span class="brand">esh</span><span class="sp"></span>
    <button class="iconbtn" data-act="openSettings" title="Settings">${ICON.settings}</button>`;
  wrap.appendChild(tb);
  const body=el('div',{cls:'body'});
  if(S.sidebarOpen) body.appendChild(renderSidebar());
  const main=el('div',{cls:'main'});
  const c=cur(); const has=c&&(c.messages.length||S.streaming);
  if(!has){ main.appendChild(el('div',{cls:'empty'},'What can I help with?')); }
  else main.appendChild(renderLog());
  main.appendChild(renderComposer());
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
  if(m.isError){ d.innerHTML=`<div class="errcard"><div class="t">${esch(m.title||'Something went wrong')}</div>
    <div class="d">${esch(m.detail||'')}</div>
    <div class="d" style="margin-top:6px">Your conversation is safe — nothing was lost.</div>
    <div style="display:flex;gap:10px;margin-top:12px">
      <span class="btn" style="padding:7px 14px;font-size:12px" data-act="retryLast" data-arg="${esch(m.lastUser||'')}">Try again</span>
      <span class="btn ghost" style="padding:7px 14px;font-size:12px" data-act="continueAuto" data-arg="${esch(m.lastUser||'')}">Continue with Auto</span>
    </div></div>`; return d; }
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
// The status line under the composer surfaces what matters right now (a degraded storage/engine
// condition takes priority), and always opens the Engine menu. Real signals only — no fabricated states.
function statusInfo(){
  const e=S.engine, st=e&&e.storage||{};
  // External model storage reports storage.status==='available' when connected; anything else on an
  // external volume means it's disconnected/degraded — surface that first (real signal, never faked).
  const extDown=!!(st.external && st.status && st.status!=='available');
  const engDown=!!(e&&e.status&&e.status!=='ok'&&e.status!=='ready');
  if(extDown) return {label:'External storage disconnected',amber:true};
  const name=S.modelSel==='Auto' ? (S.schedule&&S.schedule.selectedModelID?shortModel(S.schedule.selectedModelID):'Auto')
                                 : (S.modelSel==='Apple Intelligence'?'Apple Intelligence':shortModel(S.modelSel));
  if(!e) return {label:'Local · …',amber:false};
  if(engDown) return {label:'Local · Degraded',amber:true};
  if(S.streaming) return {label:'Local · '+name+' · generating',amber:false};
  if(S.modelSel==='Apple Intelligence') return {label:'Local · Apple Intelligence',amber:false};
  const c=cur(); if(c&&c.messages.length) return {label:'Local · '+name+' warm',amber:false};
  return {label:'Local · Private · Ready',amber:false};
}
function renderComposer(){
  const c=el('div',{cls:'composer'});
  const si=statusInfo();
  const mlabel=S.modelSel==='Auto'?'Auto':(S.modelSel==='Apple Intelligence'?'Apple Intelligence':shortModel(S.modelSel));
  c.innerHTML=`<div class="cbox">
     ${S.pendingAtts.length?renderChips():''}
     <div style="display:flex;align-items:center;gap:10px">
       <button class="cround" data-act="attach" title="Attach">${ICON.plus}</button>
       <textarea class="cinput" id="input" rows="1" placeholder="Ask anything…"></textarea>
       <button class="cchip" data-act="togglePicker" title="Model"><span class="lbl">${esch(mlabel)}</span><span class="chev">▾</span></button>
       <button class="cchip ghost" data-act="toggleEffort" title="Effort">${esch(effortWord())}</button>
       <span class="cdiv"></span>
       <button class="cround" style="border:none" data-act="startVoice" title="Voice">${ICON.mic}</button>
       ${S.streaming?`<button class="send" data-act="stop" title="Stop" style="background:var(--ink)">${ICON.stop}</button>`:(()=>{ const on=!!((S.draft&&S.draft.trim())||S.pendingAtts.length); return `<button class="send" id="sendbtn" data-act="send" title="Send" style="background:${on?'var(--ink)':'#dedbd4'};cursor:${on?'pointer':'default'}">${ICON.up}</button>`; })()}
     </div>
     ${S.attachOpen?renderAttach():''}
     ${S.pickerOpen?renderPicker():''}
     ${S.effortOpen?renderEffort():''}
     <input type="file" id="filepick" accept="image/*,audio/*,.txt,.md,.json,.csv,.pdf" multiple style="display:none">
   </div>
   <div class="statusrow"><button class="statusbtn" data-act="toggleEngine" title="Engine status"><span class="dot" style="background:${si.amber?'var(--amber)':'var(--ink)'}"></span>${esch(si.label)}</button></div>`;
  setTimeout(()=>{ const ta=$('#input'); if(ta){ ta.value=S.draft||'';
     ta.oninput=()=>{ S.draft=ta.value; ta.style.height='auto'; ta.style.height=Math.min(160,ta.scrollHeight)+'px'; updateSendState(); };
     ta.onkeydown=e=>{ if(e.key!=='Enter')return; const enterSends=S.prefs.sendEnter!==false;
       if(enterSends&&!e.shiftKey){ e.preventDefault(); send(); }
       else if(!enterSends&&(e.metaKey||e.ctrlKey)){ e.preventDefault(); send(); } };
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
  return `<div class="pop" style="left:0;bottom:calc(100% + 10px);width:230px;padding:6px 0">
    <div class="menurow" data-act="attach"><span style="width:16px;height:16px;border:1.5px solid rgba(32,30,27,.35);border-radius:4px"></span>Photo or image</div>
    <div class="menurow" data-act="attach"><span style="width:16px;height:16px;border:1.5px solid rgba(32,30,27,.35);border-radius:2px"></span>Document or text</div>
    <div class="menurow" data-act="micUpload"><span style="width:16px;height:16px;border:1.5px solid rgba(32,30,27,.35);border-radius:50%"></span>Audio file (transcribe)</div>
    <div style="padding:8px 16px 6px;font-size:11px;color:var(--faint);border-top:1px solid var(--line);margin-top:4px">Shown for ${esch(note)}</div></div>`;
}
// One consistent row for the whole picker: rounded highlight + right-aligned check on the selected row,
// hover tint on the rest (no radios). `right` is optional trailing content before the check.
function pickRow(label,sel,act,arg,right){
  return `<div class="pickrow ${sel?'sel':''}" data-act="${act}" data-arg="${esch(arg)}"><span>${esch(label)}</span><span class="sp" style="flex:1"></span>${right||''}${sel?'<span class="ck">✓</span>':''}</div>`;
}
function renderPicker(){
  const auto=S.modelSel==='Auto';
  // Auto card (same row family, roomier).
  let h=`<div class="pickrow ${auto?'sel':''}" style="padding:10px 12px;flex-direction:column;align-items:stretch;gap:2px" data-act="pickModel" data-arg="Auto">
     <div style="display:flex;align-items:center;gap:8px"><span style="font-size:13.5px;font-weight:600">Auto</span><span class="sp" style="flex:1"></span><span style="font-size:10.5px;color:var(--muted);font-weight:500">Recommended</span>${auto?'<span class="ck">✓</span>':''}</div>
     <div style="font-size:11.5px;color:var(--muted)">${S.schedule&&S.schedule.selectedModelID?('esh picks per request — now: '+esch(shortModel(S.schedule.selectedModelID))):'esh picks the best model for each request'}</div></div>`;
  // Installed models (resident dot + check).
  if(S.models.length){ h+='<div class="menuhead">Installed</div>';
    S.models.forEach(id=>{ const sel=S.modelSel===id; const resident=S.engine&&S.engine.residentModelID&&(id===S.engine.residentModelID);
      h+=pickRow(shortModel(id),sel,'pickModel',id, resident?'<span class="resdot" title="Loaded"></span>':''); }); }
  // Apple Intelligence — built into this Mac.
  const apple=S.engine&&S.engine.appleIntelligence&&S.engine.appleIntelligence.available;
  if(apple){ h+='<div class="menuhead">Built into this Mac</div>'+pickRow('Apple Intelligence',S.modelSel==='Apple Intelligence','pickModel','Apple Intelligence'); }
  // Optimize-for — same highlight+check row pattern (no radios).
  h+='<div class="menuhead">Optimize for</div>';
  ['Balanced','Quality','Speed','Low Memory'].forEach(o=>{ h+=pickRow(o,o===S.optimize,'pickOptimize',o); });
  h+='<div class="sep"></div><div class="pickrow" data-act="openModels"><span>Browse models…</span></div><div class="pickrow" data-act="openModels"><span>Manage models…</span></div>';
  return '<div class="pop" style="right:0;bottom:calc(100% + 10px);width:320px;padding:10px 0">'+h+'</div>';
}
function shortModel(id){ return id.replace(/^mlx-community--/,'').replace(/^bartowski--/,'').replace(/-4bit$/,'').replace(/-instruct/i,''); }
// The effort chip is the reasoning control at the point of use — synced with Settings → Intelligence.
// "Off" means reasoning off; Low/Medium/High mean reason (Auto), with the level as the effort.
function effortWord(){ const r=S.prefs.reasoning||'Auto'; return r==='Off'?'Off':(S.prefs.effort||'Medium'); }
function renderEffort(){
  const stops=['Off','Low','Medium','High'], cur=effortWord();
  const idx=cur==='Off'?0:{Low:1,Medium:2,High:3}[cur]; const pct=((idx+0.5)/4*100)+'%';
  const hint={Off:'Answers immediately — no reasoning pass.',Low:'A quick reasoning pass for everyday questions.',Medium:'Balanced thinking time. The default.',High:'Takes noticeably longer to think. Best for hard problems.'}[cur];
  let dots='',labels='';
  stops.forEach(s=>{ dots+=`<div data-act="pickEffort" data-arg="${s}" style="flex:1;display:flex;align-items:center;justify-content:center;cursor:pointer"><span style="width:5px;height:5px;border-radius:50%;background:rgba(32,30,27,.25)"></span></div>`;
    const on=s===cur; labels+=`<div data-act="pickEffort" data-arg="${s}" style="flex:1;text-align:center;font-size:10.5px;cursor:pointer;color:${on?'var(--ink)':'var(--muted)'};font-weight:${on?'600':'400'}">${s}</div>`; });
  const inner=`<div style="display:flex;align-items:baseline;gap:9px"><span style="font-size:15px;font-weight:600">Effort</span><span style="font-size:13.5px;color:var(--muted)">${esch(cur)}</span></div>
    <div style="display:flex;justify-content:space-between;font-size:12px;color:var(--muted);margin:16px 0 4px"><span>Faster</span><span>Smarter</span></div>
    <div style="position:relative;height:30px">
      <div style="position:absolute;left:10px;right:10px;top:13px;height:4px;background:rgba(32,30,27,.1);border-radius:2px"></div>
      <div style="position:absolute;inset:0;display:flex">${dots}</div>
      <span style="position:absolute;top:4px;left:${pct};transform:translateX(-50%);width:22px;height:22px;border-radius:50%;background:#fff;border:1px solid rgba(32,30,27,.18);box-shadow:0 1px 5px rgba(32,30,27,.28);pointer-events:none;transition:left .15s"></span>
    </div>
    <div style="display:flex;margin-top:2px">${labels}</div>
    <div style="font-size:12px;color:var(--muted);line-height:1.5;margin-top:14px;min-height:34px">${esch(hint)}</div>`;
  return '<div class="pop" style="right:0;bottom:calc(100% + 10px);width:290px;padding:18px 20px;box-sizing:border-box">'+inner+'</div>';
}
function volLabel(path){ if(!path)return 'Model storage'; const m=path.match(/\/Volumes\/([^/]+)/); return m?m[1]:'Internal storage'; }
function gb(bytes){ return (bytes/1073741824).toFixed(bytes<10737418240?1:0)+' GB'; }
function renderEngine(){
  const e=S.engine; const p=el('div',{cls:'pop'}); p.style.cssText+='bottom:56px;left:50%;transform:translateX(-50%);width:340px';
  if(!e){ p.innerHTML='<div style="padding:20px;font-size:13px;color:var(--muted)">Loading engine status…</div>'; return p; }
  const host=e.host||{}; const st=e.storage||{}; const locs=st.locations||[];
  const byClass=c=>{ const l=locs.find(x=>x.storageClass===c); return l&&l.sizeBytes||0; };
  const modelsB=byClass('models'), cachesB=byClass('caches'), audioB=byClass('audio');
  const used=modelsB+cachesB+audioB; const free=st.freeBytes||0; const total=used+free;
  const seg=(v)=>total?Math.max(0,(v/total*100)).toFixed(1):0;
  const engines=(e.engines||[]).filter(x=>x.ready).map(x=>`<span class="mono" style="font-size:11.5px;color:var(--ink)">${esch(x.id)} ✓</span>`).join('');
  let h=`<div class="panelhead"><span class="dot"></span><span style="margin-left:8px">Engine</span><span class="sp" style="flex:1"></span><span class="iconbtn" data-act="toggleEngine" style="font-size:13px">✕</span></div>
    <div style="padding:0 20px 12px;display:flex;flex-direction:column;gap:8px">
      <div class="kv"><span class="k">Chip</span><span>${esch(host.chipDescription||'Apple Silicon')}</span></div>
      <div class="kv"><span class="k">Unified memory</span><span class="mono" style="font-size:12px">${host.totalMemoryGB||'?'} GB</span></div>
      <div class="kv"><span class="k">Inference</span><span style="display:flex;align-items:center;gap:6px"><span class="dot"></span>On this Mac</span></div>
      <div class="kv"><span class="k">Apple Intelligence</span><span>${e.appleIntelligence&&e.appleIntelligence.available?'Available':'Unavailable'}</span></div>
    </div>
    <div class="menuhead" style="padding-left:20px">Storage · ${esch(volLabel(st.assetsRoot))}${st.external?' (external)':''}</div>
    <div style="padding:2px 20px 4px">
      <div class="kv" style="margin-bottom:8px"><span class="k">Free</span><span class="mono" style="font-size:12px">${gb(free)} free</span></div>
      <div style="display:flex;height:8px;border-radius:4px;overflow:hidden;background:rgba(32,30,27,.07)"><div style="width:${seg(modelsB)}%;background:var(--ink)"></div><div style="width:${seg(cachesB)}%;background:#6f6b64"></div><div style="width:${seg(audioB)}%;background:#b5b1a8"></div></div>
      <div style="display:flex;gap:14px;font-size:11px;color:var(--muted);margin-top:8px">
        <span style="display:flex;align-items:center;gap:5px"><span style="width:7px;height:7px;border-radius:2px;background:var(--ink)"></span>Models ${gb(modelsB)}</span>
        <span style="display:flex;align-items:center;gap:5px"><span style="width:7px;height:7px;border-radius:2px;background:#6f6b64"></span>Caches ${gb(cachesB)}</span>
        <span style="display:flex;align-items:center;gap:5px"><span style="width:7px;height:7px;border-radius:2px;background:#b5b1a8"></span>Speech ${gb(audioB)}</span>
      </div>
    </div>
    <div style="padding:12px 20px 16px;display:flex;gap:14px">${engines}</div>`;
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

/* ---------- install (start + poll progress, thin over /v1/models/install) ---------- */
function catModel(id){ return (S.catalog&&S.catalog.models||[]).find(x=>x.id===id); }
function fmtBytes(b){ if(!b)return ''; if(b<1048576)return (b/1024).toFixed(0)+' KB'; if(b<1073741824)return (b/1048576).toFixed(0)+' MB'; return (b/1073741824).toFixed(1)+' GB'; }
async function startInstall(id){
  S.installing[id]={phase:'resolving',bytesDownloaded:0,percent:0}; render();
  try{ await fetch('/v1/models/install',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id})}); }catch(e){ S.installing[id]={phase:'failed',error:'Could not start install'}; render(); return; }
  const poll=async()=>{ if(!S.installing[id])return; try{ const st=await (await fetch('/v1/models/install?id='+encodeURIComponent(id))).json(); S.installing[id]=st;
      if(st.phase==='installed'){ setTimeout(()=>{ delete S.installing[id]; refreshCatalog(); },600); render(); return; }
      if(st.phase==='failed'||st.phase==='cancelled'){ render(); return; } }catch(e){}
    render(); setTimeout(poll,700); };
  setTimeout(poll,500);
}
function installCell(m){ const st=S.installing[m.id];
  if(st){ if(st.phase==='failed') return `<span style="font-size:12px;color:var(--amber)">Failed</span>`;
    const pct=st.percent||0; const label=st.totalBytes?(pct+'%'):fmtBytes(st.bytesDownloaded);
    return `<span style="display:inline-flex;align-items:center;gap:8px;justify-content:flex-end"><span style="width:60px;height:4px;background:rgba(32,30,27,.1);border-radius:2px"><span style="display:block;width:${pct}%;height:4px;background:var(--ink);border-radius:2px;transition:width .3s"></span></span><span class="mono" style="font-size:10.5px;color:var(--muted)">${esch(label||'…')}</span><span class="iconbtn" data-act="cancelInstall" data-arg="${m.id}" style="padding:0;font-size:12px" title="Cancel">✕</span></span>`; }
  if(m.installed) return '<span style="font-size:12px;color:var(--muted)">Installed ✓</span>';
  if(m.status==='incompatible') return '<span style="font-size:12px;color:var(--amber)">Incompatible</span>';
  return `<span style="font-size:12px;font-weight:500;cursor:pointer;text-decoration:underline" data-act="doInstall" data-arg="${m.id}">Install</span>`;
}

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
    const shortDesc=(m.capabilities||[]).map(cap=>({chat:'General',coding:'Coding',reasoning:'Reasoning',toolCalling:'Tools','tool-calling':'Tools',vision:'Vision'}[cap]||cap)).join(' · ');
    h+=`<div class="mrow">
      <div class="mleft" data-act="openDetail" data-arg="${m.id}"><div class="mname">${esch(m.name)} ${m.badge?`<span style="font-size:11px;font-weight:500;margin-left:6px;color:var(--muted)">★</span>`:''}</div><div class="mdesc">${esch(shortDesc)} · ${m.parameterSize}</div></div>
      <div class="mmeta">
        <span class="mfit" style="color:${fitColor(m.fitClass)}">${fitLabel(m.fitClass)}</span>
        <span class="mmem mono" style="font-size:12px;color:var(--muted)">~${m.estimatedMemoryGB} GB</span>
        <span class="mspeed mono" style="font-size:12px;color:var(--muted)">${esch(speed)}</span>
        <span class="maction">${installCell(m)}</span>
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
  const ist=S.installing[m.id];
  if(ist&&(ist.phase==='downloading'||ist.phase==='resolving'||ist.phase==='verifying')){
    const pct=ist.percent||0; const lab=ist.totalBytes?(pct+'% of '+fmtBytes(ist.totalBytes)):fmtBytes(ist.bytesDownloaded);
    h+=`<div style="flex:1;display:flex;flex-direction:column;gap:7px"><div style="height:5px;background:rgba(32,30,27,.08);border-radius:3px"><div style="width:${pct}%;height:5px;background:var(--ink);border-radius:3px;transition:width .3s"></div></div><div style="display:flex;justify-content:space-between;font-size:11.5px;color:var(--muted)"><span class="mono">${esch(ist.phase)} · ${esch(lab||'…')}</span><span>${esch(storageDest())}</span></div></div><span class="iconbtn" data-act="cancelInstall" data-arg="${m.id}" style="font-size:13px">✕</span>`;
  } else if(ist&&ist.phase==='failed'){ h+=`<span style="color:var(--amber);font-size:13px">Install failed — ${esch(ist.error||'try again')}</span><button class="btn ghost" data-act="doInstall" data-arg="${m.id}">Retry</button>`; }
  else if(m.installed) h+='<span style="font-size:13px;color:var(--muted)">Installed ✓</span>';
  else if(m.status!=='incompatible') h+=`<button class="btn" data-act="doInstall" data-arg="${m.id}">${tight?'Install anyway':'Install'}</button><span style="font-size:12px;color:var(--muted)">${esch(storageDest())}</span>`;
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
  if(p==='Storage'){ const s=e.storage||{}; const locs=s.locations||[]; const bc=c=>{const l=locs.find(x=>x.storageClass===c);return l&&l.sizeBytes||0;};
    const modelsB=bc('models'),cachesB=bc('caches'),audioB=bc('audio'),free=s.freeBytes||0,total=modelsB+cachesB+audioB+free;
    const seg=v=>total?(v/total*100).toFixed(1):0;
    return `<div style="font-size:15px;font-weight:600;margin-bottom:14px">Storage</div><div style="max-width:440px">
      <div style="display:flex;align-items:baseline;gap:10px"><span style="font-size:14px;font-weight:600">${esch(volLabel(s.assetsRoot))}</span><span style="font-size:11.5px;color:var(--muted)">${s.external?'External SSD · Connected':'Internal storage'}</span><span class="sp" style="flex:1"></span><span class="mono" style="font-size:12px;color:var(--muted)">${gb(free)} free</span></div>
      <div style="display:flex;height:8px;border-radius:4px;overflow:hidden;background:rgba(32,30,27,.07);margin:12px 0 10px"><div style="width:${seg(modelsB)}%;background:var(--ink)"></div><div style="width:${seg(cachesB)}%;background:#6f6b64"></div><div style="width:${seg(audioB)}%;background:#b5b1a8"></div></div>
      <div style="display:flex;gap:16px;font-size:11.5px;color:var(--muted)">
        <span style="display:flex;align-items:center;gap:5px"><span style="width:7px;height:7px;border-radius:2px;background:var(--ink)"></span>Models ${gb(modelsB)}</span>
        <span style="display:flex;align-items:center;gap:5px"><span style="width:7px;height:7px;border-radius:2px;background:#6f6b64"></span>Caches ${gb(cachesB)}</span>
        <span style="display:flex;align-items:center;gap:5px"><span style="width:7px;height:7px;border-radius:2px;background:#b5b1a8"></span>Speech ${gb(audioB)}</span></div>
      <div class="mono" style="font-size:11px;color:var(--faint);margin-top:12px">${esch(s.assetsRoot||'')}</div>
      <div style="font-size:11.5px;color:var(--muted);margin-top:14px;line-height:1.5">If the drive disconnects, installed models pause — nothing re-downloads internally without asking.</div></div>`; }
  if(p==='General'){ const enterOn=S.prefs.sendEnter!==false, histOn=S.prefs.saveHistory!==false; const n=Object.keys(S.chats).length;
    return `<div style="font-size:15px;font-weight:600;margin-bottom:18px">General</div><div style="display:flex;flex-direction:column;gap:18px;max-width:440px">
      <div style="display:flex;justify-content:space-between;align-items:center;font-size:13.5px"><span>Send with Enter<div style="font-size:11.5px;color:var(--muted);margin-top:2px">Off uses ⌘/Shift+Enter to send, Enter for a new line</div></span><span class="toggle" data-act="toggleEnter" style="background:${enterOn?'var(--ink)':'rgba(32,30,27,.2)'}"><span class="knob" style="left:${enterOn?'16px':'2px'}"></span></span></div>
      <div style="display:flex;justify-content:space-between;align-items:center;font-size:13.5px"><span>Save conversation history<div style="font-size:11.5px;color:var(--muted);margin-top:2px">Stored only in this browser</div></span><span class="toggle" data-act="toggleHistory" style="background:${histOn?'var(--ink)':'rgba(32,30,27,.2)'}"><span class="knob" style="left:${histOn?'16px':'2px'}"></span></span></div>
      <div style="border-top:1px solid rgba(32,30,27,.07);padding-top:14px;display:flex;justify-content:space-between;align-items:center">
        <div><div style="font-size:13.5px">Clear history</div><div style="font-size:11.5px;color:var(--muted);margin-top:2px">${n} conversation${n===1?'':'s'}, stored locally</div></div>
        <span class="btn ghost" style="padding:7px 14px;font-size:12.5px" data-act="clearHistory">Clear…</span></div></div>`; }
  if(p==='Intelligence'){ const routeOn=S.prefs.autoRouting!==false; const rz=S.prefs.reasoning||'Auto';
    const rzHint={Auto:'Reasoning models think when the task benefits — the thought time shows as a collapsed line.',Off:'Responses come straight away, even on reasoning-capable models.',On:'Always reason before answering. Slower, better on hard problems.'}[rz];
    let seg=''; ['Auto','Off','On'].forEach(o=>{ const on=o===rz; seg+=`<span data-act="pickReasoning" data-arg="${o}" style="padding:7px 18px;cursor:pointer;background:${on?'var(--ink)':'transparent'};color:${on?'#fff':'rgba(32,30,27,.65)'};font-weight:${on?'500':'400'}">${o}</span>`; });
    return `<div style="font-size:15px;font-weight:600;margin-bottom:18px">Intelligence</div><div style="display:flex;flex-direction:column;gap:18px;max-width:440px">
      <div style="display:flex;justify-content:space-between;align-items:flex-start"><div><div style="font-size:13.5px">Auto routing</div><div style="font-size:11.5px;color:var(--muted);margin-top:2px;line-height:1.45">esh picks the best model per request based on task, memory, and what's already loaded</div></div><span class="toggle" data-act="toggleRouting" style="background:${routeOn?'var(--ink)':'rgba(32,30,27,.2)'};flex-shrink:0;margin-left:20px"><span class="knob" style="left:${routeOn?'16px':'2px'}"></span></span></div>
      <div><div style="font-size:12px;color:var(--muted);margin-bottom:7px">Reasoning</div><div style="display:inline-flex;border:1px solid var(--line2);border-radius:9px;overflow:hidden;font-size:12.5px">${seg}</div><div style="font-size:11.5px;color:var(--muted);margin-top:7px;line-height:1.45">${esch(rzHint)}</div></div>
      <div style="display:flex;justify-content:space-between;align-items:center;font-size:13.5px"><span>Default performance</span><span data-act="goPane" data-arg="Performance" style="color:var(--muted);font-size:13px;cursor:pointer">${esch(S.optimize)} <span style="font-size:9px">▸</span></span></div>
      <div><div style="font-size:12px;color:var(--muted);margin-bottom:7px">System instructions</div><textarea id="sysinstr" data-act="editSysInstr" oninput="ACT.editSysInstr()" placeholder="Optional — applied to every new conversation" style="width:100%;border:1px solid var(--line2);border-radius:9px;padding:10px 12px;font-size:12.5px;line-height:1.55;color:rgba(32,30,27,.85);min-height:56px;resize:vertical;font-family:inherit;background:#fff">${esch(S.prefs.systemInstr||'')}</textarea><div style="font-size:11px;color:var(--faint);margin-top:6px">Applied to every new conversation</div></div></div>`; }
  if(p==='Models'){ const ids=S.models||[];
    let rows=''; ids.forEach(id=>{ const resident=S.engine&&S.engine.residentModelID===id; rows+=`<div style="display:flex;align-items:center;gap:10px;padding:11px 0;border-bottom:1px solid var(--line)"><div style="flex:1;min-width:0"><div style="font-size:13.5px;font-weight:500;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${esch(shortModel(id))}</div></div>${resident?'<span style="font-size:11px;color:var(--muted);border:1px solid var(--line2);border-radius:5px;padding:2px 7px">Loaded</span>':''}<span class="iconbtn" data-act="openModels" style="font-size:12px" title="Manage">▸</span></div>`; });
    if(!rows) rows='<div style="font-size:12.5px;color:var(--muted);padding:8px 0">No local models installed yet.</div>';
    const s=e.storage||{};
    return `<div style="display:flex;align-items:center;margin-bottom:18px;max-width:520px"><span style="font-size:15px;font-weight:600">Models</span><span class="sp" style="flex:1"></span><span class="btn ghost" style="padding:7px 14px;font-size:12.5px" data-act="openModels">Browse models…</span></div>
      <div style="max-width:520px"><div class="menuhead" style="padding:0 0 4px">Installed</div>${rows}
        <div style="display:flex;justify-content:space-between;align-items:center;font-size:13.5px;margin-top:18px"><span>Model storage</span><span data-act="goPane" data-arg="Storage" style="color:var(--muted);font-size:13px;cursor:pointer">${esch(volLabel(s.assetsRoot))}${s.freeBytes?(' · '+gb(s.freeBytes)+' free'):''} <span style="font-size:9px">▸</span></span></div></div>`; }
  if(p==='Voice') return `<div style="font-size:15px;font-weight:600;margin-bottom:14px">Voice</div>
    <div style="display:flex;flex-direction:column;gap:12px;font-size:13.5px;max-width:440px">
      <div style="display:flex;justify-content:space-between;align-items:center"><span>Read responses aloud</span><span class="toggle" data-act="toggleTts" style="background:${S.prefs.autoTts?'var(--ink)':'rgba(32,30,27,.2)'}"><span class="knob" style="left:${S.prefs.autoTts?'16px':'2px'}"></span></span></div>
      <div style="display:flex;justify-content:space-between;align-items:center"><span>Language</span><span class="mono" style="font-size:12px;color:var(--muted)">Automatic</span></div>
      <div style="display:flex;justify-content:space-between;align-items:center"><span>Speech-to-text model</span><span class="mono" style="font-size:12px;color:var(--muted)">${esch((S.config&&S.config.defaults&&S.config.defaults.sttModel)||'parakeet (default)')}</span></div>
      <div style="display:flex;justify-content:space-between;align-items:center"><span>Voice (TTS) model</span><span class="mono" style="font-size:12px;color:var(--muted)">${esch((S.config&&S.config.defaults&&S.config.defaults.ttsModel)||'Soprano (default)')}</span></div></div>
      <div style="border-top:1px solid rgba(32,30,27,.07);margin-top:16px;padding-top:12px;font-size:12px;color:var(--muted);max-width:440px;line-height:1.5">Tap the mic in the composer for a full voice conversation — it listens, transcribes, answers, and speaks back, committing every turn to the chat.</div>`;
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

/* ---------- voice (full conversational loop) ---------- */
function renderVoice(){
  const v=el('div',{cls:'voicewrap'});
  if(S.voice==='error'){
    v.innerHTML=`<div class="vstage"><div style="max-width:340px;text-align:center;display:flex;flex-direction:column;align-items:center;gap:14px">
      <div style="font-size:16px;font-weight:600">Voice unavailable</div>
      <div style="font-size:13px;color:var(--muted);line-height:1.5">${esch(S.voiceError||'')}</div>
      <div style="display:flex;gap:12px"><span class="btn ghost" style="padding:6px 14px" data-act="voiceRetry">Try again</span><span class="btn ghost" style="padding:6px 14px" data-act="voiceText">Back to text</span></div></div></div>`;
    return v;
  }
  const label={listening:'Listening',thinking:'Thinking',speaking:'Speaking'}[S.voice]||'';
  // Orb: pulsing circle (listening) → three dots (thinking) → waveform (speaking).
  let orb='';
  if(S.voice==='listening') orb=`<div class="vorb" data-act="voiceFinish" title="Tap when you're done"><span class="vpulse"><span></span></span></div>`;
  else if(S.voice==='thinking') orb=`<div class="vorb"><span class="vdots"><i></i><i style="animation-delay:.18s"></i><i style="animation-delay:.36s"></i></span></div>`;
  else { let bars=''; [14,30,20,36,16,26,12].forEach((hh,i)=>bars+=`<i style="height:${hh}px;animation-delay:${i*.12}s"></i>`);
    orb=`<div class="vorb"><span class="vwave" data-act="voiceInterrupt" title="Tap to interrupt">${bars}</span></div>`; }
  // Transcript: live utterance with caret while listening, muted quote once it settles, streamed answer while speaking.
  let mid='';
  if(S.voice==='listening'){ if(S.voiceHeard) mid=`<div class="vlive">${esch(S.voiceHeard)}<span class="caret"></span></div>`; }
  else if(S.voiceHeard){ mid=`<div class="vquote">"${esch(S.voiceHeard)}"</div>`; }
  const ans=(S.voice==='speaking'&&S.voiceAnswer)?`<div class="vanswer">${esch(S.voiceAnswer)}</div>`:'';
  const hint=S.voice==='listening'?'Tap the circle when you’re done':(S.voice==='speaking'?'Tap the wave to interrupt':'');
  v.innerHTML=`<div class="vstage">${orb}<div class="vlabel">${label}</div>${mid}${ans}<div class="vhint">${esch(hint)}</div></div>
    <div class="vctrls">
      <div class="vctrlcol"><span class="vctrl line" data-act="voiceText" title="Back to text">${ICON.keyboard}</span><span class="vctrllbl">Text</span></div>
      <div class="vctrlcol"><span class="vctrl solid" data-act="endVoice" title="End voice chat">${ICON.xmark}</span><span class="vctrllbl">End</span></div>
    </div>
    <div class="vfoot">Everything is transcribed into the chat</div>`;
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
  let reasoning=looksReasoning(resolved);
  if(S.prefs.reasoning==='Off')reasoning=false; else if(S.prefs.reasoning==='On')reasoning=true;
  S.streaming=true; S.streamText=''; S.streamReason=reasoning; S.streamThinkMs=undefined; saveChats(); render();
  S.controller=new AbortController(); const t0=performance.now();
  const sys=(S.prefs.systemInstr||'').trim();
  const msgs=(sys?[{role:'system',content:sys}]:[]).concat(c.messages.filter(m=>m.role).map(m=>({role:m.role,content:m.content})));
  const body={ model: resolved==='Auto'?undefined:resolved, messages:msgs, stream:true, max_tokens:2048 };
  let truncated=false, ttft=0, execProfile=null;
  let errorInfo=null;
  try{
    const resp=await fetch('/v1/chat/completions',{method:'POST',headers:{'Content-Type':'application/json'},signal:S.controller.signal,body:JSON.stringify(body)});
    if(!resp.ok||!resp.body){ let msg=''; try{ msg=((await resp.json()).error||{}).message||''; }catch(e){}
      errorInfo={model:shortModel(resolved||S.modelSel), detail:msg||('The server returned HTTP '+resp.status+'.')}; }
    else{ const rd=resp.body.getReader(),dec=new TextDecoder(); let buf='';
      while(true){ const {value,done}=await rd.read(); if(done)break; buf+=dec.decode(value,{stream:true}); const lines=buf.split('\n'); buf=lines.pop();
        for(const line of lines){ const s=line.trim(); if(!s.startsWith('data:'))continue; const d=s.slice(5).trim(); if(d==='[DONE]')continue;
          try{ const j=JSON.parse(d); if(j.esh_execution){ execProfile=j.esh_execution; continue; }
            if(j.choices&&j.choices[0]&&j.choices[0].finish_reason==='length')truncated=true;
            const del=j.choices&&j.choices[0]&&j.choices[0].delta&&j.choices[0].delta.content||''; if(del){ if(!ttft)ttft=performance.now()-t0; S.streamText+=del;
              if(S.streamThinkMs===undefined&&reasoning&&S.streamText.includes('</think>'))S.streamThinkMs=(performance.now()-t0)/1000;
              throttleRender(); } }catch(e){} } } }
  }catch(e){ if(e.name!=='AbortError' && !S.streamText) errorInfo={model:shortModel(resolved||S.modelSel), detail:e.message}; }
  // Model-load / runtime failure with no output → a degraded error card (what happened, what still
  // works, what to do), not a fabricated answer.
  if(errorInfo && !S.streamText.trim()){
    c.messages.push({id:uid(),role:'assistant',isError:true, model:errorInfo.model, lastUser:text,
      title:errorInfo.model+' couldn’t respond', detail:errorInfo.detail});
    S.streaming=false; S.streamText=''; S.controller=null; saveChats(); render(); return;
  }
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
function sendText(t){ if(!t)return; const ta=document.querySelector('#input'); if(ta)ta.value=t; S.draft=t; send(); }
let _rt; function throttleRender(){ if(_rt)return; _rt=setTimeout(()=>{ _rt=null;
  // Update only the streaming bubble during generation (smooth, no whole-app rebuild/flicker).
  const sw=document.querySelector('#streamwrap');
  if(S.streaming&&sw){ sw.innerHTML=streamInner(); const lg=document.querySelector('.log'); if(lg)lg.scrollTop=lg.scrollHeight; }
  else render();
},40); }

/* ---------- speech: real mic -> STT -> LLM -> TTS voice loop ---------- */
async function speak(text){ const clean=splitThink(text).answer||text; if(!clean.trim())return null;
  try{ const r=await fetch('/v1/audio/speech',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({input:clean.slice(0,2000)})});
    if(!r.ok)return null; const b=await r.blob(); const a=new Audio(URL.createObjectURL(b)); a.play(); return a; }catch(e){ return null; } }
function blobToB64(blob){ return new Promise(res=>{ const r=new FileReader(); r.onload=()=>res((r.result+'').split(',')[1]||''); r.readAsDataURL(blob); }); }
function clearVoiceReveal(){ if(S._vsi){ clearInterval(S._vsi); S._vsi=null; } }
function endVoiceLoop(){ clearVoiceReveal(); stopListening(); if(S.voiceAudio){try{S.voiceAudio.pause()}catch(e){}} S.voiceAudio=null; S.voice=null; S.voiceHeard=''; S.voiceAnswer=''; }
async function startVoice(){
  clearVoiceReveal(); S.voice='listening'; S.voiceError=null; S.voiceHeard=''; S.voiceAnswer=''; render();
  try{
    const stream=await navigator.mediaDevices.getUserMedia({audio:true});
    S.voiceStream=stream; S.recChunks=[];
    const rec=new MediaRecorder(stream); S.recorder=rec;
    rec.ondataavailable=e=>{ if(e.data&&e.data.size)S.recChunks.push(e.data); };
    rec.onstop=()=>finishVoiceTurn();
    rec.start();
  }catch(e){ S.voice='error'; S.voiceError='Microphone unavailable — grant access to use voice.'; render(); }
}
function stopListening(){ try{ if(S.recorder&&S.recorder.state!=='inactive')S.recorder.stop(); }catch(e){} if(S.voiceStream){ S.voiceStream.getTracks().forEach(t=>t.stop()); S.voiceStream=null; } }
// Reveal the answer text word-by-word roughly in step with the spoken audio, then commit the turn and
// return to listening. `dur` is the audio duration in seconds when known (otherwise a reading estimate).
function revealAnswer(reply,dur,commit){
  clearVoiceReveal(); S.voiceAnswer=''; const words=reply.split(/\s+/).filter(Boolean);
  if(!words.length){ commit(); return; }
  const step=Math.max(45,Math.min(320,(dur*1000)/words.length)); let i=0;
  S._vsi=setInterval(()=>{ i++; if(i>=words.length){ clearVoiceReveal(); S.voiceAnswer=reply; render(); commit(); }
    else { S.voiceAnswer=words.slice(0,i).join(' '); if(S.voice==='speaking')render(); } },step);
}
async function finishVoiceTurn(){
  S.voice='thinking'; S.voiceAnswer=''; render();
  const blob=new Blob(S.recChunks,{type:(S.recorder&&S.recorder.mimeType)||'audio/webm'});
  const b64=await blobToB64(blob);
  let text='';
  try{ const r=await fetch('/v1/audio/transcriptions',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({audio:b64,filename:'voice.webm'})});
    if(!r.ok){ let em=''; try{ em=(((await r.json())||{}).error||{}).message||''; }catch(e){}
      // Surface the real cause: a missing speech runtime (mlx_audio) reads differently from a missing model.
      S.voice='error'; S.voiceError=/mlx_audio|not available|No module/i.test(em)
        ? 'Speech isn’t installed yet — run “esh bootstrap” (installs the on-device speech runtime), then try again.'
        : (em?('Speech-to-text error: '+em):'Speech-to-text isn’t available — install a transcription model.');
      render(); return; }
    text=((await r.json()).text||'').trim();
  }catch(e){ S.voice='error'; S.voiceError='Transcription failed: '+e.message; render(); return; }
  if(!text){ startVoice(); return; }  // nothing said — listen again
  S.voiceHeard=text; render();  // utterance settles into the muted quote
  const c=cur()||(newChat(),cur());
  c.messages.push({id:uid(),role:'user',content:text}); saveChats();
  // Resolve Auto through the Scheduler, then run inference (non-streaming for the voice turn).
  let model=S.modelSel;
  if(model==='Auto'){ const opt={Balanced:'balanced',Quality:'high',Speed:'fast','Low Memory':'balanced'}[S.optimize]||'balanced'; const sc=await api('/v1/schedule?goal=general&quality='+opt); if(sc&&sc.selectedModelID){ S.schedule=sc; model=sc.selectedModelID; } }
  const t0=performance.now(); let reply='';
  const vsys=(S.prefs.systemInstr||'').trim();
  const vmsgs=(vsys?[{role:'system',content:vsys}]:[]).concat(c.messages.filter(m=>m.role).map(m=>({role:m.role,content:m.content})));
  try{ const rr=await fetch('/v1/chat/completions',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({model:model==='Auto'?undefined:model,messages:vmsgs,max_tokens:512})});
    const j=await rr.json(); reply=(j.choices&&j.choices[0]&&j.choices[0].message&&j.choices[0].message.content)||''; }catch(e){ reply='[error] '+e.message; }
  const answer=splitThink(reply).answer||reply;
  const secs=Math.max(0.1,(performance.now()-t0)/1000);
  const tps=Math.max(1,Math.round((answer.length/4)/secs));
  // Every finished exchange is committed to the transcript with a voice footer.
  const meta='voice · '+secs.toFixed(1)+'s · '+tps+' tok/s';
  // Speak, reveal the answer in sync, then commit the turn (once) and listen again.
  S.voice='speaking'; S.voiceAnswer=''; render();
  const audio=await speak(reply); S.voiceAudio=audio;
  let committed=false;
  const commitOnce=()=>{ if(committed)return; committed=true; clearVoiceReveal(); S.voiceAnswer=answer;
    c.messages.push({id:uid(),role:'assistant',content:reply,reasoning:looksReasoning(model),meta:meta}); saveChats();
    if(S.voiceAudio){try{S.voiceAudio.pause()}catch(e){}} S.voiceAudio=null;
    if(S.voice==='speaking') startVoice(); };
  const dur=Math.max(1.5,answer.split(/\s+/).length*0.34);  // reading-estimate fallback
  if(audio){ audio.onloadedmetadata=()=>{ if(!committed&&isFinite(audio.duration)&&audio.duration>0) revealAnswer(answer,audio.duration,commitOnce); };
    audio.onended=commitOnce; }
  revealAnswer(answer,dur,commitOnce);
}
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
refreshModels(); refreshEngine(); refreshSchedule(); refreshConfig().then(render);
render();
</script>
</body>
</html>
"""#
}
