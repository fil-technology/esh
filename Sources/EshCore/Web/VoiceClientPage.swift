import Foundation

// esh 2.1 — Voice 2.1 server-owned browser client (spec §2/§3/§4). A self-contained page (served at GET /voice)
// that is a THIN client of the server VoiceSession: it captures the mic, converts to 16 kHz PCM16, streams it
// over the WebSocket transport, renders the typed VoiceEvents (state + transcripts), and plays the server's
// TTS audio frames in an ordered queue that flushes on barge-in. The browser owns capture + transport +
// playback + UI only; VAD/endpointing/STT/LLM/TTS/session/barge-in are all server-side.
public enum VoiceClientPage {
    public static let contentType = "text/html; charset=utf-8"

    public static func html(toolVersion: String?) -> String {
        // The WebSocket endpoint is on the serve port + 1 (see ServeCommand). Derived at runtime from location.
        """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>esh — Voice</title>
        <style>
          :root{
            --paper:#faf9f7;--panel:#ffffff;--ink:#1c1a17;--muted:#6b6760;--line:rgba(28,26,23,.10);
            --accent:#2f6d5b;--accent-soft:#e7f1ec;--you:#2f6d5b;--esh-bubble:#f1efec;
            --glow:rgba(47,109,91,.28);
          }
          @media (prefers-color-scheme:dark){:root:not([data-theme="light"]){
            --paper:#161513;--panel:#201e1b;--ink:#f2efe9;--muted:#a29c92;--line:rgba(255,255,255,.12);
            --accent:#4fb598;--accent-soft:#1e2f2a;--you:#4fb598;--esh-bubble:#2a2825;--glow:rgba(79,181,152,.30);
          }}
          *{box-sizing:border-box} html,body{margin:0;height:100%}
          body{background:radial-gradient(1200px 600px at 50% -10%,var(--accent-soft),transparent 60%),var(--paper);
            color:var(--ink);font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;
            display:flex;flex-direction:column;align-items:center;justify-content:center;gap:22px;padding:32px 20px;min-height:100%}
          .brand{position:fixed;top:18px;left:20px;font-weight:700;letter-spacing:.02em;color:var(--muted);font-size:13px}
          .stage{display:flex;flex-direction:column;align-items:center;gap:14px}
          .orb{width:112px;height:112px;border-radius:50%;display:grid;place-items:center;font-size:40px;
            background:radial-gradient(circle at 35% 30%,#fff6,transparent 55%),var(--esh-bubble);
            box-shadow:0 6px 24px rgba(0,0,0,.10),inset 0 0 0 1px var(--line);transition:transform .25s,background .3s;position:relative}
          .orb::after{content:"";position:absolute;inset:-6px;border-radius:50%;pointer-events:none;
            box-shadow:0 0 0 0 var(--glow);transition:box-shadow .3s}
          .orb.listening,.orb.speechDetected{background:radial-gradient(circle at 35% 30%,#fff8,transparent 55%),var(--accent-soft)}
          .orb.listening::after,.orb.speechDetected::after{animation:pulse 1.8s ease-out infinite}
          .orb.speechDetected{transform:scale(1.06)}
          .orb.transcribing{background:#fff3d6} .orb.thinking{background:var(--accent-soft)}
          .orb.thinking::after{animation:pulse 1.2s ease-out infinite}
          .orb.speaking{transform:scale(1.05)}
          .orb.speaking::after{animation:pulse .9s ease-out infinite}
          .orb.error{background:#f6dede} .orb.ended,.orb.idle{filter:saturate(.6)}
          @keyframes pulse{0%{box-shadow:0 0 0 0 var(--glow)}70%{box-shadow:0 0 0 22px transparent}100%{box-shadow:0 0 0 0 transparent}}
          .state{font-weight:650;text-transform:capitalize;font-size:18px;letter-spacing:.01em}
          .muted{color:var(--muted);font-size:13px;text-align:center;max-width:420px}
          .row{display:flex;gap:10px}
          button{font:inherit;font-weight:600;padding:11px 20px;border-radius:999px;border:1px solid var(--line);
            background:var(--panel);color:var(--ink);cursor:pointer;transition:transform .1s,box-shadow .2s,opacity .2s}
          button:hover:not(:disabled){transform:translateY(-1px);box-shadow:0 4px 14px rgba(0,0,0,.10)}
          button:active:not(:disabled){transform:translateY(0)}
          button.primary{background:var(--accent);color:#fff;border-color:transparent;box-shadow:0 4px 16px var(--glow)}
          button:disabled{opacity:.45;cursor:default}
          .lvl{width:min(520px,90vw);height:5px;border-radius:999px;background:var(--line);overflow:hidden}
          .lvl i{display:block;height:100%;width:0;border-radius:999px;background:linear-gradient(90deg,var(--accent),var(--you));transition:width .08s}
          .err{color:#c0392b;font-size:13px;text-align:center;max-width:520px;min-height:1em}
          @media (prefers-color-scheme:dark){:root:not([data-theme="light"]) .err{color:#ff8f7a}}
          .log{width:min(560px,92vw);max-height:44vh;overflow:auto;display:flex;flex-direction:column;gap:12px;padding:4px}
          .log:empty{display:none}
          .turn{display:flex;flex-direction:column;gap:3px;max-width:82%}
          .turn .who{font-size:10.5px;color:var(--muted);text-transform:uppercase;letter-spacing:.06em;font-weight:700;padding:0 4px}
          .turn div:last-child{padding:10px 14px;border-radius:16px;background:var(--esh-bubble);white-space:pre-wrap;word-break:break-word}
          .turn.you{align-self:flex-end;align-items:flex-end}
          .turn.you div:last-child{background:var(--accent);color:#fff;border-bottom-right-radius:5px}
          .turn.esh{align-self:flex-start} .turn.esh div:last-child{border-bottom-left-radius:5px}
        </style></head>
        <body>
          <div class="brand">esh · voice</div>
          <div class="stage">
            <div class="orb idle" id="orb">🎙️</div>
            <div class="state" id="state">Ready</div>
            <div class="lvl"><i id="lvl"></i></div>
          </div>
          <div class="row">
            <button class="primary" id="start">Start voice</button>
            <button id="stop" disabled>End</button>
          </div>
          <div class="muted" id="hint">Headphones recommended. esh runs VAD, STT, the model, and TTS on-device.</div>
          <div class="err" id="err"></div>
          <div class="log" id="log"></div>
        <script>
        (function(){
          const $=id=>document.getElementById(id);
          const orb=$('orb'), stateEl=$('state'), logEl=$('log'), errEl=$('err'), lvl=$('lvl');
          let ws=null, audioCtx=null, micStream=null, proc=null, playing=false, playQueue=[], curSource=null, curTurn=0;
          const SR=16000;

          function setState(s){ orb.className='orb '+s; stateEl.textContent=s; }
          function addTurn(who,text){ const d=document.createElement('div'); d.className='turn '+who; const w=document.createElement('div'); w.className='who'; w.textContent=who; const b=document.createElement('div'); b.textContent=(text||''); d.appendChild(w); d.appendChild(b); logEl.appendChild(d); logEl.scrollTop=logEl.scrollHeight; return d; }
          let userDiv=null, asstDiv=null;

          function wsURL(){ const p=(parseInt(location.port||'80',10)+1); return (location.protocol==='https:'?'wss://':'ws://')+location.hostname+':'+p+'/v1/voice/stream'; }

          async function start(){
            errEl.textContent='';
            try { micStream = await navigator.mediaDevices.getUserMedia({audio:{channelCount:1,echoCancellation:true,noiseSuppression:true}}); }
            catch(e){ errEl.textContent='Microphone permission is required for voice.'; return; }
            $('start').disabled=true; $('stop').disabled=false;
            ws = new WebSocket(wsURL());
            ws.binaryType='arraybuffer';
            ws.onopen=()=>{ ws.send(JSON.stringify({t:'start',sampleRate:SR})); startCapture(); setState('listening'); };
            ws.onclose=()=>{ setState('ended'); teardown(); };
            ws.onerror=()=>{ errEl.textContent='Could not reach the voice endpoint. Is `esh serve` running?'; };
            ws.onmessage=onMessage;
          }

          function startCapture(){
            audioCtx = new (window.AudioContext||window.webkitAudioContext)();
            const src=audioCtx.createMediaStreamSource(micStream);
            proc=audioCtx.createScriptProcessor(2048,1,1);
            const inRate=audioCtx.sampleRate;
            src.connect(proc); proc.connect(audioCtx.destination);
            proc.onaudioprocess=(e)=>{
              if(!ws||ws.readyState!==1) return;
              const input=e.inputBuffer.getChannelData(0);
              // meter
              let sum=0; for(let i=0;i<input.length;i++) sum+=input[i]*input[i];
              lvl.style.width=Math.min(100,Math.sqrt(sum/input.length)*400)+'%';
              // downsample inRate -> 16k, float -> PCM16 LE
              const ratio=inRate/SR; const outLen=Math.floor(input.length/ratio);
              const buf=new ArrayBuffer(outLen*2); const view=new DataView(buf);
              for(let i=0;i<outLen;i++){ let s=input[Math.floor(i*ratio)]; s=Math.max(-1,Math.min(1,s)); view.setInt16(i*2, s<0?s*0x8000:s*0x7FFF, true); }
              ws.send(buf);
            };
          }

          function onMessage(ev){
            if(typeof ev.data!=='string'){ return onAudio(ev.data); }
            let m; try{ m=JSON.parse(ev.data); }catch(_){ return; }
            switch(m.t){
              case 'session.state': setState(m.state||'listening'); break;
              case 'vad.speech_started': userDiv=addTurn('you','…'); break;
              case 'transcript.final': if(userDiv) userDiv.lastChild.textContent=m.text; else addTurn('you',m.text); break;
              case 'assistant.thinking_started': asstDiv=addTurn('esh','…'); break;
              case 'assistant.text_delta': if(asstDiv){ if(asstDiv.lastChild.textContent==='…')asstDiv.lastChild.textContent=''; asstDiv.lastChild.textContent+=m.text; } break;
              case 'assistant.text_final': if(asstDiv) asstDiv.lastChild.textContent=m.text; break;
              case 'interruption.detected': setState('interrupted'); break;
              case 'playback.cancelled': flushPlayback(); break;   // barge-in: stop stale audio immediately
              case 'install.required': setState('idle'); errEl.textContent=(m.message||'A voice model needs to be installed.')+(m.text?(' ('+m.text+')'):''); teardown(); break;
              case 'session.error': errEl.textContent=m.message||'error'; break;
            }
          }

          // Binary TTS frame: [magic 'eV'(2)][ver(1)][turn(4)][seq(4)][sampleRate(4)][channels(1)][flags(1)][WAV payload]
          function onAudio(buf){
            const b=new Uint8Array(buf); if(b.length<17||b[0]!==0x65||b[1]!==0x56) return;
            const dv=new DataView(buf); const turn=dv.getUint32(3); const wav=buf.slice(17);
            if(turn<curTurn) return;                 // drop stale audio from a cancelled turn
            curTurn=turn;
            playQueue.push(wav); if(!playing) playNext();
          }
          function playNext(){
            if(!playQueue.length){ playing=false; return; }
            playing=true;
            const wav=playQueue.shift();
            const blob=new Blob([wav],{type:'audio/wav'}); const url=URL.createObjectURL(blob);
            const a=new Audio(url); curSource=a;
            a.onended=()=>{ URL.revokeObjectURL(url); curSource=null; playNext(); };
            a.onerror=()=>{ URL.revokeObjectURL(url); curSource=null; playNext(); };
            a.play().catch(()=>{ playNext(); });
          }
          function flushPlayback(){ playQueue=[]; if(curSource){ try{curSource.pause();}catch(_){}} curSource=null; playing=false; curTurn++; }

          function stop(){ if(ws&&ws.readyState===1){ try{ws.send(JSON.stringify({t:'end'}));}catch(_){}} if(ws) ws.close(); teardown(); }
          function teardown(){ try{proc&&proc.disconnect();}catch(_){}; try{audioCtx&&audioCtx.close();}catch(_){}; try{micStream&&micStream.getTracks().forEach(t=>t.stop());}catch(_){}; flushPlayback(); $('start').disabled=false; $('stop').disabled=true; lvl.style.width='0'; }

          $('start').onclick=start; $('stop').onclick=stop;
          window.addEventListener('beforeunload',stop);
        })();
        </script></body></html>
        """
    }
}
