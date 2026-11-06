// Full duplex conversation with a local Moshi model through AudioFlow.Duplex.
//
// The microphone stays open for the whole conversation. Its samples are
// resampled continuously to 24 kHz and sent as 80 ms s16le chunks. Model audio
// plays at the same time; microphone input never stops or flushes playback.
//
// Flow limits:
// - Before the server reports the model handshake, microphone input is dropped.
// - At most MAX_IN_FLIGHT chunks wait for a server acknowledgement.
// - At most MAX_PENDING chunks wait to be sent; the oldest is dropped first.
// - Model audio more than MAX_PLAYBACK_AHEAD seconds ahead of the clock is dropped.
// - Each conversation has a server generation. Events of another generation
//   are ignored.

import { CAPTURE_WORKLET, fromBase64, toBase64 } from "./audio.js";

export const CALL_RATE = 24_000;
export const CHUNK_SAMPLES = 1_920;
export const MAX_IN_FLIGHT = 4;
export const MAX_PENDING = 12;
export const MAX_PLAYBACK_AHEAD = 1;
const PLAYBACK_LEAD = 0.04;

// Box-filter (area) resampler that keeps its phase between blocks, so the
// result does not depend on how the browser splits the input.
export class StreamResampler {
  constructor(inputRate, outputRate) {
    if (inputRate < outputRate) throw new Error(`Capture sample rate is below ${outputRate} Hz`);
    this.ratio = inputRate / outputRate;
    this.sum = 0;
    this.filled = 0;
  }

  push(samples) {
    const out = new Float32Array(Math.ceil((samples.length + this.filled) / this.ratio) + 1);
    let count = 0;
    for (const sample of samples) {
      let left = 1;
      while (left > 0) {
        const take = Math.min(left, this.ratio - this.filled);
        this.sum += sample * take;
        this.filled += take;
        left -= take;
        if (this.filled >= this.ratio - 1e-9) {
          out[count++] = this.sum / this.ratio;
          this.sum = 0;
          this.filled = 0;
        }
      }
    }
    return out.subarray(0, count);
  }
}

// Collects float samples into fixed s16le chunks.
export class Chunker {
  constructor(size) {
    this.buffer = new Int16Array(size);
    this.length = 0;
  }

  push(samples) {
    const chunks = [];
    for (const sample of samples) {
      const value = Math.max(-1, Math.min(1, sample));
      this.buffer[this.length++] = value < 0 ? value * 0x8000 : value * 0x7fff;
      if (this.length === this.buffer.length) {
        chunks.push(new Uint8Array(this.buffer.slice().buffer));
        this.length = 0;
      }
    }
    return chunks;
  }
}

