import Foundation

// esh 2.1 — Voice 2.1 server-owned browser client (spec §2/§3/§4). A self-contained page (served at GET /voice)
// that is a THIN client of the server VoiceSession: it captures the mic, converts to 16 kHz PCM16, streams it
// over the WebSocket transport, renders the typed VoiceEvents (per-side live state + transcripts), and plays
// the server's TTS audio frames in an ordered queue that flushes on barge-in. VAD/STT/LLM/TTS/session/barge-in
// are all server-side. A model + voice picker lets the user pin the LLM/TTS per session.
public enum VoiceClientPage {
    public static let contentType = "text/html; charset=utf-8"

    public static func html(toolVersion: String?) -> String {
        // The WebSocket endpoint is on the serve port + 1 (see ServeCommand). Derived at runtime from location.
        """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>esh — Voice</title>
        <link rel="preconnect" href="https://fonts.googleapis.com">
        <link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500&display=swap" rel="stylesheet">
        <style>
          :root{
            --paper:#fbfaf8;--ink:#201e1b;--ink-2:rgba(32,30,27,.6);--ink-3:rgba(32,30,27,.42);
            --line:rgba(32,30,27,.12);--bubble:rgba(32,30,27,.06);--accent:#2f6d5b;
            --mono:'IBM Plex Mono',ui-monospace,SFMono-Regular,Menlo,monospace;
          }
          @media (prefers-color-scheme:dark){:root:not([data-theme="light"]){
            --paper:#161513;--ink:#f2efe9;--ink-2:rgba(242,239,233,.62);--ink-3:rgba(242,239,233,.44);
            --line:rgba(255,255,255,.14);--bubble:rgba(255,255,255,.08);--accent:#4fb598;
          }}
          *{box-sizing:border-box} html,body{margin:0;height:100%}
          body{background:var(--paper);color:var(--ink);overflow:hidden;
            font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif}
          @keyframes eshpulse{0%,100%{transform:scale(1);opacity:.9}50%{transform:scale(1.12);opacity:1}}
          @keyframes eshbar{0%,100%{transform:scaleY(.35)}50%{transform:scaleY(1)}}
          @keyframes eshdot{0%,100%{opacity:.2}50%{opacity:1}}
          @keyframes eshblink{0%,49%{opacity:1}50%,100%{opacity:0}}
          .wrap{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:18px;padding:64px 40px 0}
          .pickers{position:fixed;top:14px;right:16px;display:flex;gap:8px;z-index:5}
          .pickers select{font:500 11px var(--mono);letter-spacing:.02em;color:var(--ink-2);background:var(--paper);
            border:1px solid var(--line);border-radius:999px;padding:6px 26px 6px 12px;cursor:pointer;
            -webkit-appearance:none;appearance:none;
            background-image:linear-gradient(45deg,transparent 50%,var(--ink-3) 50%),linear-gradient(135deg,var(--ink-3) 50%,transparent 50%);
            background-position:calc(100% - 14px) 12px,calc(100% - 9px) 12px;background-size:5px 5px,5px 5px;background-repeat:no-repeat}
          .pickers select:hover{color:var(--ink);border-color:var(--ink-3)}
          .brand{position:fixed;top:16px;left:20px;font:500 12px var(--mono);letter-spacing:.06em;color:var(--ink-3)}
          .orb{height:96px;flex-shrink:0;display:flex;align-items:center;justify-content:center;cursor:pointer;user-select:none;-webkit-user-select:none}
          .dot-wrap{width:84px;height:84px;border-radius:50%;background:var(--bubble);display:flex;align-items:center;justify-content:center}
          .dot-wrap.anim{animation:eshpulse 1.6s ease-in-out infinite}
          .dot{width:36px;height:36px;border-radius:50%;background:var(--ink)}
          .dots{display:flex;gap:8px}
          .dots i{width:9px;height:9px;border-radius:50%;background:var(--ink);animation:eshdot 1.1s ease-in-out infinite}
          .dots i:nth-child(2){animation-delay:.18s} .dots i:nth-child(3){animation-delay:.36s}
          .bars{display:flex;align-items:center;gap:4px;height:40px}
          .bars i{width:4px;border-radius:2px;background:var(--ink);animation:eshbar .9s ease-in-out infinite}
          .bars i:nth-child(1){height:14px;animation-delay:0s} .bars i:nth-child(2){height:30px;animation-delay:.12s}
          .bars i:nth-child(3){height:20px;animation-delay:.24s} .bars i:nth-child(4){height:36px;animation-delay:.36s}
          .bars i:nth-child(5){height:16px;animation-delay:.48s} .bars i:nth-child(6){height:26px;animation-delay:.6s}
          .bars i:nth-child(7){height:12px;animation-delay:.72s}
          .state{font:500 10px var(--mono);letter-spacing:.14em;text-transform:uppercase;color:var(--ink-3)}
          .log{width:100%;max-width:600px;flex:0 1 auto;min-height:0;overflow-y:auto;scrollbar-width:none;
            display:flex;flex-direction:column;gap:16px;padding:14px 20px 8px;
            -webkit-mask-image:linear-gradient(to bottom,transparent,#000 22px,#000 calc(100% - 10px),transparent);
            mask-image:linear-gradient(to bottom,transparent,#000 22px,#000 calc(100% - 10px),transparent)}
          .log::-webkit-scrollbar{display:none} .log:empty{display:none}
          .turn{display:flex;flex-direction:column;gap:4px}
          .turn.you{align-items:flex-end} .turn.esh{align-items:flex-start}
          .who{font:500 9.5px var(--mono);letter-spacing:.1em;text-transform:uppercase;color:var(--ink-3);display:flex;gap:7px;align-items:center}
          .who .st{color:var(--accent)}
          .who .live-dot{width:5px;height:5px;border-radius:50%;background:var(--accent);animation:eshdot 1s ease-in-out infinite}
          .bubble{max-width:86%;line-height:1.55;white-space:pre-wrap;word-break:break-word;letter-spacing:-.005em;min-height:1em}
          .turn.you .bubble{font-size:14px;padding:10px 14px;border-radius:14px;background:var(--bubble);text-align:right}
          .turn.you .bubble.empty{padding:8px 14px}
          .turn.esh .bubble{font-size:16px}
          .bubble.live::after{content:"";display:inline-block;width:7px;height:14px;background:var(--ink);vertical-align:-2px;margin-left:3px;animation:eshblink 1s infinite}
          .mini{display:inline-flex;align-items:center;gap:5px}
          .mini i{width:6px;height:6px;border-radius:50%;background:var(--ink-2);animation:eshdot 1.1s ease-in-out infinite}
          .mini i:nth-child(2){animation-delay:.18s} .mini i:nth-child(3){animation-delay:.36s}
          .hint{font-size:12px;color:var(--ink-3);min-height:16px;text-align:center}
          .err{color:#c0392b;font-size:13px;text-align:center;max-width:520px;min-height:1em}
          @media (prefers-color-scheme:dark){:root:not([data-theme="light"]) .err{color:#ff8f7a}}
          .end{position:absolute;bottom:24px;left:0;right:0;text-align:center}
          .end button{font:500 11px var(--mono);letter-spacing:.08em;text-transform:uppercase;color:var(--ink-2);
            background:none;border:none;cursor:pointer;padding:8px 14px;border-radius:999px}
          .end button:hover{color:var(--ink);background:var(--bubble)}
          .foot{position:absolute;bottom:10px;left:0;right:0;text-align:center;font:400 10px var(--mono);color:var(--ink-3)}
        </style></head>
        <body>
          <div class="brand">esh · voice</div>
          <div class="pickers">
            <select id="llmSel" title="Language model"><option value="">Model: Auto</option></select>
            <select id="ttsSel" title="Voice (TTS)"><option value="">Voice: Default</option></select>
          </div>
          <div class="wrap">
            <div class="orb" id="orb" title="Tap to start"></div>
            <div class="state" id="state">Ready</div>
            <div class="log" id="log"></div>
            <div class="hint" id="hint">Tap to start</div>
            <div class="err" id="err"></div>
          </div>
          <div class="end"><button id="endbtn" hidden>End</button></div>
          <div class="foot" id="foot" hidden>Everything runs on-device — VAD, STT, model, TTS.</div>
        <script>
        (function(){
          const $=id=>document.getElementById(id);
          const orb=$('orb'), stateEl=$('state'), logEl=$('log'), errEl=$('err'), hintEl=$('hint'),
                endBtn=$('endbtn'), foot=$('foot'), llmSel=$('llmSel'), ttsSel=$('ttsSel');
          let ws=null, audioCtx=null, micStream=null, proc=null, playing=false, playQueue=[], curSource=null, curTurn=0;
          let active=false, cur='idle', youT=null, eshT=null;
          const SR=16000;

          const PULSE=new Set(['listening','speechDetected']);
          const DOTS=new Set(['thinking','transcribing']);
          const BARS=new Set(['speaking']);
          function orbHTML(s){
            if(PULSE.has(s)) return '<span class="dot-wrap anim"><span class="dot"></span></span>';
            if(DOTS.has(s))  return '<span class="dots"><i></i><i></i><i></i></span>';
            if(BARS.has(s))  return '<span class="bars"><i></i><i></i><i></i><i></i><i></i><i></i><i></i></span>';
            return '<span class="dot-wrap"><span class="dot"></span></span>';
          }
          function labelFor(s){ return ({listening:'Listening',speechDetected:'Listening',transcribing:'Transcribing',thinking:'Thinking',speaking:'Speaking',idle:'Ready',ended:'Ready',error:'Error'})[s]||s; }
          function hintFor(s){ if(!active) return 'Tap to start'; if(s==='speaking') return 'Tap to interrupt'; if(PULSE.has(s)) return 'Listening… speak now'; if(s==='thinking') return 'Thinking…'; if(s==='transcribing') return 'Transcribing…'; return ''; }
          function setState(s){ cur=s; orb.innerHTML=orbHTML(s); stateEl.textContent=labelFor(s); hintEl.textContent=hintFor(s); }

          function scrollLog(){ requestAnimationFrame(()=>{ logEl.scrollTop=logEl.scrollHeight; }); }
          const DOTS_HTML='<span class="mini"><i></i><i></i><i></i></span>';
          // A turn = {el, who(span), st(status span), bubble}. status shows the live stage; live toggles a cursor.
          function makeTurn(role){
            const el=document.createElement('div'); el.className='turn '+role;
            const who=document.createElement('div'); who.className='who';
            const name=document.createElement('span'); name.textContent=role;
            const st=document.createElement('span'); st.className='st';
            who.appendChild(name); who.appendChild(st);
            const bubble=document.createElement('div'); bubble.className='bubble';
            el.appendChild(who); el.appendChild(bubble); logEl.appendChild(el); scrollLog();
            return {el, who, st, bubble};
          }
          function status(t,txt){ if(t){ t.st.innerHTML = txt ? ('· '+txt) : ''; } }
          function live(t,on){ if(t) t.bubble.classList.toggle('live',!!on); }
          function indicator(t){ if(t){ t.bubble.classList.add('empty'); t.bubble.innerHTML=DOTS_HTML; } }
          function settext(t,txt){ if(t){ t.bubble.classList.remove('empty'); t.bubble.textContent=txt; } }

          function wsURL(){ const p=(parseInt(location.port||'80',10)+1); return (location.protocol==='https:'?'wss://':'ws://')+location.hostname+':'+p+'/v1/voice/stream'; }
          function startMsg(){ const m={t:'start',sampleRate:SR}; if(llmSel.value) m.inferenceModel=llmSel.value; if(ttsSel.value) m.ttsModel=ttsSel.value; return m; }

          async function loadModels(){
            try{
              const r=await fetch('/v1/models'); const j=await r.json();
              (j.data||[]).forEach(m=>{ const o=document.createElement('option'); o.value=m.id; o.textContent='Model: '+(m.display_name||m.id); llmSel.appendChild(o); });
            }catch(_){}
            try{
              const r=await fetch('/v1/audio/models'); const j=await r.json();
              (j.data||[]).filter(m=>!m.capabilities||m.capabilities.indexOf('tts')>=0).forEach(m=>{ const o=document.createElement('option'); o.value=m.id; o.textContent='Voice: '+(m.display_name||m.id); ttsSel.appendChild(o); });
            }catch(_){}
          }

          async function start(){
            if(active) return;
            errEl.textContent='';
            try { micStream = await navigator.mediaDevices.getUserMedia({audio:{channelCount:1,echoCancellation:true,noiseSuppression:true}}); }
            catch(e){ errEl.textContent='Microphone permission is required for voice.'; return; }
            active=true; endBtn.hidden=false; foot.hidden=false;
            ws = new WebSocket(wsURL());
            ws.binaryType='arraybuffer';
            ws.onopen=()=>{ ws.send(JSON.stringify(startMsg())); startCapture(); setState('listening'); };
            ws.onclose=()=>{ active=false; setState('ended'); teardown(); };
            ws.onerror=()=>{ errEl.textContent='Could not reach the voice endpoint. Is `esh serve` running?'; };
            ws.onmessage=onMessage;
          }

          // Switch model/voice mid-session: start a fresh server session over the SAME socket with the new pins.
          function applyModelChange(){ if(!active||!ws||ws.readyState!==1) return; flushPlayback(); youT=null; eshT=null; ws.send(JSON.stringify(startMsg())); setState('listening'); }

          function startCapture(){
            audioCtx = new (window.AudioContext||window.webkitAudioContext)();
            const src=audioCtx.createMediaStreamSource(micStream);
            proc=audioCtx.createScriptProcessor(2048,1,1);
            const inRate=audioCtx.sampleRate;
            src.connect(proc); proc.connect(audioCtx.destination);
            proc.onaudioprocess=(e)=>{
              if(!ws||ws.readyState!==1) return;
              const input=e.inputBuffer.getChannelData(0);
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

              // ---- YOU side ----
              case 'vad.speech_started':
                youT=makeTurn('you'); status(youT,'listening'); indicator(youT); setState('listening'); break;
              case 'input.level':
                if(youT){ const s=Math.min(1,(m.level||0)*6); youT.bubble.style.opacity=(0.55+0.45*s).toFixed(2); } break;
              case 'vad.speech_ended':
                if(youT){ status(youT,'transcribing'); indicator(youT); youT.bubble.style.opacity=''; } setState('transcribing'); break;
              case 'transcript.final':
                if(!youT) youT=makeTurn('you');
                if((m.text||'').trim()){ status(youT,''); settext(youT,m.text); }
                else { status(youT,'no speech'); settext(youT,'…'); }
                youT=null; scrollLog(); break;

              // ---- ESH side ----
              case 'assistant.thinking_started':
                eshT=makeTurn('esh'); status(eshT,'thinking'); indicator(eshT); break;
              case 'assistant.text_delta':
                if(!eshT){ eshT=makeTurn('esh'); }
                if(eshT.bubble.classList.contains('empty')) settext(eshT,'');
                status(eshT,'generating'); live(eshT,true); eshT.bubble.textContent+=(m.text||''); scrollLog(); break;
              case 'assistant.text_final':
                if(eshT){ if((m.text||'').length) settext(eshT,m.text); } break;
              case 'tts.started':
                if(eshT){ status(eshT,'speaking'); const d=document.createElement('span'); d.className='live-dot'; eshT.who.appendChild(d);} break;
              case 'tts.finished':
                if(eshT){ live(eshT,false); status(eshT,''); const d=eshT.who.querySelector('.live-dot'); if(d) d.remove(); } eshT=null; break;

              case 'interruption.detected': if(eshT){ status(eshT,'interrupted'); live(eshT,false);} break;
              case 'playback.cancelled': flushPlayback(); if(eshT){ live(eshT,false); status(eshT,''); const d=eshT.who.querySelector('.live-dot'); if(d) d.remove(); } break;
              case 'install.required': setState('idle'); errEl.textContent=(m.message||'A voice model needs to be installed.')+(m.text?(' ('+m.text+')'):''); active=false; teardown(); break;
              case 'session.error': errEl.textContent=m.message||'error'; break;
            }
          }

          // Binary TTS frame: [magic 'eV'(2)][ver(1)][turn(4)][seq(4)][sampleRate(4)][channels(1)][flags(1)][WAV payload]
          function onAudio(buf){
            const b=new Uint8Array(buf); if(b.length<17||b[0]!==0x65||b[1]!==0x56) return;
            const dv=new DataView(buf); const turn=dv.getUint32(3); const wav=buf.slice(17);
            if(turn<curTurn) return;
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

          function interrupt(){ if(ws&&ws.readyState===1){ try{ws.send(JSON.stringify({t:'interrupt'}));}catch(_){}} flushPlayback(); }
          function stop(){ if(ws&&ws.readyState===1){ try{ws.send(JSON.stringify({t:'end'}));}catch(_){}} if(ws) ws.close(); active=false; teardown(); setState('ended'); }
          function teardown(){ try{proc&&proc.disconnect();}catch(_){}; try{audioCtx&&audioCtx.close();}catch(_){}; try{micStream&&micStream.getTracks().forEach(t=>t.stop());}catch(_){}; flushPlayback(); endBtn.hidden=true; }

          orb.onclick=()=>{ if(!active){ start(); } else if(cur==='speaking'){ interrupt(); } };
          endBtn.onclick=stop;
          llmSel.onchange=applyModelChange; ttsSel.onchange=applyModelChange;
          window.addEventListener('beforeunload',stop);
          loadModels(); setState('idle');
        })();
        </script></body></html>
        """
    }
}
