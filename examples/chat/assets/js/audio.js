// Browser audio for the chat example.
//
// Recorder captures the microphone, converts it to mono 16 kHz s16le PCM, and
// pushes one "voice" event per utterance. AudioFlow sessions accept this format.
// Player schedules the reply PCM chunks that the server pushes in turn order.

const INPUT_RATE = 16_000;
const MAX_SECONDS = 30;

const CAPTURE_WORKLET = `
registerProcessor("capture", class extends AudioWorkletProcessor {
  process(inputs) {
    const channel = inputs[0]?.[0];
    if (channel) this.port.postMessage(channel.slice(0));
    return true;
  }
});`;

let playback = null;

// Browsers start an AudioContext only after a user gesture.
const playbackContext = () => {
  playback ??= new AudioContext();
  if (playback.state === "suspended") playback.resume();
  return playback;
};

for (const type of ["pointerdown", "keydown"]) {
  document.addEventListener(type, () => playbackContext(), { capture: true });
}

const toBase64 = (bytes) => {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
};

const fromBase64 = (text) => Uint8Array.from(atob(text), (c) => c.charCodeAt(0));

// Box-filter downsampling is enough for speech recognition input.
const toPcm16 = (chunks, rate) => {
  const length = chunks.reduce((sum, chunk) => sum + chunk.length, 0);
  const samples = new Float32Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    samples.set(chunk, offset);
    offset += chunk.length;
  }

  const ratio = rate / INPUT_RATE;
  const out = new Int16Array(Math.floor(length / ratio));
  for (let i = 0; i < out.length; i++) {
    const start = Math.floor(i * ratio);
    const end = Math.max(start + 1, Math.floor((i + 1) * ratio));
    let sum = 0;
    for (let j = start; j < end; j++) sum += samples[j];
    const value = Math.max(-1, Math.min(1, sum / (end - start)));
    out[i] = value < 0 ? value * 0x8000 : value * 0x7fff;
  }
  return new Uint8Array(out.buffer);
};

export const Recorder = {
  mounted() {
    this.button = this.el.querySelector("button");
    this.onClick = () => (this.capture ? this.stop() : this.start());
    this.button.addEventListener("click", this.onClick);
  },

  destroyed() {
    this.button.removeEventListener("click", this.onClick);
    this.release();
  },

  async start() {
    window.dispatchEvent(new CustomEvent("chat:flush"));
    this.pushEvent("recording");

    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true },
      });
      const context = new AudioContext();
      const url = URL.createObjectURL(new Blob([CAPTURE_WORKLET], { type: "text/javascript" }));
      await context.audioWorklet.addModule(url);
      URL.revokeObjectURL(url);

      const node = new AudioWorkletNode(context, "capture");
      const chunks = [];
      node.port.onmessage = ({ data }) => chunks.push(data);
      context.createMediaStreamSource(stream).connect(node);

      this.capture = { stream, context, node, chunks };
      this.timer = setTimeout(() => this.stop(), MAX_SECONDS * 1000);
      this.draw(true);
    } catch (error) {
      this.release();
      this.pushEvent("recording_failed", { message: error.message });
    }
  },

  stop() {
    const capture = this.capture;
    if (!capture) return;
    const pcm = toPcm16(capture.chunks, capture.context.sampleRate);
    this.release();
    this.pushEvent("voice", { pcm: toBase64(pcm) });
  },

  release() {
    clearTimeout(this.timer);
    const capture = this.capture;
    this.capture = null;
    capture?.node.disconnect();
    capture?.stream.getTracks().forEach((track) => track.stop());
    capture?.context.close();
    this.draw(false);
  },

  draw(recording) {
    this.button.setAttribute("aria-pressed", String(recording));
    this.button.setAttribute("aria-label", recording ? "Stop recording" : "Record a voice message");
  },
};

export const Player = {
  mounted() {
    this.sources = new Set();
    this.next = 0;
    this.flush = () => this.stopAll();
    window.addEventListener("chat:flush", this.flush);

    this.handleEvent("play", ({ pcm, rate }) => {
      const context = playbackContext();
      const bytes = fromBase64(pcm);
      const samples = new Int16Array(bytes.buffer, 0, bytes.length >> 1);
      if (samples.length === 0) return;

      const buffer = context.createBuffer(1, samples.length, rate);
      const channel = buffer.getChannelData(0);
      for (let i = 0; i < samples.length; i++) channel[i] = samples[i] / 0x8000;

      const source = context.createBufferSource();
      source.buffer = buffer;
      source.connect(context.destination);
      source.onended = () => this.sources.delete(source);
      this.next = Math.max(this.next, context.currentTime);
      source.start(this.next);
      this.next += buffer.duration;
      this.sources.add(source);
    });

    this.handleEvent("flush", this.flush);
  },

  destroyed() {
    window.removeEventListener("chat:flush", this.flush);
    this.stopAll();
  },

  stopAll() {
    for (const source of this.sources) source.stop();
    this.sources.clear();
    this.next = 0;
  },
};
