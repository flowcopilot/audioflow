import '@fontsource-variable/bricolage-grotesque/standard.css';
import '@fontsource/ibm-plex-mono/400.css';
import './theme.css';
import { Receiver } from './receiver';
const button = (id: string) => document.getElementById(id) as HTMLButtonElement;
const file = document.getElementById('pcm') as HTMLInputElement;
const status = (s: string) => { document.getElementById('status')!.textContent = s; };
let ws: WebSocket | undefined, receiver: Receiver | undefined, active = false;
const send = (type: string, extra = {}) => {
  if (ws?.readyState === WebSocket.OPEN) ws.send(JSON.stringify({type, ...extra}));
};
function controls() {
  const open = ws?.readyState === WebSocket.OPEN;
  button('connect').disabled = !!ws;
  button('disconnect').disabled = !ws;
  button('start').disabled = !open || active || !file.files?.length;
  button('cancel').disabled = !open || !active;
  button('play').disabled = !receiver;
  file.disabled = active;
}
function clearReceiver() { const old = receiver; receiver = undefined; void old?.close(); controls(); }
function cancel() { send('cancel'); clearReceiver(); status('Cancelling; awaiting server cleanup'); }
function disconnect() {
  const old = ws; ws = undefined;
  old?.close(); active = false; clearReceiver(); controls();
  status('Disconnected. Server stops the owned provider session.');
}
button('connect').onclick = () => {
  ws = new WebSocket(`ws://${location.host}/ws`);
  const socket = ws;
  controls();
  socket.onopen = () => { if (ws === socket) { status('Controls connected. Select PCM and start explicitly.'); controls(); } };
  socket.onerror = () => { if (ws === socket) status('Control connection failed. Run the loopback server at 127.0.0.1.'); };
  socket.onclose = () => { if (ws === socket) disconnect(); };
  socket.onmessage = ({data}) => {
    if (ws !== socket) return;
    const event = JSON.parse(data);
    if (event.type === 'publication') {
      if (!active || receiver) return;
      receiver = new Receiver(document.getElementById('media')!, () => {
        status('Both provider tracks subscribed; sending PCM. Enable playback if blocked.');
        send('ready');
      }, message => { cancel(); status(message + '; cancelling provider session'); });
      void receiver.connect(event.url, event.token);
      status('Joining provider room; click Enable audio / video within 15 seconds. Waiting for BOTH tracks and playback permission.');
    } else {
      status(event.message);
      if (event.type === 'complete') { active = false; clearReceiver(); }
      if (event.type === 'error') {
        active = false; clearReceiver();
      }
      if (event.type === 'ended') clearReceiver();
    }
    controls();
  };
};
file.onchange = controls;
button('start').onclick = async () => {
  const input = file.files?.[0], socket = ws;
  if (!input || active || !socket) return;
  if (input.size < 2 || input.size > 480000 || input.size % 2) {
    status('Use nonempty raw mono 24 kHz PCM16LE, at most 480000 bytes (10 seconds). WAV headers are not supported.'); return;
  }
  active = true; controls();
  try {
    const bytes = new Uint8Array(await input.arrayBuffer());
    if (ws !== socket || !active) return;
    let raw = ''; for (const byte of bytes) raw += String.fromCharCode(byte);
    send('start', {pcm: btoa(raw)});
  } catch { active = false; status('Could not read PCM file'); controls(); }
};
button('play').onclick = () => {
  const current = receiver;
  void current?.play().catch(error => {
    if (receiver === current) status(error instanceof Error ? error.message : 'Playback failed. Retry Enable audio / video.');
  });
};
button('cancel').onclick = cancel;
button('disconnect').onclick = disconnect;
window.addEventListener('pagehide', disconnect);
controls();
