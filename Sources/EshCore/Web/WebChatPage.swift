import Foundation

/// The self-contained Web Chat page (M8.5) served at `GET /web` by the local esh server. A ChatGPT-
/// style reference client over the canonical esh APIs — not another inference engine. Single file, no
/// external assets, same-origin fetch (no CORS). Multi-conversation history (localStorage), model +
/// generation settings, collapsible reasoning, markdown + image/audio rendering, per-message
/// text-to-speech, and attachments (sent when the model supports them, honestly rejected otherwise).
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
<style>
  :root { color-scheme: light dark; --bg:#0f1115; --panel:#161a22; --panel2:#1c222c; --ink:#e6eaf2; --faint:#8b93a7; --accent:#5db0ff; --line:#242a36; --user:#1e2938; }
  @media (prefers-color-scheme: light) { :root { --bg:#f7f8fa; --panel:#fff; --panel2:#eef1f5; --ink:#1a1f2b; --faint:#5a6478; --accent:#0a84ff; --line:#e2e6ee; --user:#e8f0fe; } }
  * { box-sizing:border-box; }
  html,body { margin:0; height:100%; }
  body { font:14px/1.55 -apple-system,system-ui,sans-serif; background:var(--bg); color:var(--ink); display:flex; }
  button,select,input,textarea { font:inherit; color:var(--ink); background:var(--panel2); border:1px solid var(--line); border-radius:8px; padding:7px 10px; }
  button { cursor:pointer; } button:hover { border-color:var(--accent); } button:disabled { opacity:.45; cursor:default; }
  button.primary { background:var(--accent); color:#04121f; border:none; font-weight:600; }
  a { color:var(--accent); }
  /* Sidebar */
  #side { width:250px; min-width:250px; background:var(--panel); border-right:1px solid var(--line); display:flex; flex-direction:column; height:100vh; }
  #side .top { padding:12px; border-bottom:1px solid var(--line); }
  #newChat { width:100%; }
  #chats { flex:1; overflow:auto; padding:8px; }
  .chatItem { padding:8px 10px; border-radius:8px; cursor:pointer; color:var(--faint); white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
  .chatItem:hover { background:var(--panel2); }
  .chatItem.active { background:var(--panel2); color:var(--ink); }
  #side .foot { padding:10px 12px; border-top:1px solid var(--line); color:var(--faint); font-size:12px; }
  /* Main */
  #main { flex:1; display:flex; flex-direction:column; height:100vh; min-width:0; }
  header { display:flex; align-items:center; gap:10px; padding:10px 16px; border-bottom:1px solid var(--line); background:var(--panel); flex-wrap:wrap; }
  header b { color:var(--accent); }
  header .sp { flex:1; }
  #log { flex:1; overflow:auto; padding:20px; }
  .msg { max-width:820px; margin:0 auto 18px; }
  .msg .who { color:var(--faint); font-size:12px; margin-bottom:3px; display:flex; align-items:center; gap:8px; }
  .msg.user .bubble { background:var(--user); }
  .bubble { padding:10px 14px; border-radius:12px; white-space:pre-wrap; overflow-wrap:anywhere; }
  .bubble img { max-width:100%; border-radius:10px; margin:6px 0; display:block; }
  .bubble audio { width:100%; margin:6px 0; }
  .bubble pre { background:var(--panel); padding:10px; border-radius:8px; overflow-x:auto; }
  .bubble code { background:var(--panel); padding:1px 4px; border-radius:4px; }
  details.reason { margin:2px 0 8px; }
  details.reason summary { color:var(--faint); cursor:pointer; font-size:13px; }
  details.reason .rc { color:var(--faint); white-space:pre-wrap; border-left:2px solid var(--line); padding-left:10px; margin-top:6px; }
  .tools { margin-left:auto; display:flex; gap:6px; }
  .tools button { padding:2px 8px; font-size:12px; }
  /* Composer */
  .bar { border-top:1px solid var(--line); background:var(--panel); padding:12px 16px; }
  .row { display:flex; gap:8px; align-items:flex-end; max-width:900px; margin:0 auto; }
  textarea#input { flex:1; resize:none; min-height:46px; max-height:200px; }
  #atts { max-width:900px; margin:0 auto 6px; display:flex; gap:8px; flex-wrap:wrap; }
  .att { font-size:12px; color:var(--faint); background:var(--panel2); border:1px solid var(--line); border-radius:8px; padding:4px 8px; }
  #meta { max-width:900px; margin:6px auto 0; color:var(--faint); font-size:12px; }
  /* Settings drawer */
  #settings { display:none; padding:12px 16px; border-bottom:1px solid var(--line); background:var(--panel2); }
  #settings.open { display:block; }
  #settings .grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(220px,1fr)); gap:10px; max-width:900px; margin:0 auto; }
  #settings label { display:flex; flex-direction:column; gap:4px; font-size:12px; color:var(--faint); }
  #settings textarea { min-height:44px; resize:vertical; }
  .err { color:#ff8080; }
  @media (max-width:720px){ #side{position:fixed;z-index:5;transform:translateX(-100%);transition:.2s} #side.show{transform:none} }
</style>
</head>
<body>
<aside id="side">
  <div class="top"><button id="newChat" class="primary">+ New chat</button></div>
  <div id="chats"></div>
  <div class="foot">esh __VERSION__ · local reference client</div>
</aside>
<div id="main">
  <header>
    <b>esh</b>
    <select id="model" title="Model"></select>
    <button id="gear" title="Settings">⚙ Settings</button>
    <span class="sp"></span>
    <span id="status" style="color:var(--faint)">ready</span>
  </header>
  <div id="settings">
    <div class="grid">
      <label>System prompt<textarea id="sys" placeholder="(optional) You are a helpful assistant."></textarea></label>
      <label>Temperature <input id="temp" type="number" step="0.1" min="0" max="2" value="0.7"></label>
      <label>Max tokens <input id="maxtok" type="number" min="1" value="512"></label>
      <label>Reasoning <select id="reason"><option value="auto">auto</option><option value="on">enabled</option><option value="off">disabled</option></select></label>
      <label>Cache / compression <select id="cache"><option value="">default</option><option value="raw">raw</option><option value="turbo">turbo</option><option value="triattention">triattention</option><option value="auto">auto</option></select></label>
      <label>Speak replies (TTS) <select id="autotts"><option value="off">off</option><option value="on">on</option></select></label>
    </div>
  </div>
  <div id="log"></div>
  <div id="meta"></div>
  <div class="bar">
    <div id="atts"></div>
    <div class="row">
      <input id="file" type="file" accept="image/*,audio/*" multiple style="display:none">
      <button id="attach" title="Attach image/audio">📎</button>
      <button id="micBtn" title="Transcribe an audio file to text (STT)">🎙</button>
      <textarea id="input" placeholder="Ask anything…  (Enter to send, Shift+Enter for newline)"></textarea>
      <button id="send" class="primary">Send</button>
      <button id="stop" disabled>Stop</button>
    </div>
  </div>
</div>
<script>
const $=s=>document.querySelector(s), LS="esh.chats.v1";
let chats={}, current=null, controller=null, pendingAtts=[], models=[], ttsModels=[];

function load(){ try{chats=JSON.parse(localStorage.getItem(LS)||"{}")}catch(e){chats={}} }
function save(){ try{localStorage.setItem(LS,JSON.stringify(chats))}catch(e){} }
function uid(){ return Date.now().toString(36)+Math.random().toString(36).slice(2,6); }

function newChat(){ const id=uid(); chats[id]={id,title:"New chat",messages:[],created:Date.now()}; current=id; save(); renderChats(); renderLog(); $('#input').focus(); }
function switchChat(id){ current=id; renderChats(); renderLog(); }
function renderChats(){
  const el=$('#chats'); el.innerHTML="";
  Object.values(chats).sort((a,b)=>b.created-a.created).forEach(c=>{
    const d=document.createElement('div'); d.className='chatItem'+(c.id===current?' active':''); d.textContent=c.title||"New chat";
    d.onclick=()=>switchChat(c.id); el.appendChild(d);
  });
}
function esc(s){ return s.replace(/[&<>]/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[m])); }
function mdInline(s){ return esc(s).replace(/`([^`]+)`/g,'<code>$1</code>').replace(/\*\*([^*]+)\*\*/g,'<b>$1</b>'); }
function renderMarkdown(t){
  // fenced code blocks, then inline.
  const parts=t.split(/```/); let out="";
  parts.forEach((p,i)=>{ if(i%2){ const nl=p.indexOf('\n'); out+='<pre><code>'+esc(nl>=0?p.slice(nl+1):p)+'</code></pre>'; } else out+=mdInline(p).replace(/\n/g,'<br>'); });
  return out;
}
function splitThink(t, opts){
  opts=opts||{};
  const close=t.indexOf('</think>');
  if(close>=0){ let start=t.indexOf('<think>'); start=start<0?0:start+7;
    return {reason:t.slice(start,close).trim(), answer:t.slice(close+8).trim(), thinking:false}; }
  // Explicit open tag: everything after it is live reasoning until </think> arrives.
  if(t.startsWith('<think>')) return {reason:t.slice(7), answer:'', thinking:true};
  // Implicit-open reasoning models (e.g. DeepSeek-R1) emit thinking with only a trailing </think>.
  // While streaming and reasoning is expected, show the live tokens AS reasoning instead of leaking
  // them into the answer bubble (they move to the collapsed section once </think> lands).
  if(opts.streaming && opts.expectReasoning && t) return {reason:t, answer:'', thinking:true};
  return {reason:'', answer:t, thinking:false};
}
function looksLikeReasoningModel(id){ return /deepseek-?r1|(^|[^a-z])r1([^a-z]|$)|qwq|magistral|thinking|reason/i.test(id||''); }
function renderLog(){
  const log=$('#log'); log.innerHTML="";
  const c=chats[current]; if(!c) return;
  c.messages.forEach(m=>{
    const wrap=document.createElement('div'); wrap.className='msg '+m.role;
    const who=document.createElement('div'); who.className='who'; who.textContent=m.role==='user'?'you':'esh';
    if(m.role==='assistant'){ const t=document.createElement('div'); t.className='tools';
      const b=document.createElement('button'); b.textContent='🔊'; b.title='Speak (TTS)'; b.onclick=()=>speak(m.content); t.appendChild(b); who.appendChild(t); }
    wrap.appendChild(who);
    const bub=document.createElement('div'); bub.className='bubble';
    if(m.role==='assistant'){ const s=splitThink(m.content, {streaming:m.streaming, expectReasoning:m.reasoning});
      if(s.reason||s.thinking){ const dt=document.createElement('details'); dt.className='reason';
        dt.open = !!s.thinking;   // expanded while thinking live, collapsed once the answer begins
        const label = s.thinking ? 'Reasoning (thinking…)' : 'Reasoning';
        dt.innerHTML='<summary>'+label+'</summary><div class="rc">'+esc(s.reason)+'</div>'; wrap.appendChild(dt); }
      const answer = s.answer || (s.thinking ? '' : m.content);
      if(answer){ bub.innerHTML=renderMarkdown(answer); } else { bub.style.display='none'; }
    } else {
      bub.innerHTML=renderMarkdown(m.content||'');
      (m.attachments||[]).forEach(a=>{ if(a.kind==='image'){const i=new Image();i.src=a.dataURL;bub.appendChild(i);} else if(a.kind==='audio'){const au=document.createElement('audio');au.controls=true;au.src=a.dataURL;bub.appendChild(au);} });
    }
    wrap.appendChild(bub); log.appendChild(wrap);
  });
  log.scrollTop=log.scrollHeight;
}

async function loadModels(){
  try{ const d=await (await fetch('/v1/models')).json(); models=(d.data||[]).map(m=>m.id);
    $('#model').innerHTML=models.map(id=>'<option>'+id+'</option>').join('')||'<option>(no models)</option>'; }catch(e){ $('#model').innerHTML='<option>(server unreachable)</option>'; }
  try{ const a=await (await fetch('/v1/audio/models')).json(); ttsModels=(a.data||a||[]).map(m=>m.id||m); }catch(e){ ttsModels=[]; }
}

async function speak(text){
  const clean=splitThink(text).answer||text;
  if(!clean.trim()) return;
  $('#status').textContent='synthesizing…';
  try{
    const r=await fetch('/v1/audio/speech',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({input:clean.slice(0,2000)})});
    if(!r.ok){ $('#status').textContent='TTS unavailable — install a speech model: esh model install / esh config set-speech'; return; }
    const blob=await r.blob(); const a=new Audio(URL.createObjectURL(blob)); a.play(); $('#status').textContent='ready';
  }catch(e){ $('#status').textContent='TTS error: '+e.message; }
}

$('#attach').onclick=()=>$('#file').click();
$('#file').onchange=e=>{ for(const f of e.target.files){ const r=new FileReader(); r.onload=()=>{ const kind=f.type.startsWith('image')?'image':f.type.startsWith('audio')?'audio':'other'; pendingAtts.push({kind,name:f.name,dataURL:r.result}); renderAtts(); }; r.readAsDataURL(f);} e.target.value=''; };
function renderAtts(){ $('#atts').innerHTML=pendingAtts.map((a,i)=>'<span class="att">'+a.kind+': '+esc(a.name)+' <a href="#" onclick="removeAtt('+i+');return false">✕</a></span>').join(''); }
window.removeAtt=i=>{ pendingAtts.splice(i,1); renderAtts(); };

$('#micBtn').onclick=async()=>{
  const inp=document.createElement('input'); inp.type='file'; inp.accept='audio/*';
  inp.onchange=async e=>{ const f=e.target.files[0]; if(!f) return; $('#status').textContent='transcribing…';
    const r=new FileReader(); r.onload=async()=>{ try{
      const resp=await fetch('/v1/audio/transcriptions',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({audio:r.result.split(',')[1],filename:f.name})});
      if(!resp.ok){ $('#status').textContent='STT unavailable — install a speech model'; return; }
      const d=await resp.json(); $('#input').value+=(d.text||''); $('#status').textContent='ready';
    }catch(err){ $('#status').textContent='STT error: '+err.message; } };
    r.readAsDataURL(f); };
  inp.click();
};

async function send(){
  const text=$('#input').value.trim(); if((!text&&!pendingAtts.length)||controller) return;
  if(!current) newChat();
  const c=chats[current];
  const atts=pendingAtts.slice(); pendingAtts=[]; renderAtts();
  c.messages.push({role:'user',content:text,attachments:atts});
  if(c.title==='New chat'&&text) c.title=text.slice(0,40);
  $('#input').value=''; renderChats(); renderLog(); save();

  const model=$('#model').value; const rz=$('#reason').value;
  // Expect a live reasoning stream when thinking is on, or (in auto) when the model is a reasoning model.
  const expectReasoning = rz==='on' || (rz!=='off' && looksLikeReasoningModel(model));
  const out={role:'assistant',content:'',streaming:true,reasoning:expectReasoning}; c.messages.push(out);
  const bubbleRefresh=()=>renderLog();
  $('#status').textContent='generating…'; $('#meta').textContent=''; $('#send').disabled=true; $('#stop').disabled=false;
  controller=new AbortController(); const t0=performance.now();
  const msgs=[]; const sys=$('#sys').value.trim(); if(sys) msgs.push({role:'system',content:sys});
  c.messages.slice(0,-1).forEach(m=>msgs.push({role:m.role,content:m.content}));
  const body={ model:model, messages:msgs, stream:true,
    max_tokens:parseInt($('#maxtok').value)||512, temperature:parseFloat($('#temp').value) };
  if(rz==='on') body.enable_thinking=true; if(rz==='off') body.enable_thinking=false;
  const cache=$('#cache').value; if(cache) body.cache_mode=cache;
  try{
    const resp=await fetch('/v1/chat/completions',{method:'POST',headers:{'Content-Type':'application/json'},signal:controller.signal,body:JSON.stringify(body)});
    if(!resp.ok||!resp.body){ out.content='error: HTTP '+resp.status; }
    else{ const rd=resp.body.getReader(), dec=new TextDecoder(); let buf='';
      while(true){ const {value,done}=await rd.read(); if(done) break;
        buf+=dec.decode(value,{stream:true}); const lines=buf.split('\n'); buf=lines.pop();
        for(const line of lines){ const s=line.trim(); if(!s.startsWith('data:'))continue; const d=s.slice(5).trim(); if(d==='[DONE]')continue;
          try{ const j=JSON.parse(d); const delta=j.choices?.[0]?.delta?.content||''; if(delta){ out.content+=delta; bubbleRefresh(); } }catch(e){} } }
    }
    const secs=((performance.now()-t0)/1000).toFixed(1); $('#meta').textContent=secs+'s · '+out.content.length+' chars';
    if($('#autotts').value==='on') speak(out.content);
  }catch(e){ if(e.name!=='AbortError'){ out.content+='\n[error] '+e.message; } }
  out.streaming=false;
  $('#status').textContent='ready'; $('#send').disabled=false; $('#stop').disabled=true; controller=null; save(); renderLog();
}

$('#send').onclick=send;
$('#stop').onclick=()=>{ if(controller) controller.abort(); };
$('#newChat').onclick=newChat;
$('#gear').onclick=()=>$('#settings').classList.toggle('open');
$('#input').addEventListener('keydown',e=>{ if(e.key==='Enter'&&!e.shiftKey){ e.preventDefault(); send(); }});

load(); loadModels();
if(!Object.keys(chats).length) newChat(); else { current=Object.values(chats).sort((a,b)=>b.created-a.created)[0].id; renderChats(); renderLog(); }
</script>
</body>
</html>
"""#
}
