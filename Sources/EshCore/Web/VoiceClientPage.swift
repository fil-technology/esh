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
        <link rel="preconnect" href="https://fonts.googleapis.com">
        <link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500&display=swap" rel="stylesheet">
        <style>
          :root{
            --paper:#fbfaf8;--ink:#201e1b;--ink-2:rgba(32,30,27,.6);--ink-3:rgba(32,30,27,.42);
            --line:rgba(32,30,27,.12);--bubble:rgba(32,30,27,.06);
            --mono:'IBM Plex Mono',ui-monospace,SFMono-Regular,Menlo,monospace;
          }
          @media (prefers-color-scheme:dark){:root:not([data-theme="light"]){
            --paper:#161513;--ink:#f2efe9;--ink-2:rgba(242,239,233,.62);--ink-3:rgba(242,239,233,.44);
            --line:rgba(255,255,255,.14);--bubble:rgba(255,255,255,.08);
          }}
          *{box-sizing:border-box} html,body{margin:0;height:100%}
          body{background:var(--paper);color:var(--ink);overflow:hidden;
            font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif}
          @keyframes eshpulse{0%,100%{transform:scale(1);opacity:.9}50%{transform:scale(1.12);opacity:1}}
          @keyframes eshbar{0%,100%{transform:scaleY(.35)}50%{transform:scaleY(1)}}
          @keyframes eshdot{0%,100%{opacity:.2}50%{opacity:1}}
          @keyframes eshblink{0%,49%{opacity:1}50%,100%{opacity:0}}
          .wrap{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:20px;padding:0 40px}
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
          .turn .who{font:500 9.5px var(--mono);letter-spacing:.1em;text-transform:uppercase;color:var(--ink-3)}
          .bubble{max-width:86%;line-height:1.55;white-space:pre-wrap;word-break:break-word;letter-spacing:-.005em}
          .turn.you .bubble{font-size:14px;padding:10px 14px;border-radius:14px;background:var(--bubble);text-align:right}
          .turn.esh .bubble{font-size:16px}
          .bubble.live::after{content:"";display:inline-block;width:7px;height:14px;background:var(--ink);vertical-align:-2px;margin-left:3px;animation:eshblink 1s infinite}
          .hint{font-size:12px;color:var(--ink-3);min-height:16px;text-align:center}
          .err{color:#c0392b;font-size:13px;text-align:center;max-width:520px;min-height:1em}
          @media (prefers-color-scheme:dark){:root:not([data-theme="light"]) .err{color:#ff8f7a}}
          .end{position:absolute;bottom:26px;left:0;right:0;text-align:center}
          .end button{font:500 11px var(--mono);letter-spacing:.08em;text-transform:uppercase;color:var(--ink-2);
            background:none;border:none;cursor:pointer;padding:8px 14px;border-radius:999px}
          .end button:hover{color:var(--ink);background:var(--bubble)}
          .foot{position:absolute;bottom:12px;left:0;right:0;text-align:center;font:400 10px var(--mono);color:var(--ink-3)}
        </style></head>
        <body>
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
          const orb=$('orb'), stateEl=$('state'), logEl=$('log'), errEl=$('err'), hintEl=$('hint'), endBtn=$('endbtn'), foot=$('foot');
          let ws=null, audioCtx=null, micStream=null, proc=null, playing=false, playQueue=[], curSource=null, curTurn=0;
          let active=false, cur='idle', userBubble=null, asstBubble=null;
          const SR=16000;

          const PULSE=new Set(['listening','speechDetected']);
          const DOTS=new Set(['thinking','transcribing']);
          const BARS=new Set(['speaking']);
          function orbHTML(s){
            if(PULSE.has(s)) return '<span class="dot-wrap anim"><span class="dot"></span></span>';
            if(DOTS.has(s))  return '<span class="dots"><i></i><i></i><i></i></span>';
            if(BARS.has(s))  return '<span class="bars"><i></i><i></i><i></i><i></i><i></i><i></i><i></i></span>';
            return '<span class="dot-wrap"><span class="dot"></span></span>';   // idle / ended / error
          }
          function labelFor(s){ return ({listening:'Listening',speechDetected:'Listening',transcribing:'Transcribing',thinking:'Thinking',speaking:'Speaking',idle:'Ready',ended:'Ready',error:'Error'})[s]||s; }
          function hintFor(s){
            if(!active) return 'Tap to start';
            if(s==='speaking') return 'Tap to interrupt';
            if(PULSE.has(s)) return 'Listening…';
            return '';
          }
          function setState(s){ cur=s; orb.innerHTML=orbHTML(s); stateEl.textContent=labelFor(s); hintEl.textContent=hintFor(s); }

          function scrollLog(){ requestAnimationFrame(()=>{ logEl.scrollTop=logEl.scrollHeight; }); }
          function addTurn(who){
            const d=document.createElement('div'); d.className='turn '+who;
            const w=document.createElement('div'); w.className='who'; w.textContent=who;
            const b=document.createElement('div'); b.className='bubble live'; b.textContent='';
            d.appendChild(w); d.appendChild(b); logEl.appendChild(d); scrollLog(); return b;
          }
          function live(b,on){ if(b) b.classList.toggle('live',!!on); }

          function wsURL(){ const p=(parseInt(location.port||'80',10)+1); return (location.protocol==='https:'?'wss://':'ws://')+location.hostname+':'+p+'/v1/voice/stream'; }

          async function start(){
            if(active) return;
            errEl.textContent='';
            try { micStream = await navigator.mediaDevices.getUserMedia({audio:{channelCount:1,echoCancellation:true,noiseSuppression:true}}); }
            catch(e){ errEl.textContent='Microphone permission is required for voice.'; return; }
            active=true; endBtn.hidden=false; foot.hidden=false;
            ws = new WebSocket(wsURL());
            ws.binaryType='arraybuffer';
            ws.onopen=()=>{ ws.send(JSON.stringify({t:'start',sampleRate:SR})); startCapture(); setState('listening'); };
            ws.onclose=()=>{ active=false; setState('ended'); teardown(); };
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
              case 'vad.speech_started': userBubble=addTurn('you'); break;
              case 'transcript.partial': if(userBubble){ userBubble.textContent=m.text||''; scrollLog(); } break;
              case 'transcript.final':
                if(!userBubble) userBubble=addTurn('you');
                userBubble.textContent=m.text||''; live(userBubble,false); scrollLog(); break;
              case 'assistant.thinking_started': asstBubble=addTurn('esh'); break;
              case 'assistant.text_delta':
                if(!asstBubble) asstBubble=addTurn('esh');
                asstBubble.textContent+=m.text||''; scrollLog(); break;
              case 'assistant.text_final':
                if(asstBubble){ asstBubble.textContent=m.text||asstBubble.textContent; live(asstBubble,false); scrollLog(); } break;
              case 'tts.finished': live(asstBubble,false); asstBubble=null; break;
              case 'interruption.detected': live(asstBubble,false); break;
              case 'playback.cancelled': flushPlayback(); live(asstBubble,false); break;   // barge-in
              case 'install.required': setState('idle'); errEl.textContent=(m.message||'A voice model needs to be installed.')+(m.text?(' ('+m.text+')'):''); active=false; teardown(); break;
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

          // Barge-in from the UI: tapping the wave while esh is speaking interrupts it.
          function interrupt(){ if(ws&&ws.readyState===1){ try{ws.send(JSON.stringify({t:'interrupt'}));}catch(_){}} flushPlayback(); }

          function stop(){ if(ws&&ws.readyState===1){ try{ws.send(JSON.stringify({t:'end'}));}catch(_){}} if(ws) ws.close(); active=false; teardown(); setState('ended'); }
          function teardown(){ try{proc&&proc.disconnect();}catch(_){}; try{audioCtx&&audioCtx.close();}catch(_){}; try{micStream&&micStream.getTracks().forEach(t=>t.stop());}catch(_){}; flushPlayback(); endBtn.hidden=true; }

          orb.onclick=()=>{ if(!active){ start(); } else if(cur==='speaking'){ interrupt(); } };
          endBtn.onclick=stop;
          window.addEventListener('beforeunload',stop);
          setState('idle');
        })();
        </script></body></html>
        """
    }
}
