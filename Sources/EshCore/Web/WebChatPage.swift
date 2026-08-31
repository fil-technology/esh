import Foundation

/// The self-contained Web Chat page (M8.5) served at `GET /web` by the local esh server. It is a
/// *reference client* over the canonical esh APIs (`/v1/models`, streaming `/v1/chat/completions`) —
/// not another inference engine. Single file, no external assets, same-origin fetch (no CORS).
public enum WebChatPage {
    public static let contentType = "text/html; charset=utf-8"

    public static func html(toolVersion: String?) -> String {
        let version = toolVersion.map { "v\($0)" } ?? ""
        return #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>esh — Local Chat</title>
<style>
  :root { color-scheme: light dark; --bg:#0f1115; --panel:#161a22; --ink:#e6eaf2; --faint:#8b93a7; --accent:#5db0ff; --line:#242a36; }
  * { box-sizing:border-box; }
  body { margin:0; font:14px/1.5 -apple-system,system-ui,sans-serif; background:var(--bg); color:var(--ink); height:100vh; display:flex; flex-direction:column; }
  header { display:flex; align-items:center; gap:12px; padding:10px 16px; border-bottom:1px solid var(--line); background:var(--panel); }
  header b { color:var(--accent); }
  header .sp { flex:1; }
  select, button, input, textarea { font:inherit; color:var(--ink); background:#0e131b; border:1px solid var(--line); border-radius:8px; padding:8px 10px; }
  button { cursor:pointer; }
  button.primary { background:var(--accent); color:#04121f; border:none; font-weight:600; }
  button:disabled { opacity:.5; cursor:default; }
  #log { flex:1; overflow:auto; padding:18px; display:flex; flex-direction:column; gap:14px; }
  .msg { max-width:820px; white-space:pre-wrap; }
  .msg .who { color:var(--faint); font-size:12px; margin-bottom:2px; }
  .msg.user .who { color:var(--accent); }
  .bar { padding:12px 16px; border-top:1px solid var(--line); background:var(--panel); }
  .row { display:flex; gap:10px; align-items:flex-end; max-width:980px; margin:0 auto; }
  textarea { flex:1; resize:none; min-height:44px; max-height:180px; }
  #meta { color:var(--faint); font-size:12px; padding:0 16px 10px; text-align:center; }
  .err { color:#ff8080; }
</style>
</head>
<body>
<header>
  <b>esh</b> <span style="color:var(--faint)">Local Chat</span>
  <select id="model" title="Model"></select>
  <span class="sp"></span>
  <span id="status" style="color:var(--faint)">ready</span>
</header>
<div id="log"></div>
<div id="meta"></div>
<div class="bar"><div class="row">
  <textarea id="input" placeholder="Ask anything…  (Enter to send, Shift+Enter for newline)"></textarea>
  <button id="send" class="primary">Send</button>
  <button id="stop" disabled>Stop</button>
</div></div>
<script>
const $ = s => document.querySelector(s);
const log = $('#log'), input = $('#input'), sendBtn = $('#send'), stopBtn = $('#stop'), modelSel = $('#model'), statusEl = $('#status'), metaEl = $('#meta');
let history = [], controller = null;

function add(role, text) {
  const el = document.createElement('div');
  el.className = 'msg ' + role;
  el.innerHTML = '<div class="who">' + (role === 'user' ? 'you' : 'esh') + '</div>';
  const body = document.createElement('span'); body.textContent = text; el.appendChild(body);
  log.appendChild(el); log.scrollTop = log.scrollHeight;
  return body;
}

async function loadModels() {
  try {
    const r = await fetch('/v1/models'); const d = await r.json();
    const ids = (d.data || []).map(m => m.id);
    modelSel.innerHTML = ids.map(id => '<option>' + id + '</option>').join('') || '<option>(no models installed)</option>';
    if (ids.some(x => x.includes('apple'))) {} // apple appears if available
  } catch (e) { modelSel.innerHTML = '<option>(server unreachable)</option>'; }
}

async function send() {
  const text = input.value.trim(); if (!text || controller) return;
  input.value = ''; add('user', text); history.push({role:'user', content:text});
  const out = add('assistant', ''); statusEl.textContent = 'generating…'; metaEl.textContent = '';
  sendBtn.disabled = true; stopBtn.disabled = false; controller = new AbortController();
  const t0 = performance.now();
  try {
    const resp = await fetch('/v1/chat/completions', {
      method:'POST', headers:{'Content-Type':'application/json'}, signal: controller.signal,
      body: JSON.stringify({ model: modelSel.value, messages: history, stream: true })
    });
    if (!resp.ok || !resp.body) { out.textContent = 'error: HTTP ' + resp.status; out.parentElement.classList.add('err'); }
    else {
      const reader = resp.body.getReader(); const dec = new TextDecoder(); let buf = '', acc = '';
      while (true) {
        const {value, done} = await reader.read(); if (done) break;
        buf += dec.decode(value, {stream:true}); const lines = buf.split('\n'); buf = lines.pop();
        for (const line of lines) {
          const s = line.trim(); if (!s.startsWith('data:')) continue;
          const data = s.slice(5).trim(); if (data === '[DONE]') continue;
          try { const j = JSON.parse(data); const delta = j.choices?.[0]?.delta?.content || j.choices?.[0]?.message?.content || ''; if (delta) { acc += delta; out.textContent = acc; log.scrollTop = log.scrollHeight; } } catch (e) {}
        }
      }
      history.push({role:'assistant', content: acc});
      const secs = ((performance.now()-t0)/1000).toFixed(1);
      metaEl.textContent = secs + 's · ' + acc.length + ' chars';
    }
  } catch (e) { if (e.name !== 'AbortError') { out.textContent = (out.textContent||'') + '\n[error] ' + e.message; out.parentElement.classList.add('err'); } }
  statusEl.textContent = 'ready'; sendBtn.disabled = false; stopBtn.disabled = true; controller = null;
}

sendBtn.onclick = send;
stopBtn.onclick = () => { if (controller) controller.abort(); };
input.addEventListener('keydown', e => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send(); } });
loadModels();
</script>
<!-- esh __VERSION__ web chat · reference client over the local esh API -->
</body>
</html>
"""#.replacingOccurrences(of: "__VERSION__", with: version)
    }
}