export const Duplex = {
  mounted() {
    this.call = null;
    this.readyGeneration = null;
    this.controls = this.el.parentElement;
    this.onClick = (event) => {
      const button = event.target.closest("[data-call]");
      if (!button || button.disabled) return;
      if (button.dataset.call === "start") this.start();
      else this.stop();
    };
    this.controls.addEventListener("click", this.onClick);

    this.handleEvent("call_ready", ({ generation }) => {
      this.readyGeneration = generation;
      const call = this.current(generation);
      if (call) call.ready = true;
    });
    this.handleEvent("call_play", ({ generation, pcm, rate }) => {
      const call = this.current(generation);
      if (call) this.play(call, pcm, rate);
    });
    this.handleEvent("call_stopped", ({ generation }) => {
      const call = this.current(generation);
      if (call) this.release(call);
    });
  },

  destroyed() {
    this.controls.removeEventListener("click", this.onClick);
    this.release(this.call);
  },

  // The server stops the conversation when the LiveView process ends.
  disconnected() {
    this.release(this.call);
  },

  current(generation) {
    return this.call && this.call.generation === generation ? this.call : null;
  },

  async start() {
    if (this.call) return;
    const call = {
      generation: null,
      ready: false,
      context: null,
      stream: null,
      node: null,
      pending: [],
      inFlight: 0,
      sent: 0,
      dropped: 0,
      sources: new Set(),
      next: 0,
      late: 0,
      released: false,
    };
    this.call = call;
    this.draw("Requesting microphone…");

    try {
      // Created during the click, so the browser allows playback.
      call.context = new AudioContext();
      const resampler = new StreamResampler(call.context.sampleRate, CALL_RATE);
      const url = URL.createObjectURL(new Blob([CAPTURE_WORKLET], { type: "text/javascript" }));
      // A stream that arrives after a stop or a failure is stopped at once.
      const media = navigator.mediaDevices
        .getUserMedia({
          audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true },
        })
        .then((stream) => {
          call.stream = stream;
          if (call.released) this.release(call);
          return stream;
        });
      const [stream] = await Promise.all([
        media,
        call.context.audioWorklet.addModule(url).finally(() => URL.revokeObjectURL(url)),
      ]);
      if (this.call !== call) return;

      const chunker = new Chunker(CHUNK_SAMPLES);
      call.node = new AudioWorkletNode(call.context, "capture");
      call.node.port.onmessage = ({ data }) => {
        if (this.call !== call || !call.ready) return;
        for (const chunk of chunker.push(resampler.push(data))) this.enqueue(call, chunk);
      };
      call.context.createMediaStreamSource(stream).connect(call.node);
      for (const track of stream.getTracks()) {
        track.onended = () => this.fail(call, new Error("Microphone disconnected"));
      }

      this.pushEvent("call_start", {}, (reply) => {
        if (this.call !== call) {
          // Stopped while the server started it.
          if (reply?.ok) this.pushEvent("call_stop", { generation: reply.generation });
          return;
        }
        if (!reply?.ok) return this.release(call);
        call.generation = reply.generation;
        call.ready = this.readyGeneration === reply.generation;
        this.ticker = setInterval(() => this.draw(), 500);
        this.draw();
      });
    } catch (error) {
      this.fail(call, error);
    }
  },

  stop() {
    const call = this.call;
    if (!call) return;
    if (call.generation !== null) this.pushEvent("call_stop", { generation: call.generation });
    this.release(call);
  },

  fail(call, error) {
    if (this.call !== call) return this.release(call);
    this.release(call);
    this.pushEvent("call_failed", { message: error.message });
  },

  enqueue(call, chunk) {
    call.pending.push(chunk);
    while (call.pending.length > MAX_PENDING) {
      call.pending.shift();
      call.dropped++;
    }
    this.pump(call);
  },

  pump(call) {
    while (call.inFlight < MAX_IN_FLIGHT && call.pending.length > 0) {
      const pcm = toBase64(call.pending.shift());
      call.inFlight++;
      this.pushEvent("call_audio", { generation: call.generation, pcm }, (reply) => {
        if (this.call !== call) return;
        call.inFlight--;
        if (reply?.ok) call.sent++;
        else call.dropped++;
        this.pump(call);
      });
    }
  },

  play(call, pcm, rate) {
    const bytes = fromBase64(pcm);
    const samples = new Int16Array(bytes.buffer, 0, bytes.length >> 1);
    if (samples.length === 0) return;

    const context = call.context;
    const now = context.currentTime;
    const start = Math.max(call.next, now + PLAYBACK_LEAD);
    if (start - now > MAX_PLAYBACK_AHEAD) {
      call.late++;
      return;
    }

    const buffer = context.createBuffer(1, samples.length, rate);
    const channel = buffer.getChannelData(0);
    for (let i = 0; i < samples.length; i++) channel[i] = samples[i] / 0x8000;

    const source = context.createBufferSource();
    source.buffer = buffer;
    source.connect(context.destination);
    source.onended = () => call.sources.delete(source);
    source.start(start);
    call.sources.add(source);
    call.next = start + buffer.duration;
  },

  release(call) {
    if (!call) return;
    call.released = true;
    if (this.call === call) {
      this.call = null;
      clearInterval(this.ticker);
      this.draw("");
    }
    if (call.node) {
      call.node.port.onmessage = null;
      call.node.disconnect();
    }
    for (const track of call.stream?.getTracks() ?? []) {
      track.onended = null;
      track.stop();
    }
    for (const source of call.sources) {
      source.onended = null;
      source.stop();
    }
    call.sources.clear();
    call.pending.length = 0;
    if (call.context?.state !== "closed") call.context?.close();
  },

  draw(text) {
    const stats = this.controls.querySelector("#duplex-stats");
    if (!stats) return;
    const call = this.call;
    if (text !== undefined || !call) {
      stats.textContent = text ?? "";
      return;
    }
    const queued = Math.max(0, call.next - call.context.currentTime);
    stats.textContent =
      `Sent ${call.sent} · dropped ${call.dropped} input chunks · ` +
      `${Math.round(queued * 1000)} ms queued playback · ${call.late} late output chunks`;
  },
};
