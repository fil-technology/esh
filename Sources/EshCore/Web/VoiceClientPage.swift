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
          :root{--paper:#fbfaf8;--ink:#201e1b;--muted:#6b6760;--line:rgba(32,30,27,.1);--accent:#201e1b}
          *{box-sizing:border-box} html,body{margin:0;height:100%}
          body{background:var(--paper);color:var(--ink);font:15px/1.5 system-ui,-apple-system,sans-serif;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:18px;padding:24px}
          .orb{width:96px;height:96px;border-radius:50%;background:#eee;display:grid;place-items:center;transition:transform .15s,background .2s;box-shadow:0 1px 3px rgba(0,0,0,.08)}
          .orb.listening{background:#e8f0ff} .orb.speechDetected{background:#dbe8ff;transform:scale(1.06)}
          .orb.transcribing{background:#fff3d6} .orb.thinking{background:#f0e8ff} .orb.speaking{background:#daf5e4;transform:scale(1.04)}
          .orb.error{background:#ffe0e0} .orb.ended,.orb.idle{background:#eee}
          .state{font-weight:600;text-transform:capitalize} .muted{color:var(--muted);font-size:13px}
          .row{display:flex;gap:10px} button{font:inherit;padding:9px 16px;border-radius:10px;border:1px solid var(--line);background:#fff;cursor:pointer}
          button.primary{background:var(--accent);color:#fff;border-color:var(--accent)} button:disabled{opacity:.5;cursor:default}
          .log{width:min(560px,92vw);max-height:40vh;overflow:auto;border:1px solid var(--line);border-radius:12px;padding:12px;background:#fff}
          .turn{margin:6px 0} .turn .who{font-size:11px;color:var(--muted);text-transform:uppercase;letter-spacing:.04em}
          .lvl{width:min(560px,92vw);height:4px;border-radius:2px;background:#eee;overflow:hidden}
          .lvl i{display:block;height:100%;width:0;background:#8ab;transition:width .08s}
          .err{color:#a33;font-size:13px}
        </style></head>
        <body>
          <div class="orb idle" id="orb">🎙️</div>
          <div class="state" id="state">Ready</div>
          <div class="lvl"><i id="lvl"></i></div>
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
          function addTurn(who,text){ const d=document.createElement('div'); d.className='turn'; d.innerHTML='<div class="who">'+who+'</div><div>'+(text||'')+'</div>'; logEl.appendChild(d); logEl.scrollTop=logEl.scrollHeight; return d; }
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
