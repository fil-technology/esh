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
  /* Fade in only on ENTER (via .enter), never on every state change — otherwise the whole overlay
     flashes transparent each listening→thinking→speaking transition. */
  .voicewrap{ position:absolute; inset:0; background:var(--paper); display:flex; flex-direction:column; z-index:60; }
  .voicewrap.enter{ animation:eshfade .22s ease-out; }
  .vlabel,.vquote,.vanswer,.vlive{ animation:eshfade .18s ease-out; }
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
  .chatitem[draggable="true"]{ cursor:pointer; }
  .chatitem.dragging{ opacity:.4; }
  .sbhead{ display:flex; align-items:center; gap:6px; margin-bottom:10px; }
  .sbhead .newchat{ flex:1; margin-bottom:0; }
  .nfbtn{ width:34px; height:34px; flex-shrink:0; border:1px solid var(--line2); border-radius:8px; display:flex; align-items:center; justify-content:center; color:var(--muted); background:none; cursor:pointer; }
  .nfbtn:hover{ background:rgba(32,30,27,.03); color:var(--ink); }
  .folderrow{ display:flex; align-items:center; gap:6px; padding:6px 10px; border-radius:8px; font-size:13px; color:rgba(32,30,27,.82); cursor:pointer; user-select:none; }
  .folderrow:hover{ background:rgba(32,30,27,.04); }
  .folderrow.dropover{ background:rgba(32,30,27,.10); box-shadow:inset 0 0 0 1px var(--line2); }
  .fchev{ display:inline-flex; width:12px; flex-shrink:0; transition:transform .15s; color:var(--faint); }
  .fchev.open{ transform:rotate(90deg); }
  .ficon{ display:inline-flex; flex-shrink:0; color:var(--muted); }
  .fname{ flex:1; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
  .fcount{ font:400 10px var(--mono); color:var(--faint); }
  .folderchats{ margin-left:13px; padding-left:8px; border-left:1px solid var(--line); display:flex; flex-direction:column; gap:2px; margin-top:2px; }
  .folderempty{ padding:5px 10px; font-size:11px; color:var(--faint); font-style:italic; }
  .rootchats{ display:flex; flex-direction:column; gap:2px; min-height:10px; border-radius:6px; }
  .rootchats.dropover, .sgroup.dropover{ background:rgba(32,30,27,.06); box-shadow:inset 0 0 0 1px var(--line2); }
  .renameinput{ width:100%; box-sizing:border-box; border:1px solid rgba(32,30,27,.35); border-radius:6px; padding:5px 8px; font-size:13px; font-family:inherit; color:var(--ink); background:var(--paper); outline:none; }
  .main{ flex:1; display:flex; flex-direction:column; min-width:0; position:relative; }
  .empty{ flex:1; display:flex; align-items:center; justify-content:center; padding-bottom:60px; font-size:26px; font-weight:500; letter-spacing:-.02em; }
  .log{ flex:1; overflow-y:auto; padding:28px 24px; }
  .thread{ max-width:640px; margin:0 auto; display:flex; flex-direction:column; gap:22px; }
  .msg{ display:flex; flex-direction:column; gap:10px; }
  .userrow{ display:flex; justify-content:flex-end; }
  .userbubble{ background:var(--userbubble); border-radius:13px; padding:6px 13px; font-size:14px; line-height:1.45; max-width:70%; white-space:pre-wrap; overflow-wrap:anywhere; }
  .asst{ display:flex; flex-direction:column; gap:6px; }
  .reason{ font-size:12px; color:var(--muted); }
  .reason summary{ cursor:pointer; list-style:none; color:var(--faint); }
  .reason summary::-webkit-details-marker{ display:none; }
  .reason summary::before{ content:"▸ "; } .reason[open] summary::before{ content:"▾ "; }
  .reason summary.live{ color:var(--ink); animation:eshpulse 1.5s ease-in-out infinite; }
  .reason .rc{ color:var(--muted); white-space:pre-wrap; border-left:2px solid var(--line2); padding-left:10px; margin-top:6px; line-height:1.5; }
  .asttext{ font-size:14px; line-height:1.6; white-space:pre-wrap; overflow-wrap:anywhere; }
  .asttext pre{ background:var(--panel2); padding:11px 13px; border-radius:9px; overflow-x:auto; margin:8px 0; border:1px solid var(--line); }
  .asttext pre code{ background:none; padding:0; font-size:12.5px; line-height:1.55; display:block; white-space:pre; }
  .asttext code{ background:var(--panel2); padding:1px 4px; border-radius:4px; font-family:var(--mono); font-size:12.5px; }
  /* Markdown blocks + inline */
  .asttext .mdh{ font-weight:600; line-height:1.3; margin:12px 0 6px; } .asttext .mdh1{ font-size:19px; } .asttext .mdh2{ font-size:16.5px; } .asttext .mdh3{ font-size:15px; } .asttext .mdh4{ font-size:14px; }
  .asttext .mdp{ margin:7px 0; } .asttext .mdp:first-child{ margin-top:0; } .asttext .mdp:last-child{ margin-bottom:0; }
  /* The user bubble renders md() too; without this the paragraph keeps the browser
     default ~14px top/bottom margins, inflating the bubble height. Keep it tight. */
  .userbubble .mdp{ margin:0; } .userbubble .mdp + .mdp{ margin-top:6px; }
  .asttext .mdul,.asttext .mdol{ margin:7px 0; padding-left:22px; } .asttext .mdul li,.asttext .mdol li{ margin:3px 0; }
  .asttext .mdq{ border-left:2.5px solid var(--line2); margin:8px 0; padding:2px 0 2px 12px; color:var(--muted); }
  .asttext .mdhr{ border:none; border-top:1px solid var(--line2); margin:14px 0; }
  .asttext a{ color:var(--ink); text-decoration:underline; text-underline-offset:2px; } .asttext a:hover{ opacity:.7; }
  /* Lightweight syntax highlighting — restrained warm palette (no teal/blue) */
  .hlc{ color:rgba(32,30,27,.42); font-style:italic; } .hls{ color:#5f7346; } .hlk{ color:#201e1b; font-weight:600; } .hln{ color:#9a6a30; } .hlt{ color:#6a5a86; }
  .asttext img{ max-width:100%; border-radius:10px; margin:6px 0; display:block; } .asttext audio{ width:100%; margin:6px 0; }
  .userbubble img{ max-width:220px; border-radius:10px; margin:2px 0 6px; display:block; } .userbubble audio{ width:220px; margin:2px 0 6px; }
  .attwrap{ display:flex; flex-wrap:wrap; gap:8px; margin-bottom:6px; }
  .transcap{ font-size:12.5px; color:var(--muted); line-height:1.45; font-style:italic; padding-top:2px; }
  .transcap.loading{ display:flex; align-items:center; gap:8px; font-style:normal; color:var(--faint); }
  .attpill{ display:flex; align-items:center; gap:8px; background:var(--paper); border:1px solid var(--line2); border-radius:9px; padding:6px 10px 6px 6px; }
  .attpill .ai{ width:26px; height:26px; border-radius:6px; background:var(--ink); display:flex; align-items:center; justify-content:center; flex-shrink:0; }
  .attpill .an{ display:flex; flex-direction:column; min-width:0; } .attpill .an b{ font-size:12px; font-weight:600; max-width:170px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
  /* Custom audio player (no native controls) — on-brand play/pause + progress + mono time */
  .aplayer{ display:flex; align-items:center; gap:10px; background:var(--panel2); border:1px solid var(--line); border-radius:11px; padding:7px 12px 7px 8px; min-width:180px; max-width:260px; }
  .aplayer .pp{ width:30px; height:30px; border-radius:50%; background:var(--ink); color:var(--paper); display:flex; align-items:center; justify-content:center; cursor:pointer; flex-shrink:0; border:none; }
  .aplayer .pp:hover{ opacity:.88; } .aplayer .pp svg{ display:block; }
  .aplayer .track{ flex:1; height:4px; background:rgba(32,30,27,.14); border-radius:2px; position:relative; cursor:pointer; min-width:60px; }
  .aplayer .fill{ position:absolute; left:0; top:0; height:100%; background:var(--ink); border-radius:2px; width:0%; }
  .aplayer .knobd{ position:absolute; top:50%; width:9px; height:9px; border-radius:50%; background:var(--ink); transform:translate(-50%,-50%); left:0%; }
  .aplayer .atime{ font:400 10.5px var(--mono); color:var(--muted); flex-shrink:0; min-width:30px; text-align:right; }
  .metaline{ font:400 11px var(--mono); color:var(--faint); cursor:pointer; }
  .metaline:hover{ color:var(--ink); text-decoration:underline; }
  .caret{ display:inline-block; width:8px; height:15px; background:var(--ink); vertical-align:-2px; margin-left:2px; animation:eshblink 1s infinite; }
  /* Streaming cursor sits inline at the END of the last rendered block (paragraph,
     list item, code line) instead of dropping to its own line below the text. */
  .asttext.streaming>:last-child::after{ content:''; display:inline-block; width:7px; height:14px; background:var(--ink); vertical-align:-2px; margin-left:2px; border-radius:1px; animation:eshblink 1s infinite; }
  .typing{ display:inline-flex; gap:5px; align-items:center; padding:3px 2px; }
  .typing i{ width:7px; height:7px; border-radius:50%; background:var(--faint); animation:eshtype 1.2s infinite ease-in-out both; }
  .typing i:nth-child(2){ animation-delay:.16s } .typing i:nth-child(3){ animation-delay:.32s }
  .errcard{ border:1px solid var(--line2); border-radius:12px; padding:16px 18px; }
  .errcard .t{ font-size:13.5px; font-weight:600; } .errcard .d{ font-size:12.5px; line-height:1.55; color:rgba(32,30,27,.7); margin-top:5px; }
  /* Composer */
  .composer{ padding:0 24px 10px; flex-shrink:0; position:relative; }
  .miniplayer{ display:flex; align-items:center; gap:10px; padding:8px 12px; max-width:640px; margin:0 auto 8px; border:1px solid var(--line2); border-radius:12px; background:var(--paper); box-shadow:0 2px 10px rgba(32,30,27,.05); }
  .mpbtn{ display:inline-flex; align-items:center; justify-content:center; width:30px; height:30px; flex-shrink:0; border:none; border-radius:8px; background:var(--panel2); color:var(--ink); cursor:pointer; padding:0; }
  .mpbtn:hover{ background:rgba(32,30,27,.08); }
  .mpmeta{ flex:1; display:flex; flex-direction:column; gap:5px; min-width:0; }
  .mplbl{ font-size:12px; color:var(--muted); white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
  .mptrack{ height:4px; border-radius:2px; background:rgba(32,30,27,.10); overflow:hidden; }
  .mpfill{ height:100%; width:0%; background:var(--ink); border-radius:2px; }
  .mptime{ font-size:11px; color:var(--faint); flex-shrink:0; }
  .mpspin{ width:16px; height:16px; flex-shrink:0; box-sizing:border-box; border:2px solid rgba(32,30,27,.15); border-top-color:var(--ink); border-radius:50%; animation:eshspin .7s linear infinite; margin:7px; }
  @keyframes eshspin{ to{ transform:rotate(360deg); } }
  /* Fade the thread out as it scrolls under the composer (transparent → paper) */
  .composer::before{ content:''; position:absolute; left:0; right:0; top:-54px; height:54px; background:linear-gradient(to bottom, rgba(251,250,248,0), var(--paper) 82%); pointer-events:none; }
  /* Small screens: the chat sidebar and the settings category list overlay the view (with a backdrop)
     instead of squeezing it — opened from the top-left toggle / settings. */
  .sbackdrop{ display:none; }
  @keyframes eshslidein{ from{ transform:translateX(-100%); opacity:.5 } to{ transform:none; opacity:1 } }
  @media(max-width:768px){
    .sidebar{ position:absolute; top:0; left:0; right:0; bottom:0; z-index:60; width:100%; max-width:100%; background:var(--paper); box-shadow:none; animation:eshslidein .18s cubic-bezier(.2,.8,.2,1); }
    .sbackdrop{ display:block; position:absolute; inset:0; background:rgba(32,30,27,.28); z-index:55; animation:eshfade .15s ease-out; }
    .settingsbody{ flex-direction:column !important; }
    .paneside{ width:100% !important; flex-direction:row !important; overflow-x:auto; border-right:none !important; border-bottom:1px solid rgba(32,30,27,.07); gap:4px; padding:10px 12px; }
    .paneitem{ white-space:nowrap; flex-shrink:0; }
  }
  .cbox{ max-width:640px; margin:0 auto; background:#fff; border:1px solid var(--line2); border-radius:15px; box-shadow:0 1px 2px rgba(32,30,27,.04); padding:11px 14px; display:flex; flex-direction:column; gap:10px; position:relative; }
  .crow{ display:flex; align-items:center; gap:10px; }
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
  /* Animate only on the open transition (added by popAnimPass), never on the full
     re-renders that happen while a popover stays open (e.g. during streaming) — a
     re-triggered entrance read as the menu "jumping". */
  .pop{ transform-origin:top; } .pop.opening{ animation:eshpop .15s cubic-bezier(.2,.8,.2,1); }
  .asstfoot{ display:flex; align-items:center; gap:6px; align-self:flex-start; }
  .sbtn{ display:inline-flex; align-items:center; justify-content:center; width:24px; height:24px; border-radius:6px; border:none; background:none; color:var(--faint); cursor:pointer; padding:0; transition:color .12s, background .12s; }
  .sbtn svg{ width:14px; height:14px; }
  .sbtn:hover{ color:var(--ink); background:var(--panel2); } .sbtn.on{ color:var(--ink); } .sbtn.load{ animation:eshpulse 1s ease-in-out infinite; }
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
const $=s=>document.querySelector(s), LS="esh.chats.v1", PREF="esh.prefs.v1", FOLD="esh.folders.v1";
const ICON={
  sidebar:'<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><rect x="3.5" y="4.5" width="17" height="15" rx="2.5"/><path d="M9.5 4.5v15"/></svg>',
  settings:'<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M4 7h16"/><path d="M4 17h16"/><circle cx="9.5" cy="7" r="2.4"/><circle cx="14.5" cy="17" r="2.4"/></svg>',
  plus:'<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M12 5v14"/><path d="M5 12h14"/></svg>',
  mic:'<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5.5 11.5a6.5 6.5 0 0 0 13 0"/><path d="M12 18v3"/></svg>',
  up:'<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 19V5"/><path d="M6 11l6-6 6 6"/></svg>',
  back:'<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M19 12H5"/><path d="M11 18l-6-6 6-6"/></svg>',
  stop:'<svg width="11" height="11" viewBox="0 0 24 24" fill="currentColor"><rect x="6" y="6" width="12" height="12" rx="2"/></svg>',
  queue:'<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h11"/><path d="M4 12h9"/><path d="M4 17h7"/><path d="M18 13v7"/><path d="M14.5 16.5h7"/></svg>',
  keyboard:'<svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"><rect x="3" y="7" width="18" height="11" rx="2.5"/><path d="M7 11h.5"/><path d="M11.75 11h.5"/><path d="M16.5 11h.5"/><path d="M8 14.5h8"/></svg>',
  xmark:'<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M6 6l12 12"/><path d="M18 6L6 18"/></svg>',
  play:'<svg width="13" height="13" viewBox="0 0 24 24" fill="currentColor"><path d="M7 5v14l12-7z"/></svg>',
  pause:'<svg width="13" height="13" viewBox="0 0 24 24" fill="currentColor"><rect x="6" y="5" width="4" height="14" rx="1"/><rect x="14" y="5" width="4" height="14" rx="1"/></svg>',
  speaker:'<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 9.5v5h3.5L12 18V6L7.5 9.5H4z"/><path d="M15.5 9a4 4 0 0 1 0 6"/><path d="M18 6.5a7.5 7.5 0 0 1 0 11"/></svg>',
  folder:'<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M3 7a2 2 0 0 1 2-2h4l2 2.5h8a2 2 0 0 1 2 2V18a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></svg>',
  folderPlus:'<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M3 7a2 2 0 0 1 2-2h4l2 2.5h8a2 2 0 0 1 2 2V18a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/><path d="M12 11v5"/><path d="M9.5 13.5h5"/></svg>',
  chevr:'<svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 6l6 6-6 6"/></svg>'
};
let S={ view:'chat', chats:{}, current:null, controller:null, streaming:false, streamText:'', streamThinkMs:undefined,
        models:[], modelSel:'Auto', optimize:'Balanced', pickerOpen:false, engineOpen:false, execOpen:false, attachOpen:false,
        engine:null, schedule:null, catalog:null, config:null, lastExec:null, execMsgId:null,
        modelsFilter:'Recommended', detail:null, settingsPane:'Privacy', pendingAtts:[], sidebarOpen:true,
        onbStep:0, voice:null, prefs:{}, installing:{}, effortOpen:false, audioModels:null, voiceDrop:null, chatMenu:null, genChatId:null,
        folders:{}, renaming:null };

/* ---------- persistence ---------- */
function loadChats(){ try{S.chats=JSON.parse(localStorage.getItem(LS)||"{}")}catch(e){S.chats={}} }
function saveChats(){ if(S.prefs&&S.prefs.saveHistory===false)return; try{localStorage.setItem(LS,JSON.stringify(S.chats))}catch(e){} }
function loadFolders(){ try{S.folders=JSON.parse(localStorage.getItem(FOLD)||"{}")}catch(e){S.folders={}} }
function saveFolders(){ if(S.prefs&&S.prefs.saveHistory===false)return; try{localStorage.setItem(FOLD,JSON.stringify(S.folders))}catch(e){} }
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
async function refreshAudioModels(){ const d=await api('/v1/audio/models'); S.audioModels=(d&&d.data)||[]; render(); }
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
function mdInline(s){ s=esc(mathify(s));
  s=s.replace(/`([^`]+)`/g,'<code>$1</code>');
  s=s.replace(/\*\*([^*]+?)\*\*/g,'<b>$1</b>');
  s=s.replace(/(^|[^*\w])\*([^*\n]+?)\*(?!\w)/g,'$1<em>$2</em>');
  s=s.replace(/(^|[^_\w])_([^_\n]+?)_(?!\w)/g,'$1<em>$2</em>');
  s=s.replace(/\[([^\]]+)\]\((https?:[^)\s]+)\)/g,'<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>');
  return s; }
// Lightweight, self-contained syntax highlighter (no dependency). A small scanner emits spans for
// comments, strings, numbers, and keywords in a restrained warm palette. Not a full parser — enough
// to make code blocks readable and on-brand.
const HL_KW={
  swift:'func var let class struct enum protocol extension guard if else for while repeat return switch case default break continue import public private fileprivate internal static self Self nil true false in throws rethrows async await try do catch where init deinit override some any lazy weak unowned mutating associatedtype typealias defer as is',
  javascript:'function var let const class return if else for while switch case default break continue import export from new this super null undefined true false async await try catch finally throw typeof instanceof of in do delete void yield extends',
  typescript:'function var let const class interface type return if else for while switch case default import export from new this null undefined true false async await try catch throw typeof of in extends implements public private readonly enum namespace as keyof',
  python:'def class return if elif else for while break continue import from as with try except finally raise lambda None True False and or not in is pass yield global nonlocal async await self del assert',
  rust:'fn let mut const struct enum trait impl pub use mod match if else for while loop return break continue self Self as ref move where async await dyn crate super true false Some None Ok Err',
  go:'func var const type struct interface map return if else for range switch case default break continue import package go defer chan select nil true false',
  _default:'function def fn func class struct enum var let const return if else for while switch case import from export public private static true false null nil new void async await try catch throw'
};
function highlight(code, lang){
  lang=(lang||'').toLowerCase(); if(lang==='js')lang='javascript'; if(lang==='ts')lang='typescript'; if(lang==='py')lang='python';
  const kw={}; (HL_KW[lang]||HL_KW._default).split(' ').forEach(k=>kw[k]=1);
  const hash=(lang==='python'||lang==='ruby'||lang==='sh'||lang==='bash'||lang==='shell'||lang==='yaml'||lang==='yml');
  let out='', i=0; const n=code.length;
  const push=(cls,txt)=>{ out+=cls?('<span class="'+cls+'">'+esc(txt)+'</span>'):esc(txt); };
  while(i<n){ const ch=code[i];
    if(!hash && ch==='/' && code[i+1]==='/'){ let j=code.indexOf('\n',i); if(j<0)j=n; push('hlc',code.slice(i,j)); i=j; continue; }
    if(!hash && ch==='/' && code[i+1]==='*'){ let j=code.indexOf('*/',i); j=j<0?n:j+2; push('hlc',code.slice(i,j)); i=j; continue; }
    if(hash && ch==='#'){ let j=code.indexOf('\n',i); if(j<0)j=n; push('hlc',code.slice(i,j)); i=j; continue; }
    if(ch==='"'||ch==="'"||ch==='`'){ let j=i+1; while(j<n){ if(code[j]==='\\'){ j+=2; continue; } if(code[j]===ch){ j++; break; } j++; } push('hls',code.slice(i,j)); i=j; continue; }
    if(/[0-9]/.test(ch) && !/[A-Za-z_]/.test(code[i-1]||'')){ let j=i; while(j<n&&/[0-9._xXa-fA-F]/.test(code[j]))j++; push('hln',code.slice(i,j)); i=j; continue; }
    if(/[A-Za-z_$]/.test(ch)){ let j=i; while(j<n&&/[A-Za-z0-9_$]/.test(code[j]))j++; const w=code.slice(i,j); push(kw[w]?'hlk':'', w); i=j; continue; }
    push('', ch); i++;
  }
  return out;
}
// Block-level markdown → HTML (headings, lists, blockquotes, hr, paragraphs); inline handled by mdInline.
function mdBlocks(t){ const lines=t.split('\n'); let out='', i=0;
  const isSpecial=l=>/^(#{1,4})\s|^\s*[-*+]\s|^\s*\d+\.\s|^\s*>|^\s*(---|\*\*\*|___)\s*$/.test(l);
  while(i<lines.length){ const line=lines[i];
    if(/^\s*$/.test(line)){ i++; continue; }
    let hm=line.match(/^(#{1,4})\s+(.*)$/); if(hm){ out+='<div class="mdh mdh'+hm[1].length+'">'+mdInline(hm[2])+'</div>'; i++; continue; }
    if(/^\s*(---|\*\*\*|___)\s*$/.test(line)){ out+='<hr class="mdhr">'; i++; continue; }
    if(/^\s*>\s?/.test(line)){ const q=[]; while(i<lines.length&&/^\s*>\s?/.test(lines[i])){ q.push(lines[i].replace(/^\s*>\s?/,'')); i++; } out+='<blockquote class="mdq">'+mdInline(q.join(' '))+'</blockquote>'; continue; }
    if(/^\s*[-*+]\s+/.test(line)){ const it=[]; while(i<lines.length&&/^\s*[-*+]\s+/.test(lines[i])){ it.push(lines[i].replace(/^\s*[-*+]\s+/,'')); i++; } out+='<ul class="mdul">'+it.map(x=>'<li>'+mdInline(x)+'</li>').join('')+'</ul>'; continue; }
    if(/^\s*\d+\.\s+/.test(line)){ const it=[]; while(i<lines.length&&/^\s*\d+\.\s+/.test(lines[i])){ it.push(lines[i].replace(/^\s*\d+\.\s+/,'')); i++; } out+='<ol class="mdol">'+it.map(x=>'<li>'+mdInline(x)+'</li>').join('')+'</ol>'; continue; }
    const para=[]; while(i<lines.length&&!/^\s*$/.test(lines[i])&&!isSpecial(lines[i])){ para.push(lines[i]); i++; }
    out+='<p class="mdp">'+mdInline(para.join('\n')).replace(/\n/g,'<br>')+'</p>';
  }
  return out; }
function md(t){
  // Split fenced code blocks (```lang\n…```), highlight them, and run block markdown on the rest.
  const segs=[]; const fence=/```([^\n`]*)\n([\s\S]*?)```/g; let last=0, m;
  while((m=fence.exec(t))){ segs.push({t:'x',v:t.slice(last,m.index)}); segs.push({t:'c',lang:m[1].trim(),v:m[2].replace(/\n$/,'')}); last=m.index+m[0].length; }
  segs.push({t:'x',v:t.slice(last)});
  // Handle a trailing UNCLOSED fence (streaming): render everything after the last ``` as open code.
  const tail=segs[segs.length-1];
  if(tail.t==='x'){ const op=tail.v.indexOf('```'); if(op>=0){ const after=tail.v.slice(op+3); const nl=after.indexOf('\n'); const lang=nl>=0?after.slice(0,nl).trim():''; const code=nl>=0?after.slice(nl+1):''; tail.v=tail.v.slice(0,op); segs.push({t:'c',lang,v:code}); } }
  return segs.map(s=> s.t==='c' ? ('<pre><code>'+highlight(s.v, s.lang)+'</code></pre>') : mdBlocks(s.v) ).join('');
}
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
function render(){ renderView(); popAnimPass(); wireSidebar(); a11yPass(); wireAudioPlayers(); }
// Play the popover entrance animation only when a popover first opens (the open set
// changes), not on every full re-render while it stays open — otherwise the menu
// re-pops on each render (e.g. streaming start/end) and looks like it's jumping.
function popAnimPass(){
  const key = S.pickerOpen?'picker':S.effortOpen?'effort':S.attachOpen?'attach':S.engineOpen?'engine':S.voiceDrop?('vdrop:'+S.voiceDrop):S.chatMenu?'menu':'';
  if(key && key!==S._popKey){ document.querySelectorAll('.pop').forEach(p=>p.classList.add('opening')); }
  S._popKey=key;
}
function renderView(){ const app=$('#app'); app.innerHTML='';
  if(S.view==='onboarding'){ app.appendChild(renderOnboarding()); return; }
  if(S.view==='models'){ app.appendChild(renderModels()); if(S.detail) app.appendChild(renderDetail()); return; }
  if(S.view==='settings'){ app.appendChild(renderSettings()); return; }
  app.appendChild(renderChat());
  if(S.voice) app.appendChild(renderVoice());
  if(S.chatMenu) app.appendChild(renderChatMenu());
}
function renderChatMenu(){
  const m=S.chatMenu; const isFolder=m.type==='folder'; const w=170, h=84;
  const x=Math.min(m.x, window.innerWidth-w-8), y=Math.min(m.y, window.innerHeight-h-8);
  const p=el('div',{cls:'pop'}); p.style.cssText+='position:fixed;left:'+x+'px;top:'+y+'px;width:'+w+'px;padding:6px 0;z-index:60';
  const renameAct=isFolder?'renameFolder':'renameChat', deleteAct=isFolder?'deleteFolder':'deleteChat';
  p.innerHTML=`<div class="menurow" data-act="${renameAct}" data-arg="${esch(m.id)}"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z"/></svg>Rename</div>
    <div class="menurow" data-act="${deleteAct}" data-arg="${esch(m.id)}" style="color:var(--amber)"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h16"/><path d="M9 7V5h6v2"/><path d="M6 7l1 13h10l1-13"/></svg>Delete</div>`;
  return p;
}
// Make non-native interactive controls reachable + labeled for keyboard and screen-reader users.
function a11yPass(){ document.querySelectorAll('[data-act]').forEach(e=>{ if(e.tagName!=='BUTTON'&&e.tagName!=='A'){
    if(!e.hasAttribute('tabindex'))e.setAttribute('tabindex','0'); if(!e.hasAttribute('role'))e.setAttribute('role','button'); }
  if(!e.getAttribute('aria-label')){ const t=e.getAttribute('title')||e.textContent.trim(); if(t)e.setAttribute('aria-label',t.slice(0,60)); } }); }
function el(tag,attrs,html){ const e=document.createElement(tag); if(attrs) for(const k in attrs){ if(k==='cls')e.className=attrs[k]; else if(k==='on')e.onclick=attrs[k]; else e.setAttribute(k,attrs[k]); } if(html!=null)e.innerHTML=html; return e; }

/* ---------- action delegation (thin client: handlers are named, wired by data-act) ---------- */
const ACT={
  toggleSidebar:()=>{ S.sidebarOpen=!S.sidebarOpen; S.prefs.sidebarOpen=S.sidebarOpen; savePrefs(); render(); },
  newChat, openSettings:()=>{ closeAll(); S.view='settings'; refreshConfig().then(render); if(!S.audioModels)refreshAudioModels(); render(); },
  openModels:()=>{ closeAll(); S.view='models'; refreshCatalog(); render(); },
  backChat:()=>{ S.view='chat'; S.detail=null; render(); },
  togglePicker:()=>{ const was=S.pickerOpen; closeAll(); S.pickerOpen=!was; if(!S.pickerOpen)S.focusInput=true; render(); },
  toggleEffort:()=>{ const was=S.effortOpen; closeAll(); S.effortOpen=!was; if(!S.effortOpen)S.focusInput=true; render(); },
  pickEffort:(v)=>{ if(v==='Off'){ S.prefs.reasoning='Off'; } else { S.prefs.reasoning='Auto'; S.prefs.effort=v; } savePrefs(); S.focusInput=true; render(); },
  toggleEngine:()=>{ const was=S.engineOpen; closeAll(); S.engineOpen=!was; if(S.engineOpen)refreshEngine(); else S.focusInput=true; render(); },
  toggleAttach:()=>{ const was=S.attachOpen; closeAll(); S.attachOpen=!was; render(); },
  pickModel:(v)=>{ S.modelSel=v; closeAll(); S.focusInput=true; if(v==='Auto')refreshSchedule(); render(); },
  pickOptimize:(v)=>{ S.optimize=v; S.focusInput=true; postConfig({performanceMode:v.toLowerCase()}); refreshSchedule(); render(); },
  openExec:(id)=>{ S.execMsgId=id; S.execOpen=true; render(); },
  closeExec:()=>{ S.execOpen=false; render(); },
  copyExec:(id)=>{ const m=cur().messages.find(x=>x.id===id); if(m&&m.exec){ try{ navigator.clipboard.writeText(JSON.stringify(m.exec.profile||m.exec,null,2)); }catch(e){} } },
  send:()=>send(), stop:()=>{ S._stopQueue=true; if(S.controller)S.controller.abort(); },
  removeQueued:(i)=>{ const c=cur(); if(c&&c.queue)c.queue.splice(+i,1); S.focusInput=true; render(); },
  queueDraft:()=>enqueueDraft(),
  retryLast:(t)=>{ const c=cur(); if(c&&c.messages.length&&c.messages[c.messages.length-1].isError)c.messages.pop(); sendText(t); },
  continueAuto:(t)=>{ const c=cur(); if(c&&c.messages.length&&c.messages[c.messages.length-1].isError)c.messages.pop(); S.modelSel='Auto'; refreshSchedule(); sendText(t); },
  switchChat:(id)=>{ if(S.renaming)return; S.current=id; render(); },
  renameChat:(id)=>{ S.chatMenu=null; startRename('chat',id); },
  renameFolder:(id)=>{ S.chatMenu=null; startRename('folder',id); },
  commitRename:()=>commitRename(),
  newFolder:()=>{ const id=uid(); S.folders[id]={id,name:'New folder',created:Date.now(),collapsed:false}; saveFolders(); startRename('folder',id); },
  toggleFolder:(id)=>{ if(S.renaming)return; const f=S.folders[id]; if(!f)return; f.collapsed=!f.collapsed; saveFolders(); render(); },
  deleteFolder:(id)=>{ S.chatMenu=null; const f=S.folders[id]; if(!f)return; if(!confirm('Delete folder “'+((f.name||'Folder').slice(0,40))+'”? Chats inside move back to Recent.'))return;
    Object.values(S.chats).forEach(ch=>{ if(ch.folderId===id)delete ch.folderId; }); delete S.folders[id]; saveFolders(); saveChats(); render(); },
  deleteChat:(id)=>{ S.chatMenu=null; const ch=S.chats[id]; if(!ch)return; if(!confirm('Delete “'+((ch.title||'New chat').slice(0,40))+'”? This can’t be undone.'))return;
    delete S.chats[id]; saveChats();
    if(S.current===id){ const rest=Object.values(S.chats).sort((a,b)=>b.created-a.created); if(rest.length){ S.current=rest[0].id; } else { newChat(); return; } }
    render(); },
  closeChatMenu:()=>{ S.chatMenu=null; render(); },
  startVoice:()=>{ if(S._micHold){ S._micHold=false; return; } S._voiceFadeIn=true; startVoice(); },
  endVoice:()=>{ endVoiceLoop(); render(); },
  voiceText:()=>{ endVoiceLoop(); S.focusInput=true; render(); },
  voiceFinish:()=>{ stopListening(); },
  voiceInterrupt:()=>{ clearVoiceReveal(); if(S.voiceAudio){try{S.voiceAudio.pause()}catch(e){}} startVoice(); },
  voiceRetry:()=>{ S._voiceFadeIn=true; startVoice(); },
  speakMsg:(id)=>{ const c=cur(); const m=c&&c.messages.find(x=>x.id===id); if(!m)return; if(S._speakId===id){ stopSpeak(); render(); } else { speakMessage(m); } },
  speakToggle:()=>{ const a=S._speakAudio; if(!a)return; if(a.paused)a.play().catch(()=>{}); else a.pause(); render(); },
  speakStop:()=>{ stopSpeak(); render(); },
  pickPane:(p)=>{ S.settingsPane=p; S.voiceDrop=null; if(p==='Voice'&&!S.audioModels)refreshAudioModels(); render(); },
  toggleVoiceDrop:(w)=>{ S.voiceDrop=(S.voiceDrop===w)?null:w; render(); },
  pickTtsModel:(id)=>{ S.voiceDrop=null; postConfig({ttsModel:id}).then(()=>render()); render(); },
  pickTtsVoice:(id)=>{ S.prefs.ttsVoice=id; savePrefs(); S.voiceDrop=null; render(); },
  pickTtsLang:(id)=>{ S.prefs.ttsLanguage=id; savePrefs(); S.voiceDrop=null; render(); },
  pickSttModel:(id)=>{ S.voiceDrop=null; if(id==='__custom__'){ const v=prompt('Speech-to-text model (Hugging Face repo, mlx_audio-compatible):', (S.config&&S.config.defaults&&S.config.defaults.sttModel)||'mlx-community/parakeet-tdt-0.6b-v2'); if(v&&v.trim()){ postConfig({sttModel:v.trim()}).then(()=>render()); } render(); return; } postConfig({sttModel:id}).then(()=>render()); render(); },
  pickFilter:(f)=>{ S.modelsFilter=f; refreshCatalog(); render(); },
  openDetail:(id)=>{ S.detail=id; render(); },
  closeDetail:()=>{ S.detail=null; render(); },
  install:(id)=>{ ACT.openDetail(id); },
  doInstall:(id)=>startInstall(id),
  cancelInstall:(id)=>{ const m=catModel(id); if(m){ fetch('/v1/models/install/cancel',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id})}); } delete S.installing[id]; render(); },
  attach:()=>{ document.getElementById('filepick').click(); S.attachOpen=false; render(); },
  removeAtt:(i)=>{ S.pendingAtts.splice(+i,1); render(); },
  micUpload:()=>micUpload(),
  toggleEnter:()=>{ S.prefs.sendEnter=!(S.prefs.sendEnter!==false); savePrefs(); render(); },
  toggleHistory:()=>{ S.prefs.saveHistory=!(S.prefs.saveHistory!==false); savePrefs(); if(S.prefs.saveHistory)saveChats(); render(); },
  clearHistory:()=>{ if(!confirm('Clear all conversations stored in this browser?'))return; S.chats={}; try{localStorage.removeItem(LS)}catch(e){} newChat(); },
  toggleRouting:()=>{ S.prefs.autoRouting=!(S.prefs.autoRouting!==false); savePrefs(); render(); },
  pickReasoning:(v)=>{ S.prefs.reasoning=v; savePrefs(); render(); },
  goPane:(p)=>{ S.settingsPane=p; render(); },
  editSysInstr:()=>{ const t=$('#sysinstr'); if(t){ S.prefs.systemInstr=t.value; savePrefs(); } }
};
function closeAll(open){ S.pickerOpen=false; S.engineOpen=false; S.attachOpen=false; S.effortOpen=false; if(open)S[open]=true; }
document.addEventListener('click',e=>{ const t=e.target.closest('[data-act]'); const a=t&&t.getAttribute('data-act');
  // Outside-click closes any open popover, unless the click is inside a popover or on the chip/button
  // that owns it (those toggles handle their own open/close).
  const anyPop=S.pickerOpen||S.effortOpen||S.engineOpen||S.attachOpen;
  if(anyPop && !e.target.closest('.pop') && !/^toggle(Picker|Effort|Engine|Attach)$/.test(a||'')){ closeAll(); if(S.view==='chat')S.focusInput=true; render(); if(!t)return; }
  if(S.voiceDrop && !e.target.closest('.pop') && a!=='toggleVoiceDrop'){ S.voiceDrop=null; render(); if(!t)return; }
  if(S.chatMenu && !e.target.closest('.pop')){ S.chatMenu=null; render(); if(!t)return; }
  if(!t)return; const arg=t.getAttribute('data-arg'); if(ACT[a]){ e.stopPropagation(); ACT[a](arg); } });
// Keyboard: Escape unwinds the most-nested surface; Enter/Space activate focused data-act controls.
document.addEventListener('keydown',e=>{
  if(e.key==='Escape'){
    if(S.chatMenu){ S.chatMenu=null; render(); }
    else if(S.detail){ S.detail=null; render(); }
    else if(S.execOpen){ S.execOpen=false; render(); }
    else if(S.pickerOpen||S.engineOpen||S.attachOpen||S.effortOpen){ closeAll(); render(); }
    else if(S.voice){ ACT.endVoice(); }
    else if(S.view==='models'||S.view==='settings'){ S.view='chat'; render(); }
    return;
  }
  if((e.key==='Enter'||e.key===' ')){ const t=document.activeElement; if(t&&t.getAttribute&&t.getAttribute('data-act')&&t.tagName!=='TEXTAREA'&&t.tagName!=='INPUT'){ e.preventDefault(); const a=t.getAttribute('data-act'); if(ACT[a])ACT[a](t.getAttribute('data-arg')); } }
});
// Right-click a chat in the sidebar → a small Rename / Delete menu at the cursor.
document.addEventListener('contextmenu',e=>{
  const folder=e.target.closest('.folderrow');
  if(folder){ e.preventDefault(); S.chatMenu={type:'folder', id:folder.getAttribute('data-folder'), x:e.clientX, y:e.clientY}; render(); return; }
  const item=e.target.closest('.chatitem[data-chat]'); if(!item)return; e.preventDefault();
  S.chatMenu={type:'chat', id:item.getAttribute('data-chat'), x:e.clientX, y:e.clientY}; render(); });

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
  if(S.sidebarOpen){ body.appendChild(renderSidebar()); body.appendChild(el('div',{cls:'sbackdrop','data-act':'toggleSidebar'})); }
  const main=el('div',{cls:'main'});
  const c=cur(); const has=c&&(c.messages.length||(S.streaming&&S.genChatId===S.current));
  if(!has){ main.appendChild(el('div',{cls:'empty'},'What can I help with?')); S._logNode=null; S._logSig=''; }
  else {
    // Reuse the existing log DOM when the conversation hasn't changed, so opening/closing a popover (or
    // changing model/effort) doesn't rebuild + re-parse the whole thread (which flashed/scroll-jumped).
    const sig=logSig();
    if(S._logNode && S._logSig===sig){ main.appendChild(S._logNode); }
    else { const lg=renderLog(); S._logNode=lg; S._logSig=sig; main.appendChild(lg); }
  }
  main.appendChild(renderComposer());
  if(S.engineOpen) main.appendChild(renderEngine());
  body.appendChild(main);
  if(S.execOpen) body.appendChild(renderExec());
  wrap.appendChild(body);
  return wrap;
}
function esch(s){ return (s||'').replace(/[&<>]/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[m])); }
function escAttr(s){ return esch(s).replace(/"/g,'&quot;'); }
// A cheap fingerprint of the thread: changes only when the messages actually change (not on popover
// toggles). During streaming the bubble is patched in place by throttleRender, so the sig stays stable.
function logSig(){ const c=cur(); if(!c)return ''; const last=c.messages[c.messages.length-1];
  const lastPart=last?(last.id+':'+((last.content||'').length)):'';
  // Include read-aloud state so the per-message speak button repaints (loading →
  // playing → idle) even though the message list itself is unchanged.
  const speakPart=(S._speakId||'')+(S._speakLoading?'L':'');
  return (S.current||'')+'|'+c.messages.length+'|'+lastPart+'|'+((S.streaming&&S.genChatId===S.current)?'S':'')+'|'+speakPart; }
// A chat row — draggable (into folders) and inline-renamable. When it's the one
// being renamed, the title becomes a focused input committed on Enter/blur.
function chatRow(ch){
  if(S.renaming && S.renaming.type==='chat' && S.renaming.id===ch.id){
    return `<div class="chatitem active"><input class="renameinput" id="renameinput" data-rename="chat" data-arg="${ch.id}" value="${escAttr(ch.title||'')}" maxlength="80"></div>`;
  }
  return `<div class="chatitem ${ch.id===S.current?'active':''}" draggable="true" data-chat="${ch.id}" data-act="switchChat" data-arg="${ch.id}">${esch(ch.title||'New chat')}</div>`;
}
function folderRow(f, chats){
  const collapsed=!!f.collapsed;
  const titleHTML = (S.renaming && S.renaming.type==='folder' && S.renaming.id===f.id)
    ? `<input class="renameinput" id="renameinput" data-rename="folder" data-arg="${f.id}" value="${escAttr(f.name||'')}" maxlength="60">`
    : `<span class="fname">${esch(f.name||'Folder')}</span><span class="fcount">${chats.length||''}</span>`;
  let h=`<div class="folderrow" data-folder="${f.id}" data-act="toggleFolder" data-arg="${f.id}">
      <span class="fchev ${collapsed?'':'open'}">${ICON.chevr}</span>
      <span class="ficon">${ICON.folder}</span>${titleHTML}</div>`;
  if(!collapsed){ h+=`<div class="folderchats">`; chats.forEach(ch=>{ h+=chatRow(ch); }); if(!chats.length) h+=`<div class="folderempty">Drop chats here</div>`; h+=`</div>`; }
  return h;
}
function renderSidebar(){
  const sb=el('div',{cls:'sidebar'});
  const byCreated=(a,b)=>b.created-a.created;
  const folders=Object.values(S.folders).sort(byCreated);
  const all=Object.values(S.chats).sort(byCreated);
  const ungrouped=all.filter(ch=>!ch.folderId || !S.folders[ch.folderId]);
  let h=`<div class="sbhead">
      <button class="newchat" data-act="newChat">${ICON.plus}New chat</button>
      <button class="iconbtn nfbtn" data-act="newFolder" title="New folder">${ICON.folderPlus}</button>
    </div>`;
  // Folders first (each a drop target), then ungrouped chats under "Recent".
  folders.forEach(f=>{ const fchats=all.filter(ch=>ch.folderId===f.id); h+=folderRow(f,fchats); });
  h+=`<div class="sgroup ${folders.length?'':'nofolders'}" data-drop-root="1" style="${folders.length?'':'margin-top:0'}">Recent</div>`;
  h+=`<div class="rootchats" data-drop-root="1">`;
  ungrouped.forEach(ch=>{ h+=chatRow(ch); });
  h+=`</div>`;
  sb.innerHTML=h; return sb;
}
// Inline rename: the title becomes a focused input, committed on Enter/blur,
// cancelled on Escape — no popup dialog.
function startRename(type,id){ S.renaming={type,id}; render(); }
function commitRename(){
  const r=S.renaming; if(!r)return;
  const inp=document.getElementById('renameinput'); const v=inp?inp.value.trim():'';
  S.renaming=null;
  if(v){
    if(r.type==='chat'){ const ch=S.chats[r.id]; if(ch){ ch.title=v.slice(0,80); saveChats(); } }
    else { const f=S.folders[r.id]; if(f){ f.name=v.slice(0,60); saveFolders(); } }
  }
  render();
}
function cancelRename(){ if(!S.renaming)return; S.renaming=null; render(); }
function moveChatToFolder(chatId,folderId){
  const ch=S.chats[chatId]; if(!ch)return;
  if(folderId){ ch.folderId=folderId; const f=S.folders[folderId]; if(f)f.collapsed=false; }
  else delete ch.folderId;
  saveChats(); saveFolders(); render();
}
// Wire the sidebar's imperative bits after each render: focus the rename input and
// bind its commit/cancel keys; make chats draggable into folders / back to Recent.
function wireSidebar(){
  const inp=document.getElementById('renameinput');
  if(inp && !inp._wired){ inp._wired=true;
    inp.focus(); try{ inp.select(); }catch(e){}
    inp.onkeydown=e=>{ e.stopPropagation(); if(e.key==='Enter'){ e.preventDefault(); commitRename(); } else if(e.key==='Escape'){ e.preventDefault(); cancelRename(); } };
    inp.onblur=()=>commitRename();
    inp.onclick=e=>e.stopPropagation();
  }
  document.querySelectorAll('.chatitem[draggable="true"]').forEach(it=>{ if(it._dnd)return; it._dnd=true;
    it.addEventListener('dragstart',e=>{ S._dragChat=it.getAttribute('data-chat'); e.dataTransfer.effectAllowed='move'; try{ e.dataTransfer.setData('text/plain',S._dragChat); }catch(_){} it.classList.add('dragging'); });
    it.addEventListener('dragend',()=>{ S._dragChat=null; it.classList.remove('dragging'); document.querySelectorAll('.dropover').forEach(x=>x.classList.remove('dropover')); });
  });
  const targets=[];
  document.querySelectorAll('.folderrow').forEach(f=>targets.push([f,f.getAttribute('data-folder')]));
  document.querySelectorAll('[data-drop-root]').forEach(r=>targets.push([r,null]));
  targets.forEach(([elm,fid])=>{ if(elm._dnd)return; elm._dnd=true;
    elm.addEventListener('dragover',e=>{ if(!S._dragChat)return; e.preventDefault(); e.dataTransfer.dropEffect='move'; elm.classList.add('dropover'); });
    elm.addEventListener('dragleave',()=>elm.classList.remove('dropover'));
    elm.addEventListener('drop',e=>{ e.preventDefault(); elm.classList.remove('dropover'); if(S._dragChat)moveChatToFolder(S._dragChat,fid); });
  });
}
const _seen=new Set();
function streamInner(){ const s=splitThink(S.streamText,{streaming:true,expectReasoning:S.streamReason}); let inner='';
  if(s.reason||s.thinking) inner+=`<details class="reason" open><summary class="live">Thinking…</summary><div class="rc">${esch(s.reason)}</div></details>`;
  if(s.answer) inner+=`<div class="asttext streaming">${md(s.answer)}</div>`;
  else if(!s.reason) inner+='<div class="asttext"><span class="typing"><i></i><i></i><i></i></span></div>';
  return inner; }
function renderLog(){
  const log=el('div',{cls:'log'}); const th=el('div',{cls:'thread'}); const c=cur();
  (c?c.messages:[]).forEach(m=>{ th.appendChild(renderMsg(m)); });
  if(S.streaming&&S.genChatId===S.current){ const d=el('div',{cls:'msg'}); d.innerHTML=`<div class="asst" id="streamwrap">${streamInner()}</div>`; th.appendChild(d); }
  log.appendChild(th);
  setTimeout(()=>{ log.scrollTop=log.scrollHeight; },0);
  return log;
}
function renderMsg(m){
  const fresh=m.id&&!_seen.has(m.id); if(m.id)_seen.add(m.id);
  const d=el('div',{cls:'msg'+(fresh?' msgin':'')});
  if(m.isUser||m.role==='user'){ let a='';
    (m.attachments||[]).forEach((x,ix)=>{
      if(x.kind==='image')a+=`<img src="${x.dataURL}">`;
      else if(x.kind==='audio')a+=`<div style="margin:2px 0 6px">${audioPlayer(x.dataURL,(m.id||'m')+'-'+ix)}</div>`;
      else a+=`<div class="attpill"><span class="ai"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M7 3h7l4 4v14H7z"/><path d="M14 3v4h4"/></svg></span><span class="an"><b>${esch(x.name||'file')}</b><span class="mono" style="font-size:10px;color:var(--muted)">${esch(x.size||'')}</span></span></div>`;
    });
    // Audio: a "Transcribing…" indicator while STT runs, then the transcription as
    // a muted caption — distinct from text the user actually typed.
    const cap = m.transcribing
      ? `<div class="transcap loading"><span class="typing"><i></i><i></i><i></i></span>Transcribing…</div>`
      : (m.transcript ? `<div class="transcap">${esch(m.transcript)}</div>` : '');
    const body=(a?`<div class="attwrap">${a}</div>`:'')+cap+(m.content?md(m.content):'');
    d.innerHTML=`<div class="userrow"><div class="userbubble">${body}</div></div>`; return d; }
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
  // Footer: manual "read aloud" control (speech is opt-in, per message — never auto)
  // plus the execution-inspector meta link.
  const speakable=(s.answer||m.content||'').trim();
  if(speakable || m.meta){
    const speaking=(S._speakId===m.id); const loading=speaking&&S._speakLoading;
    const sb = speakable
      ? `<button class="sbtn${speaking?' on':''}${loading?' load':''}" data-act="speakMsg" data-arg="${m.id}" title="${speaking?'Stop':'Read aloud'}" aria-label="${speaking?'Stop reading aloud':'Read aloud'}">${(speaking&&!loading)?ICON.stop:ICON.speaker}</button>`
      : '';
    const ml = m.meta ? `<span class="metaline" data-act="openExec" data-arg="${m.id}">${esch(m.meta)}</span>` : '';
    h+=`<div class="asstfoot">${ml}${sb}</div>`;
  }
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
// Mini read-aloud player above the composer while a reply is being spoken: it
// shows synth/loading, play-pause, a progress bar, and a close/stop button.
function renderMiniPlayer(){
  if(!S._speakAudio && !S._speakLoading) return '';
  const loading=!!S._speakLoading; const playing=!!(S._speakAudio && !S._speakAudio.paused);
  const btn = loading ? `<span class="mpspin"></span>` : `<button class="mpbtn" data-act="speakToggle" title="${playing?'Pause':'Play'}">${playing?ICON.pause:ICON.play}</button>`;
  return `<div class="miniplayer">${btn}
     <div class="mpmeta"><span class="mplbl">${loading?'Preparing audio…':'Reading aloud'}</span>
       <div class="mptrack"><div class="mpfill" id="mpfill"></div></div></div>
     <span class="mptime mono" id="mptime">0:00</span>
     <button class="mpbtn" data-act="speakStop" title="Stop">${ICON.xmark}</button></div>`;
}
function renderComposer(){
  const c=el('div',{cls:'composer'});
  const si=statusInfo();
  const mlabel=S.modelSel==='Auto'?'Auto':(S.modelSel==='Apple Intelligence'?'Apple Intelligence':shortModel(S.modelSel));
  c.innerHTML=`${renderMiniPlayer()}<div class="cbox">
     ${S._recording?`<div style="display:flex;align-items:center;gap:9px;font-size:12.5px;color:var(--ink);padding:2px 2px 4px"><span style="width:9px;height:9px;border-radius:50%;background:#c0392b;animation:eshpulse 1s ease-in-out infinite"></span>Recording <span class="mono" id="rectime" style="font-size:12px">0:00</span><span style="color:var(--muted)">— release to attach</span></div>`:''}
     ${(cur()&&cur().queue&&cur().queue.length)?renderQueue():''}
     ${S.pendingAtts.length?renderChips():''}
     <div style="display:flex;align-items:center;gap:10px">
       <button class="cround" data-act="attach" title="Attach">${ICON.plus}</button>
       <textarea class="cinput" id="input" rows="1" placeholder="Ask anything…"></textarea>
       <button class="cchip" data-act="togglePicker" title="Model"><span class="lbl">${esch(mlabel)}</span><span class="chev">▾</span></button>
       <button class="cchip ghost" data-act="toggleEffort" title="Effort">${esch(effortWord())}</button>
       <span class="cdiv"></span>
       <button class="cround" id="micbtn" style="border:none${S._recording?';background:#c0392b;color:#fff':''}" data-act="startVoice" title="Tap for voice · hold to record audio">${ICON.mic}</button>
       ${(S.streaming&&S.genChatId===S.current)?`<button class="cround" id="queuebtn" data-act="queueDraft" title="Queue this message · ⌥Enter" style="border:none;opacity:${(S.draft&&S.draft.trim())?'1':'.4'}">${ICON.queue}</button><button class="send" data-act="stop" title="Stop" style="background:var(--ink)">${ICON.stop}</button>`:(()=>{ const on=!!((S.draft&&S.draft.trim())||S.pendingAtts.length); return `<button class="send" id="sendbtn" data-act="send" title="Send" style="background:${on?'var(--ink)':'#dedbd4'};cursor:${on?'pointer':'default'}">${ICON.up}</button>`; })()}
     </div>
     ${S.attachOpen?renderAttach():''}
     ${S.pickerOpen?renderPicker():''}
     ${S.effortOpen?renderEffort():''}
     <input type="file" id="filepick" accept="image/*,audio/*,.txt,.md,.json,.csv,.pdf" multiple style="display:none">
   </div>
   <div class="statusrow"><button class="statusbtn" data-act="toggleEngine" title="Engine status"><span class="dot" style="background:${si.amber?'var(--amber)':'var(--ink)'}"></span>${esch(si.label)}</button></div>`;
  setTimeout(()=>{ const ta=$('#input'); if(ta){ ta.value=S.draft||'';
     ta.oninput=()=>{ S.draft=ta.value; ta.style.height='auto'; ta.style.height=Math.min(160,ta.scrollHeight)+'px'; updateSendState(); };
     ta.oncompositionstart=()=>{ S._composing=true; }; ta.oncompositionend=()=>{ S._composing=false; };
     ta.onkeydown=e=>{ if(e.key!=='Enter')return;
       // IME/composition safety: while composing (CJK etc.), Enter confirms the candidate — never send/queue.
       if(e.isComposing || e.keyCode===229 || S._composing) return;
       // Queue: Option/Alt+Enter, or Cmd/Ctrl+Shift+Enter (auto-sends in order when the assistant is free).
       if(e.altKey || ((e.metaKey||e.ctrlKey)&&e.shiftKey)){ e.preventDefault(); enqueueDraft(); return; }
       // Cmd/Ctrl+Enter always sends (alternative to Enter).
       if((e.metaKey||e.ctrlKey)&&!e.shiftKey){ e.preventDefault(); send(); return; }
       // Shift+Enter → new line (conventional): let the textarea handle it.
       if(e.shiftKey) return;
       // Plain Enter sends when "Send with Enter" is on; otherwise it's a new line.
       if(S.prefs.sendEnter!==false){ e.preventDefault(); send(); } };
     const fp=$('#filepick'); if(fp) fp.onchange=onFiles; updateSendState();
     if(S.focusInput&&S.view==='chat'){ S.focusInput=false; ta.focus(); } }
     wireEffortSlider(); wireMicHold(); },0);
  return c;
}
// Effort slider: drag the knob (or click anywhere on the track) to change effort. Previews the knob
// during the drag without a full re-render, and commits the choice on release.
function wireEffortSlider(){ const sl=document.getElementById('effslider'); if(!sl)return;
  const stops=['Off','Low','Medium','High']; const knob=document.getElementById('effknob');
  const idxFromX=cx=>{ const r=sl.getBoundingClientRect(); let f=r.width?(cx-r.left)/r.width:0; f=Math.max(0,Math.min(1,f)); return Math.max(0,Math.min(3,Math.floor(f*4))); };
  let dragging=false;
  const preview=cx=>{ const i=idxFromX(cx); if(knob){ knob.style.transition='none'; knob.style.left=((i+0.5)/4*100)+'%'; } };
  sl.onpointerdown=e=>{ dragging=true; try{sl.setPointerCapture(e.pointerId)}catch(_){} preview(e.clientX); e.preventDefault(); };
  sl.onpointermove=e=>{ if(dragging)preview(e.clientX); };
  const end=e=>{ if(!dragging)return; dragging=false; ACT.pickEffort(stops[idxFromX(e.clientX)]); };
  sl.onpointerup=end; sl.onpointercancel=end;
}
// Mic button: a quick tap opens voice mode (data-act click); pressing and holding records an audio clip
// that is attached (playable) and, once sent, plays back in the chat.
function wireMicHold(){ const mic=document.getElementById('micbtn'); if(!mic)return; let holdT=null;
  mic.onpointerdown=e=>{ if(S._recording)return; S._recCancel=false; holdT=setTimeout(()=>{ holdT=null; startAudioRecording(); }, 380); };
  const end=()=>{ if(holdT){ clearTimeout(holdT); holdT=null; return; }  // released before the long-press → normal tap (click opens voice)
    S._micHold=true;  // a long-press happened: suppress the click that would open voice mode
    if(S._recording) stopAudioRecording(); else S._recCancel=true; };
  mic.onpointerup=end; mic.onpointerleave=end; mic.onpointercancel=end; }
function fmtDur(ms){ const s=Math.max(0,Math.round(ms/1000)); return Math.floor(s/60)+':'+String(s%60).padStart(2,'0'); }
// Custom on-brand audio player (no native <audio controls>). Markup only — wired by wireAudioPlayers().
function audioPlayer(dataURL,id){ return `<div class="aplayer" data-aud="${esch(id||'')}">
  <button class="pp" type="button"><svg class="i-play" width="13" height="13" viewBox="0 0 24 24" fill="currentColor"><path d="M7 5l12 7-12 7z"/></svg><svg class="i-pause" width="12" height="12" viewBox="0 0 24 24" fill="currentColor" style="display:none"><rect x="6" y="5" width="4.5" height="14" rx="1.2"/><rect x="13.5" y="5" width="4.5" height="14" rx="1.2"/></svg></button>
  <div class="track"><div class="fill"></div></div>
  <span class="atime">0:00</span>
  <audio preload="metadata" src="${dataURL}" style="display:none"></audio></div>`; }
function wireAudioPlayers(){ document.querySelectorAll('.aplayer').forEach(p=>{ if(p._w)return; p._w=true;
  const audio=p.querySelector('audio'), fill=p.querySelector('.fill'), time=p.querySelector('.atime'), track=p.querySelector('.track');
  const ip=p.querySelector('.i-play'), ipa=p.querySelector('.i-pause');
  const fmt=s=>{ s=Math.max(0,Math.floor(isFinite(s)?s:0)); return Math.floor(s/60)+':'+String(s%60).padStart(2,'0'); };
  const setP=on=>{ ip.style.display=on?'none':'block'; ipa.style.display=on?'block':'none'; };
  let dur=0;
  const showDur=()=>{ if(audio.duration===Infinity||isNaN(audio.duration)){ const h=()=>{ audio.removeEventListener('timeupdate',h); audio.currentTime=0; dur=audio.duration; if(audio.paused)time.textContent=fmt(dur); }; audio.addEventListener('timeupdate',h); try{ audio.currentTime=1e101; }catch(e){} } else { dur=audio.duration; if(audio.paused)time.textContent=fmt(dur); } };
  audio.onloadedmetadata=showDur; if(audio.readyState>=1)showDur();
  p.querySelector('.pp').onclick=()=>{ if(audio.paused){ document.querySelectorAll('.aplayer audio').forEach(a=>{ if(a!==audio)a.pause(); }); audio.play().catch(()=>{}); } else audio.pause(); };
  audio.onplay=()=>setP(true); audio.onpause=()=>setP(false);
  audio.onended=()=>{ setP(false); fill.style.width='0%'; time.textContent=fmt(dur); };
  audio.ontimeupdate=()=>{ const d=dur||audio.duration||0; fill.style.width=(d?Math.min(100,audio.currentTime/d*100):0)+'%'; if(!audio.paused)time.textContent=fmt(d?d-audio.currentTime:audio.currentTime); };
  track.onclick=e=>{ const r=track.getBoundingClientRect(); const f=Math.max(0,Math.min(1,(e.clientX-r.left)/r.width)); const d=dur||audio.duration; if(isFinite(d)&&d>0)audio.currentTime=f*d; };
}); }
async function startAudioRecording(){
  try{ const stream=await navigator.mediaDevices.getUserMedia({audio:true});
    if(S._recCancel){ stream.getTracks().forEach(t=>t.stop()); S._recCancel=false; return; }  // released during arming
    S._recStream=stream; S._recChunks=[]; const rec=new MediaRecorder(stream); S._recRec=rec;
    rec.ondataavailable=e=>{ if(e.data&&e.data.size)S._recChunks.push(e.data); };
    rec.onstop=()=>finishAudioRecording();
    rec.start(); S._recording=true; S._recStart=performance.now(); render();
    S._recTimer=setInterval(()=>{ const el=document.getElementById('rectime'); if(el)el.textContent=fmtDur(performance.now()-S._recStart); },250);
  }catch(e){ S._recording=false; S._micHold=false; render(); }
}
function stopAudioRecording(){ try{ if(S._recRec&&S._recRec.state!=='inactive')S._recRec.stop(); }catch(e){} }
function finishAudioRecording(){
  if(S._recTimer){ clearInterval(S._recTimer); S._recTimer=null; }
  if(S._recStream){ S._recStream.getTracks().forEach(t=>t.stop()); S._recStream=null; }
  const dur=performance.now()-(S._recStart||performance.now());
  const blob=new Blob(S._recChunks||[],{type:(S._recRec&&S._recRec.mimeType)||'audio/webm'});
  const r=new FileReader(); r.onload=()=>{ S.pendingAtts.push({kind:'audio', name:'Recording', size:fmtDur(dur), mime:blob.type, dataURL:r.result});
    S._recording=false; S.focusInput=true; render(); }; r.readAsDataURL(blob);
}
function updateSendState(){ const hasText=!!(S.draft&&S.draft.trim());
  const q=document.querySelector('#queuebtn'); if(q)q.style.opacity=hasText?'1':'.4';   // reflect draft while generating
  const b=document.querySelector('#sendbtn'); if(!b)return; const on=hasText||!!S.pendingAtts.length;
  b.style.background=on?'var(--ink)':'#dedbd4'; b.style.cursor=on?'pointer':'default'; b.setAttribute('aria-disabled',on?'false':'true'); }
function renderQueue(){ const q=(cur()&&cur().queue)||[]; if(!q.length)return '';
  let h='<div style="display:flex;flex-direction:column;gap:6px;margin-bottom:2px">';
  h+='<div style="font:500 9.5px var(--mono);letter-spacing:.1em;text-transform:uppercase;color:var(--faint)">Queued · '+q.length+'</div>';
  q.forEach((item,i)=>{ const nAtt=(item.atts&&item.atts.length)||0; const label=item.text||(nAtt?('['+nAtt+' attachment'+(nAtt>1?'s':'')+']'):'(empty)');
    h+=`<div style="display:flex;align-items:center;gap:8px;background:var(--panel2);border:1px solid var(--line);border-radius:9px;padding:6px 10px">
    <span style="width:6px;height:6px;border-radius:50%;background:var(--faint);flex-shrink:0"></span>
    <span style="flex:1;min-width:0;font-size:12.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${esch(label)}</span>
    ${(nAtt&&item.text)?`<span class="mono" style="font-size:10px;color:var(--muted)">+${nAtt}</span>`:''}
    <span class="iconbtn" data-act="removeQueued" data-arg="${i}" style="padding:2px;font-size:12px" title="Remove">✕</span></div>`; });
  return h+'</div>'; }
function renderChips(){ let h='<div style="display:flex;flex-wrap:wrap;gap:8px;margin-bottom:9px">';
  S.pendingAtts.forEach((a,i)=>{ const ic=a.kind==='image'?'<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.8"><rect x="3" y="4" width="18" height="16" rx="2"/><circle cx="8.5" cy="9.5" r="1.6"/><path d="M4 17l5-4 4 3 3-2 4 3"/></svg>':a.kind==='audio'?'<svg width="15" height="15" viewBox="0 0 24 24" fill="#fff"><rect x="4" y="9" width="2.4" height="6" rx="1"/><rect x="8.4" y="6" width="2.4" height="12" rx="1"/><rect x="12.8" y="8" width="2.4" height="8" rx="1"/><rect x="17.2" y="10" width="2.4" height="4" rx="1"/></svg>':'<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.8"><path d="M7 3h7l4 4v14H7z"/><path d="M14 3v4h4"/></svg>';
    if(a.kind==='audio'){
      // A recorded/attached audio clip — playable right in the composer before sending (custom player).
      h+=`<div style="display:flex;align-items:center;gap:6px">${audioPlayer(a.dataURL,'pa'+i)}<span class="iconbtn" data-act="removeAtt" data-arg="${i}" style="padding:2px;font-size:14px">✕</span></div>`;
    } else {
      h+=`<div style="display:flex;align-items:center;gap:9px;background:var(--panel2);border:1px solid var(--line);border-radius:10px;padding:8px 10px 8px 8px">
        <span style="width:30px;height:30px;border-radius:7px;background:var(--ink);display:flex;align-items:center;justify-content:center;flex-shrink:0">${ic}</span>
        <span style="min-width:0"><div style="font-size:12.5px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:150px">${esch(a.name)}</div><div class="mono" style="font-size:10.5px;color:var(--muted)">${esch(a.size||'')}</div></span>
        <span class="iconbtn" data-act="removeAtt" data-arg="${i}" style="padding:2px;font-size:14px">✕</span></div>`;
    } });
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
    <div id="effslider" style="position:relative;height:30px;cursor:pointer;touch-action:none">
      <div style="position:absolute;left:10px;right:10px;top:13px;height:4px;background:rgba(32,30,27,.1);border-radius:2px;pointer-events:none"></div>
      <div style="position:absolute;inset:0;display:flex">${dots}</div>
      <span id="effknob" style="position:absolute;top:4px;left:${pct};transform:translateX(-50%);width:22px;height:22px;border-radius:50%;background:#fff;border:1px solid rgba(32,30,27,.18);box-shadow:0 1px 5px rgba(32,30,27,.28);pointer-events:none;transition:left .12s"></span>
    </div>
    <div style="display:flex;margin-top:2px">${labels}</div>
    <div style="font-size:12px;color:var(--muted);line-height:1.5;margin-top:14px;min-height:34px">${esch(hint)}</div>`;
  return '<div class="pop" style="right:0;bottom:calc(100% + 10px);width:290px;padding:18px 20px;box-sizing:border-box">'+inner+'</div>';
}
function volLabel(path){ if(!path)return 'Model storage'; const m=path.match(/\/Volumes\/([^/]+)/); return m?m[1]:'Internal storage'; }
function gb(bytes){ return (bytes/1073741824).toFixed(bytes<10737418240?1:0)+' GB'; }
function renderEngine(){
  // Center with margin (not transform) so the eshpop entrance animation doesn't
  // fight the centering and shift the panel sideways.
  const e=S.engine; const p=el('div',{cls:'pop'}); p.style.cssText+='bottom:56px;left:50%;margin-left:-170px;width:340px';
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
    <div class="settingsbody" style="flex:1;display:flex;border-top:1px solid var(--line);min-height:0">
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
  if(p==='Voice') return renderVoicePane();
  if(p==='Advanced'){ const srv=(e.server&&e.server.endpoint)||'http://127.0.0.1:11435'; return `<div style="font-size:15px;font-weight:600;margin-bottom:14px">Advanced</div><div style="max-width:480px">
      <div style="display:flex;align-items:center;gap:9px"><span style="font-size:13.5px;font-weight:600">API server</span><span class="sp" style="flex:1"></span><span class="dot"></span><span style="font-size:12px;color:var(--muted)">Running</span></div>
      <div style="margin-top:12px;display:flex;align-items:center;gap:10px;background:var(--panel2);border:1px solid var(--line);border-radius:8px;padding:10px 14px"><span class="mono" style="font-size:12.5px">${esch(srv)}</span></div>
      <div style="padding:12px 0 0;display:flex;gap:14px;font-size:12px;color:rgba(32,30,27,.65)"><span>✓ Native esh</span><span>✓ OpenAI-compatible</span></div>
      <div style="margin-top:8px;font-size:12px;color:var(--muted);line-height:1.5">Structured output, capability resolution and the Request Inspector are surfaced per response in the Execution panel.</div></div>`; }
  return `<div style="font-size:15px;font-weight:600;margin-bottom:10px">${p}</div><div style="font-size:13px;color:var(--muted)">Designed in the canvas — more controls arrive in a later rc.</div>`;
}
// A settings dropdown row (label + current-value chip that opens a checkmark menu). Options come from
// real esh capabilities — never a fabricated list.
function vdropRow(which,label,valueText,options,act){
  const open=S.voiceDrop===which;
  let menu='';
  if(open){ let rows='';
    options.forEach(o=>{ rows+=`<div class="pickrow ${o.selected?'sel':''}" data-act="${act}" data-arg="${esch(o.id)}"><span style="display:flex;flex-direction:column;min-width:0"><span style="white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${esch(o.name)}</span>${o.sub?`<span style="font-size:11px;color:var(--muted)">${esch(o.sub)}</span>`:''}</span><span class="sp" style="flex:1"></span>${o.selected?'<span class="ck">✓</span>':''}</div>`; });
    menu=`<div class="pop" style="right:0;top:calc(100% + 4px);width:320px;padding:6px 0;max-height:300px;overflow-y:auto">${rows}</div>`;
  }
  return `<div style="position:relative;display:flex;justify-content:space-between;align-items:center;padding:12px 0;border-bottom:1px solid var(--line)">
    <span style="font-size:13.5px">${esch(label)}</span>
    <button class="cchip" data-act="toggleVoiceDrop" data-arg="${which}" style="background:${open?'rgba(32,30,27,.09)':'rgba(32,30,27,.05)'}"><span class="lbl">${esch(valueText)}</span><span class="chev">▾</span></button>
    ${menu}</div>`;
}
function renderVoicePane(){
  const cfg=(S.config&&S.config.defaults)||{};
  const models=S.audioModels||[];
  // Resolve the active TTS model: configured, else the built-in default (Soprano), else the first.
  const sel=models.find(m=>m.id===cfg.ttsModel) || models.find(m=>/soprano/i.test(m.id)) || models[0] || null;
  const ttsName=sel?(sel.display_name||shortModel(sel.id)):(cfg.ttsModel?shortModel(cfg.ttsModel):'Soprano (default)');
  const modelOpts=models.map(m=>({id:m.id,name:m.display_name||shortModel(m.id),sub:((m.languages||[]).map(l=>l.display_name||l.id).join(', ')||'')||'Local',selected:sel&&m.id===sel.id}));
  // Speaker voices for the active model (+ Auto). Stored as a browser pref, sent with each speech call.
  const voices=(sel&&sel.voices)||[]; const curVoice=S.prefs.ttsVoice||'';
  const voiceOpts=[{id:'',name:'Auto',sub:'Model default',selected:!curVoice}].concat(voices.map(v=>({id:v.id,name:v.display_name||v.id,selected:curVoice===v.id})));
  const voiceName=curVoice?(voices.find(v=>v.id===curVoice)||{}).display_name||curVoice:(voices.length?'Auto':'Default');
  // Languages for the active model (+ Automatic).
  const langs=(sel&&sel.languages)||[]; const curLang=S.prefs.ttsLanguage||'';
  const langOpts=[{id:'',name:'Automatic',selected:!curLang}].concat(langs.map(l=>({id:l.id,name:l.display_name||l.id,selected:curLang===l.id})));
  const langName=curLang?(langs.find(l=>l.id===curLang)||{}).display_name||curLang:'Automatic';
  // STT: the verified default is Parakeet; other mlx_audio STT repos can be set via Custom (downloads on
  // first use). No fabricated model list.
  const PARA='mlx-community/parakeet-tdt-0.6b-v2'; const curStt=cfg.sttModel||PARA;
  const sttName=curStt===PARA?'Parakeet 0.6B':shortModel(curStt);
  const sttOpts=[{id:PARA,name:'Parakeet 0.6B',sub:'Local · fast · English',selected:curStt===PARA},{id:'__custom__',name:'Custom model…',sub:'Any mlx_audio STT repo',selected:curStt!==PARA}];
  const loading=!S.audioModels;
  return `<div style="font-size:15px;font-weight:600;margin-bottom:8px">Voice</div>
    <div style="display:flex;flex-direction:column;max-width:520px">
      ${vdropRow('voice','Voice',voiceName,voiceOpts,'pickTtsVoice')}
      ${vdropRow('model','Voice model',loading?'Loading…':ttsName,modelOpts,'pickTtsModel')}
      ${vdropRow('stt','Speech-to-text',sttName,sttOpts,'pickSttModel')}
      ${vdropRow('lang','Language',langName,langOpts,'pickTtsLang')}
    </div>
    <div style="max-width:520px;font-size:12px;color:var(--muted);line-height:1.55;margin-top:10px">Assistant replies don’t speak automatically — use the <b style="font-weight:600;color:var(--ink)">read-aloud</b> button under any message to hear it.</div>
    <div style="max-width:520px;font-size:12px;color:var(--muted);line-height:1.55;margin-top:6px">Speaking with <b style="font-weight:600;color:var(--ink)">${esch(ttsName)}</b> · listening with <b style="font-weight:600;color:var(--ink)">${esch(sttName)}</b>. All speech stays on this Mac — models download on first use.</div>`;
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
  const v=el('div',{cls:'voicewrap'+(S._voiceFadeIn?' enter':'')}); S._voiceFadeIn=false;
  if(S.voice==='error'){
    v.innerHTML=`<div class="vstage"><div style="max-width:360px;text-align:center;display:flex;flex-direction:column;align-items:center;gap:16px">
      <span style="width:52px;height:52px;border-radius:50%;background:rgba(32,30,27,.05);display:flex;align-items:center;justify-content:center;color:rgba(32,30,27,.55)"><svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"><rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5.5 11.5a6.5 6.5 0 0 0 13 0"/><path d="M12 18v3"/><path d="M4 4l16 16"/></svg></span>
      <div style="font-size:17px;font-weight:600">Voice unavailable</div>
      <div style="font-size:13px;color:var(--muted);line-height:1.55">${esch(S.voiceError||'')}</div>
      <div style="display:flex;gap:10px;margin-top:2px"><button class="btn" style="padding:9px 20px;font-size:13px" data-act="voiceRetry">Try again</button><button class="btn ghost" style="padding:9px 18px;font-size:13px" data-act="voiceText">Back to text</button></div></div></div>
      <div class="vctrls"><div class="vctrlcol"><span class="vctrl solid" data-act="endVoice" title="End voice chat">${ICON.xmark}</span><span class="vctrllbl">End</span></div></div>`;
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
  // Keep the answer container present through the whole speaking phase so word-by-word reveal can update
  // just this node (no full re-render → no flicker).
  const ans=(S.voice==='speaking')?`<div class="vanswer" id="vanswer">${esch(S.voiceAnswer||'')}</div>`:'';
  const hint=S.voice==='listening'?'Just pause when you’re done':(S.voice==='speaking'?'Tap the wave to interrupt':'');
  v.innerHTML=`<div class="vstage">${orb}<div class="vlabel">${label}</div>${mid}${ans}<div class="vhint">${esch(hint)}</div></div>
    <div class="vctrls">
      <div class="vctrlcol"><span class="vctrl line" data-act="voiceText" title="Back to text">${ICON.keyboard}</span><span class="vctrllbl">Text</span></div>
      <div class="vctrlcol"><span class="vctrl solid" data-act="endVoice" title="End voice chat">${ICON.xmark}</span><span class="vctrllbl">End</span></div>
    </div>
    <div class="vfoot">Everything is transcribed into the chat</div>`;
  return v;
}

/* ---------- send + streaming ---------- */
// Decode text/document attachments to plain text for the model (never images/audio).
function attText(m){ let s=''; if(m.transcript&&m.transcript.trim()) s+=m.transcript.trim(); (m.attachments||[]).forEach(x=>{ if(x.kind!=='image'&&x.kind!=='audio'&&x.dataURL){ try{ const b64=(x.dataURL.split(',')[1]||''); const txt=decodeURIComponent(escape(atob(b64))); if(txt.trim()) s+='\n\n[Attached file: '+(x.name||'file')+']\n'+txt.slice(0,20000); }catch(e){} } }); return s; }
// Transcribe audio attachments (STT) so a recorded voice message becomes text the model can answer.
async function transcribeAtts(atts){ const out=[];
  for(const a of (atts||[])){ if(a.kind!=='audio'||!a.dataURL)continue;
    try{ const b64=(a.dataURL.split(',')[1]||''); const r=await fetch('/v1/audio/transcriptions',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({audio:b64,filename:'recording.webm'})});
      if(r.ok){ const j=await r.json(); if(j&&j.text&&j.text.trim())out.push(j.text.trim()); } }catch(e){} }
  return out.join(' ').trim(); }
// `queued` (optional) = {chatId,text,atts} routes a queued message to its ORIGINAL conversation, so a
// queued message never executes in whatever chat happens to be open now.
async function send(queued){
  stopSpeak();
  let text, atts, c, ta=null;
  if(queued){ c=S.chats[queued.chatId]; if(!c||S.controller)return; text=(queued.text||'').trim(); atts=(queued.atts||[]).slice(); }
  else { ta=$('#input'); text=ta?ta.value.trim():(S.draft||'').trim(); if((!text&&!S.pendingAtts.length)||S.controller) return; c=cur()||(newChat(),cur()); atts=S.pendingAtts.slice(); S.pendingAtts=[]; }
  c.messages.push({id:uid(),role:'user',content:text,attachments:atts});
  const userMsg=c.messages[c.messages.length-1];
  if(c.title==='New chat'&&text) c.title=text.slice(0,40);
  if(!queued){ S.draft=''; if(ta)ta.value=''; } S.focusInput=true; render();
  // An audio attachment with no text: transcribe it so the model has text to answer (it can't hear
  // audio); the clip stays playable in the bubble.
  if(!text && atts.some(a=>a.kind==='audio')){
    userMsg.transcribing=true; render();                       // show a "Transcribing…" indicator
    const tr=await transcribeAtts(atts);
    userMsg.transcribing=false;
    // Keep the clip as the message; show the transcription as a caption (not as
    // typed text). The model still receives it via attText().
    if(tr){ userMsg.transcript=tr; if(c.title==='New chat')c.title=tr.slice(0,40); }
    saveChats(); render();
  }
  // Nothing the model can act on (audio-only + transcription empty/unavailable) → keep the message
  // playable, but don't send an empty conversation to the model.
  if(!((userMsg.content||'')+attText(userMsg)).trim()){ saveChats(); return; }
  // Auto routing runs through the real Scheduler: send its chosen model explicitly so the server uses
  // the model the UI shows (and reasoning detection matches the actual model).
  let resolved=S.modelSel;
  if(resolved==='Auto'){ const opt={Balanced:'balanced',Quality:'high',Speed:'fast','Low Memory':'balanced'}[S.optimize]||'balanced';
    const sc=await api('/v1/schedule?goal=general&quality='+opt); if(sc){ S.schedule=sc; if(sc.selectedModelID) resolved=sc.selectedModelID; } }
  let reasoning=looksReasoning(resolved);
  if(S.prefs.reasoning==='Off')reasoning=false; else if(S.prefs.reasoning==='On')reasoning=true;
  S.genChatId=c.id;   // the generation (and its streaming UI) belongs to THIS conversation
  S.streaming=true; S.streamText=''; S.streamReason=reasoning; S.streamThinkMs=undefined; S.focusInput=true; saveChats(); render();
  S.controller=new AbortController(); const t0=performance.now();
  const sys=(S.prefs.systemInstr||'').trim();
  // Text/document attachments are decoded and appended to the user message so the model actually sees
  // the file contents (image/audio are shown in the bubble; vision/transcription is model-dependent).
  const msgs=(sys?[{role:'system',content:sys}]:[]).concat(c.messages.filter(m=>m.role).map(m=>({role:m.role,content:(m.content||'')+(m.role==='user'?attText(m):'')})));
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
    if(_rt){ clearTimeout(_rt); _rt=null; }
    S.streaming=false; S.genChatId=null; S.streamText=''; S.controller=null; S.focusInput=true; saveChats(); render(); return;
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
  // A backend/load failure arrives as streamed "[error] …" content (not an HTTP
  // error), so it would otherwise render as a normal reply with a read-aloud
  // button. Detect it and show the friendly error card (with Try again / Continue
  // with Auto) instead — e.g. a model whose files are no longer on disk.
  const rawAns=(splitThink(S.streamText).answer||S.streamText).trim();
  const errM=rawAns.match(/^\[error\]\s*([\s\S]+)$/i);
  if(errM){ let detail=errM[1].trim(); let title=(auto?'The model':shortModel(resolved||S.modelSel))+' couldn’t respond';
    if(/install path does not exist|Model install path/i.test(detail)){ title='This model isn’t available'; detail='Its files aren’t on this Mac anymore. Reinstall it from the model browser, or continue with Auto.'; }
    c.messages.push({id:uid(),role:'assistant',isError:true, model:shortModel(resolved||S.modelSel), lastUser:text, title, detail});
    if(_rt){ clearTimeout(_rt); _rt=null; }
    S.streaming=false; S.genChatId=null; S.streamText=''; S.controller=null; S.focusInput=true; saveChats(); render();
    if(S._stopQueue){ S._stopQueue=false; } else { maybeSendQueue(c.id); }
    return;
  }
  c.messages.push({id:uid(),role:'assistant',content:S.streamText,reasoning:reasoning,thinkMs:S.streamThinkMs,truncated:truncated,
    meta:secs+'s'+(auto?' · '+shortModel(resolved||''):''), exec:exec});
  if(_rt){ clearTimeout(_rt); _rt=null; }   // drop any trailing throttle so it can't rebuild + steal focus
  S.streaming=false; S.genChatId=null; S.streamText=''; S.controller=null; S.focusInput=true; saveChats(); render();
  // Text chat never auto-speaks — use the per-message "read aloud" button instead.
  // Process the next queued message for THIS conversation, unless the user just hit Stop.
  if(S._stopQueue){ S._stopQueue=false; } else { maybeSendQueue(c.id); }
}
function sendText(t){ if(!t)return; const ta=document.querySelector('#input'); if(ta)ta.value=t; S.draft=t; send(); }
// Message queue: Shift+Enter enqueues the draft; queued messages auto-send in order once the assistant
// is free. Enqueuing while idle kicks off processing immediately (so a lone Shift+Enter still sends).
function enqueueDraft(){ const ta=document.querySelector('#input'); const t=((ta?ta.value:S.draft)||'').trim();
  if(!t && !S.pendingAtts.length)return;
  // The queue lives ON the conversation, so a queued message always runs in the chat it was written in.
  const c=cur()||(newChat(),cur()); c.queue=c.queue||[]; c.queue.push({text:t, atts:S.pendingAtts.slice()});
  S.pendingAtts=[]; S.draft=''; if(ta){ ta.value=''; ta.style.height='auto'; }
  S.focusInput=true; render(); maybeSendQueue(c.id); }
function maybeSendQueue(chatId){ if(S.streaming||S.controller)return; const c=S.chats[chatId]; if(!c||!c.queue||!c.queue.length)return; const item=c.queue.shift(); render(); send({chatId:chatId, text:item.text, atts:item.atts}); }
let _rt; function throttleRender(){ if(_rt)return; _rt=setTimeout(()=>{ _rt=null;
  // Update only the streaming bubble during generation (smooth, no whole-app rebuild/flicker).
  const sw=document.querySelector('#streamwrap');
  if(S.streaming&&sw){ patchStream(sw); const lg=document.querySelector('.log'); if(lg)lg.scrollTop=lg.scrollHeight; }
  else render();
},40); }
// Patch the streaming bubble in place. Re-creating the whole subtree each tick replayed
// the reasoning <details> fade/pulse animations, so the "Thinking…" block blinked. When
// the structure is unchanged we update just the reasoning text and answer HTML nodes; we
// only rebuild the subtree when the structure changes (reasoning/answer/typing appears).
function patchStream(sw){
  const s=splitThink(S.streamText,{streaming:true,expectReasoning:S.streamReason});
  const hasReason=!!(s.reason||s.thinking), hasAnswer=!!s.answer, hasTyping=!hasAnswer&&!s.reason;
  const rc=sw.querySelector('.reason .rc'), at=sw.querySelector('.asttext.streaming'), typing=sw.querySelector('.asttext .typing');
  const sameStruct=(!!rc===hasReason)&&(!!at===hasAnswer)&&(!!typing===hasTyping);
  if(!sameStruct){ sw.innerHTML=streamInner(); return; }
  if(rc) rc.textContent=s.reason||'';
  if(at) at.innerHTML=md(s.answer);
}

/* ---------- speech: real mic -> STT -> LLM -> TTS voice loop ---------- */
// Synthesize speech for `text` and return the audio Blob (or null). Sends the chosen TTS model/voice/
// language. Used both by the per-message read-aloud (speakMessage) and the voice loop's sentence pipeline.
async function speakBlob(text){ const clean=splitThink(text).answer||text; if(!clean.trim())return null;
  const body={input:clean.slice(0,2000)};
  const tts=S.config&&S.config.defaults&&S.config.defaults.ttsModel; if(tts)body.model=tts;
  if(S.prefs.ttsVoice)body.voice=S.prefs.ttsVoice;
  if(S.prefs.ttsLanguage)body.language=S.prefs.ttsLanguage;
  try{ const r=await fetch('/v1/audio/speech',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
    if(!r.ok)return null; return await r.blob(); }catch(e){ return null; } }
// Per-message "read aloud". One audio at a time; object URLs are revoked when
// playback ends/stops so repeated speaking never leaks memory. Cancel-safe: if the
// user stops (or starts another) while the blob is still synthesizing, the stale
// result is dropped.
function stopSpeak(){
  const a=S._speakAudio;
  if(a){ try{ a.pause(); }catch(e){} if(a._url)URL.revokeObjectURL(a._url); S._speakAudio=null; }
  S._speakId=null; S._speakLoading=false; S._speakChatId=null;
}
function fmtT(s){ if(!isFinite(s)||s<0)s=0; const m=Math.floor(s/60), ss=Math.floor(s%60); return m+':'+(ss<10?'0':'')+ss; }
function updateMiniProgress(a){ if(!a)return; const fill=document.getElementById('mpfill'), t=document.getElementById('mptime');
  const d=a.duration||0, c=a.currentTime||0; if(fill)fill.style.width=(d?Math.min(100,c/d*100):0)+'%'; if(t)t.textContent=fmtT(c); }
async function speakMessage(m){
  stopSpeak();
  const text=(splitThink(m.content).answer||m.content||'').trim(); if(!text)return;
  S._speakId=m.id; S._speakChatId=S.current; S._speakLoading=true; render();
  let b=null; try{ b=await speakBlob(text); }catch(e){}
  if(S._speakId!==m.id) return;                 // superseded or stopped mid-synthesis
  if(!b){ S._speakId=null; S._speakLoading=false; render(); return; }
  const url=URL.createObjectURL(b); const a=new Audio(url); a._url=url;
  S._speakAudio=a; S._speakLoading=false;
  const done=()=>{ if(S._speakAudio===a){ URL.revokeObjectURL(url); S._speakAudio=null; S._speakId=null; S._speakChatId=null; render(); } };
  a.onended=done; a.onerror=done;
  a.ontimeupdate=()=>updateMiniProgress(a);     // live progress bar in the mini player
  render(); a.play().catch(()=>{});
}
function blobToB64(blob){ return new Promise(res=>{ const r=new FileReader(); r.onload=()=>res((r.result+'').split(',')[1]||''); r.readAsDataURL(blob); }); }
function clearVoiceReveal(){ if(S._vsi){ clearInterval(S._vsi); S._vsi=null; } }
function stopVAD(){ if(S._vad){ cancelAnimationFrame(S._vad); S._vad=null; } if(S.voiceAC){ try{S.voiceAC.close()}catch(e){} S.voiceAC=null; } }
function endVoiceLoop(){ stopVAD(); clearVoiceReveal(); stopListening(); if(S.voiceAudio){try{S.voiceAudio.pause()}catch(e){}} S.voiceAudio=null; S.voice=null; S.voiceHeard=''; S.voiceAnswer=''; }
// Hands-free: auto-end listening after a brief pause once the user has actually spoken. Falls back to
// the tap-the-circle affordance if the Web Audio API isn't available. Runs only while listening.
function startVAD(stream){
  try{
    const AC=window.AudioContext||window.webkitAudioContext; if(!AC)return;
    const ac=new AC(); S.voiceAC=ac; const src=ac.createMediaStreamSource(stream);
    const an=ac.createAnalyser(); an.fftSize=512; src.connect(an); const buf=new Uint8Array(an.fftSize);
    let spoke=false, silenceAt=null; const t0=performance.now();
    const tick=()=>{ if(S.voice!=='listening'||S.voiceAC!==ac) return;
      an.getByteTimeDomainData(buf); let sum=0; for(let i=0;i<buf.length;i++){ const v=(buf[i]-128)/128; sum+=v*v; }
      const rms=Math.sqrt(sum/buf.length), now=performance.now();
      if(rms>0.045){ spoke=true; silenceAt=null; }
      else if(spoke){ if(silenceAt===null)silenceAt=now; else if(now-silenceAt>1400){ stopVAD(); stopListening(); return; } }
      if(now-t0>30000){ stopVAD(); stopListening(); return; }   // safety cap on a single listen
      S._vad=requestAnimationFrame(tick); };
    S._vad=requestAnimationFrame(tick);
  }catch(e){}
}
async function startVoice(){
  stopVAD(); clearVoiceReveal(); S.voice='listening'; S.voiceError=null; S.voiceHeard=''; S.voiceAnswer=''; render();
  try{
    const stream=await navigator.mediaDevices.getUserMedia({audio:true});
    S.voiceStream=stream; S.recChunks=[];
    const rec=new MediaRecorder(stream); S.recorder=rec;
    rec.ondataavailable=e=>{ if(e.data&&e.data.size)S.recChunks.push(e.data); };
    rec.onstop=()=>finishVoiceTurn();
    rec.start();
    startVAD(stream);   // auto-advance when the user pauses — no tapping needed
  }catch(e){ S.voice='error'; S.voiceError='Microphone unavailable — grant access to use voice.'; render(); }
}
function stopListening(){ try{ if(S.recorder&&S.recorder.state!=='inactive')S.recorder.stop(); }catch(e){} if(S.voiceStream){ S.voiceStream.getTracks().forEach(t=>t.stop()); S.voiceStream=null; } }
// Reveal the answer text word-by-word roughly in step with the spoken audio, then commit the turn and
// return to listening. `dur` is the audio duration in seconds when known (otherwise a reading estimate).
function revealAnswer(reply,dur,commit){
  clearVoiceReveal(); S.voiceAnswer=''; const words=reply.split(/\s+/).filter(Boolean);
  if(!words.length){ commit(); return; }
  const step=Math.max(45,Math.min(320,(dur*1000)/words.length)); let i=0;
  const paint=()=>{ const node=document.getElementById('vanswer'); if(node&&S.voice==='speaking')node.textContent=S.voiceAnswer; else if(S.voice==='speaking')render(); };
  S._vsi=setInterval(()=>{ i++; if(i>=words.length){ clearVoiceReveal(); S.voiceAnswer=reply; paint(); commit(); }
    else { S.voiceAnswer=words.slice(0,i).join(' '); paint(); } },step);
}
async function finishVoiceTurn(){
  stopVAD(); S.voice='thinking'; S.voiceAnswer=''; render();
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
  // Resolve Auto through the Scheduler.
  let model=S.modelSel;
  if(model==='Auto'){ const opt={Balanced:'balanced',Quality:'high',Speed:'fast','Low Memory':'balanced'}[S.optimize]||'balanced'; const sc=await api('/v1/schedule?goal=general&quality='+opt); if(sc&&sc.selectedModelID){ S.schedule=sc; model=sc.selectedModelID; } }
  const t0=performance.now();
  const vsys=(S.prefs.systemInstr||'').trim();
  const vmsgs=(vsys?[{role:'system',content:vsys}]:[]).concat(c.messages.filter(m=>m.role).map(m=>({role:m.role,content:m.content})));
  // Pipeline for fast time-to-first-audio: stream the reply and synthesize + play it sentence-by-
  // sentence, so speaking begins after the FIRST sentence instead of the whole answer (and each
  // sentence's TTS overlaps the previous one's playback). A turn id lets an interrupt abort cleanly.
  const turn=(S._vturnId=(S._vturnId||0)+1);
  const alive=()=>S._vturnId===turn;
  let full='', enqLen=0, shown='', genDone=false, committed=false, playing=false; const queue=[];
  const paintV=()=>{ const n=document.getElementById('vanswer'); if(n)n.textContent=S.voiceAnswer; else if(S.voice==='speaking')render(); };
  const commitOnce=()=>{ if(committed||!alive())return; committed=true;
    const answer=splitThink(full).answer||full; const secs=Math.max(0.1,(performance.now()-t0)/1000);
    const tps=Math.max(1,Math.round((answer.length/4)/secs));
    c.messages.push({id:uid(),role:'assistant',content:full,reasoning:looksReasoning(model),meta:'voice · '+secs.toFixed(1)+'s · '+tps+' tok/s'}); saveChats();
    if(S.voiceAudio){try{S.voiceAudio.pause()}catch(e){}} S.voiceAudio=null;
    if(S.voice==='speaking') startVoice(); };
  const playNext=()=>{ if(playing||!alive())return; const item=queue.shift();
    if(!item){ if(genDone)commitOnce(); return; }
    playing=true;
    item.blobP.then(blob=>{ if(!alive()){ playing=false; return; }
      if(S.voice!=='speaking'){ S.voice='speaking'; render(); }
      shown=(shown?shown+' ':'')+item.text; S.voiceAnswer=shown; paintV();
      if(blob){ const a=new Audio(URL.createObjectURL(blob)); S.voiceAudio=a;
        a.onended=()=>{ playing=false; playNext(); }; a.onerror=()=>{ playing=false; playNext(); };
        a.play().catch(()=>{ playing=false; playNext(); }); }
      else { playing=false; setTimeout(()=>{ if(alive())playNext(); }, 220); } }); };
  const enqueue=(chunk)=>{ chunk=(chunk||'').trim(); if(!chunk)return; queue.push({text:chunk, blobP:speakBlob(chunk)}); playNext(); };
  // Emit complete sentences from the answer portion (never the <think> reasoning) as they stream in.
  const pump=(force)=>{ const ans=splitThink(full).answer||''; let rest=ans.slice(enqLen), mt;
    while((mt=rest.match(/^([\s\S]*?[.!?\n]+)(\s|$)/))){ enqueue(mt[1]); enqLen+=mt[0].length; rest=ans.slice(enqLen); }
    if(force){ const tail=ans.slice(enqLen).trim(); if(tail){ enqueue(tail); enqLen=ans.length; } } };
  try{
    const resp=await fetch('/v1/chat/completions',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({model:model==='Auto'?undefined:model,messages:vmsgs,stream:true,max_tokens:512})});
    if(!resp.ok||!resp.body) throw new Error('HTTP '+resp.status);
    const rd=resp.body.getReader(), dec=new TextDecoder(); let buf='';
    while(true){ const {value,done}=await rd.read(); if(done||!alive())break; buf+=dec.decode(value,{stream:true}); const lines=buf.split('\n'); buf=lines.pop();
      for(const line of lines){ const s=line.trim(); if(!s.startsWith('data:'))continue; const d=s.slice(5).trim(); if(d==='[DONE]')continue;
        try{ const j=JSON.parse(d); if(j.esh_execution)continue; const del=j.choices&&j.choices[0]&&j.choices[0].delta&&j.choices[0].delta.content||''; if(del){ full+=del; pump(false); } }catch(e){} } }
  }catch(e){ if(!full)full='[error] '+e.message; }
  genDone=true; pump(true);
  if(!queue.length && !playing) commitOnce();
}
function fmtSize(b){ if(b<1024)return b+' B'; if(b<1048576)return (b/1024).toFixed(0)+' KB'; return (b/1048576).toFixed(1)+' MB'; }
function onFiles(e){ const files=[...e.target.files]; let pending=files.length; if(!pending)return;
  files.forEach(f=>{ const r=new FileReader(); r.onload=()=>{ const kind=f.type.startsWith('image')?'image':f.type.startsWith('audio')?'audio':'document';
    S.pendingAtts.push({kind,name:f.name,size:fmtSize(f.size),mime:f.type,dataURL:r.result}); if(--pending===0)render(); }; r.readAsDataURL(f); }); e.target.value=''; }
function micUpload(){ const inp=document.createElement('input'); inp.type='file'; inp.accept='audio/*';
  inp.onchange=async ev=>{ const f=ev.target.files[0]; if(!f)return; const r=new FileReader(); r.onload=async()=>{ try{ const resp=await fetch('/v1/audio/transcriptions',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({audio:r.result.split(',')[1],filename:f.name})}); if(resp.ok){ const d=await resp.json(); const ta=$('#input'); if(ta){ta.value+=(d.text||'');S.draft=ta.value;} } }catch(e){} }; r.readAsDataURL(f); }; inp.click(); }


/* ---------- boot ---------- */
loadChats(); loadPrefs(); loadFolders();
// On small screens the sidebar overlays the chat, so start it collapsed regardless of the saved pref.
if(window.innerWidth<=768) S.sidebarOpen=false;
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
