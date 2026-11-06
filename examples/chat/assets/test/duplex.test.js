import { afterEach, test } from "node:test";
import assert from "node:assert/strict";

// Browser fakes: a 48 kHz AudioContext with a settable clock, a microphone
// stream whose tracks record stop(), and a worklet port the test drives.
let contexts = [];
let microphone;
globalThis.document = { addEventListener() {} };
globalThis.window = { addEventListener() {}, removeEventListener() {} };
globalThis.AudioContext = class {
  constructor() {
    this.sampleRate = 48_000;
    this.currentTime = 0;
    this.state = "running";
    this.sources = [];
    this.audioWorklet = { addModule: async () => {} };
    contexts.push(this);
  }
  close() {
    this.state = "closed";
  }
  createMediaStreamSource() {
    return { connect() {} };
  }
  createBuffer(_, samples, rate) {
    return { duration: samples / rate, getChannelData: () => new Float32Array(samples) };
  }
  createBufferSource() {
    const source = {
      connect() {},
      start(at) {
        source.at = at;
      },
      stop() {
        source.stopped = true;
      },
    };
    this.sources.push(source);
    return source;
  }
};
globalThis.AudioWorkletNode = class {
  constructor() {
    this.port = {};
    microphone.node = this;
  }
  disconnect() {
    this.disconnected = true;
  }
};
Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: { mediaDevices: { getUserMedia: () => microphone.grant() } },
});

const {
  Duplex,
  StreamResampler,
  CHUNK_SAMPLES,
  MAX_IN_FLIGHT,
  MAX_PENDING,
  MAX_PLAYBACK_AHEAD,
} = await import("../js/duplex.js");

// A failed assertion must not leave a call (and its status timer) running.
const mounted = [];
afterEach(() => mounted.splice(0).forEach((hook) => hook.destroyed()));

const tick = () => new Promise((resolve) => setImmediate(resolve));

function grantMicrophone() {
  const track = {
    stop() {
      track.stopped = true;
    },
  };
  microphone = { track, grant: async () => ({ getTracks: () => [track] }) };
  return microphone;
}

function mount() {
  const handlers = {};
  const pushes = [];
  const listeners = {};
  const stats = { textContent: "" };
  const buttons = {
    start: { disabled: false, dataset: { call: "start" } },
    stop: { disabled: true, dataset: { call: "stop" } },
  };
  const el = {
    addEventListener(type, fn) {
      listeners[type] = fn;
    },
    removeEventListener() {},
    querySelector: (selector) => selector.includes('"start"') ? buttons.start :
      selector.includes('"stop"') ? buttons.stop : stats,
  };
  const hook = {
    ...Duplex,
    el: { parentElement: el },
    handleEvent(name, fn) {
      handlers[name] = fn;
    },
    pushEvent(name, payload, reply) {
      pushes.push({ name, payload, reply });
    },
  };
  hook.mounted();
  mounted.push(hook);
  const click = (action) =>
    listeners.click({ target: { closest: () => buttons[action] } });
  const sent = (name) => pushes.filter((push) => push.name === name);
  return { hook, handlers, pushes, click, sent, stats, buttons };
}

// Starts a conversation: click, microphone grant, server reply, model handshake.
async function connect(generation = 1) {
  const view = mount();
  grantMicrophone();
  view.click("start");
  await tick();
  view.sent("call_start")[0].reply({ ok: true, generation });
  view.handlers.call_ready({ generation });
  return view;
}

// 80 ms of capture at 48 kHz, in 128-sample worklet blocks.
function speak(blocks = 30, value = 0.5) {
  for (let i = 0; i < blocks; i++) {
    microphone.node.port.onmessage({ data: new Float32Array(128).fill(value) });
  }
}

const pcm = (samples) => Buffer.alloc(samples * 2).toString("base64");

test("resampler output does not depend on block boundaries", () => {
  const input = Float32Array.from({ length: 4_410 }, (_, i) => Math.sin(i / 7));
  const whole = new StreamResampler(44_100, 24_000).push(input);
  const split = new StreamResampler(44_100, 24_000);
  const parts = [];
  for (let i = 0; i < input.length; i += 128) parts.push(...split.push(input.subarray(i, i + 128)));
  assert.equal(whole.length, 2_400);
  assert.equal(parts.length, whole.length);
  parts.forEach((value, i) => assert.ok(Math.abs(value - whole[i]) < 1e-5));
  assert.throws(() => new StreamResampler(16_000, 24_000), /below 24000 Hz/);
});

test("capture sends 80 ms 24 kHz chunks only after the model handshake", async () => {
  const view = mount();
  grantMicrophone();
  view.click("start");
  await tick();
  speak(60);
  assert.equal(view.sent("call_audio").length, 0);
  view.sent("call_start")[0].reply({ ok: true, generation: 7 });
  speak(60);
  assert.equal(view.sent("call_audio").length, 0);
  view.handlers.call_ready({ generation: 7 });
  speak(30);
  const [chunk] = view.sent("call_audio");
  assert.equal(chunk.payload.generation, 7);
  const bytes = Buffer.from(chunk.payload.pcm, "base64");
  assert.equal(bytes.length, CHUNK_SAMPLES * 2);
  assert.equal(bytes.readInt16LE(0), Math.round(0.5 * 0x7fff - 0.5));
});

test("input waits for acknowledgements and drops the oldest chunks past the queue limit", async () => {
  const view = await connect();
  speak(30 * (MAX_IN_FLIGHT + MAX_PENDING + 3));
  const audio = () => view.sent("call_audio");
  assert.equal(audio().length, MAX_IN_FLIGHT);
  audio()[0].reply({ ok: true });
  assert.equal(audio().length, MAX_IN_FLIGHT + 1);
  audio()[1].reply({ ok: false, error: "overloaded" });
  assert.equal(audio().length, MAX_IN_FLIGHT + 2);
  view.hook.draw();
  assert.match(view.stats.textContent, /Sent 1 · dropped 4 input chunks/);
});

test("capture starts when the model handshake arrives before the start reply", async () => {
  const view = mount();
  grantMicrophone();
  view.click("start");
  await tick();
  view.handlers.call_ready({ generation: 9 });
  view.sent("call_start")[0].reply({ ok: true, generation: 9 });
  speak(30);
  assert.equal(view.sent("call_audio").length, 1);
  assert.equal(view.sent("call_audio")[0].payload.generation, 9);
});

test("model audio plays while the microphone keeps sending", async () => {
  const view = await connect();
  const [context] = contexts.slice(-1);
  view.handlers.call_play({ generation: 1, pcm: pcm(1_920), rate: 24_000 });
  view.handlers.call_play({ generation: 1, pcm: pcm(1_920), rate: 24_000 });
  speak(30);
  view.sent("call_audio")[0].reply({ ok: true });
  speak(30);
  view.handlers.call_play({ generation: 1, pcm: pcm(1_920), rate: 24_000 });
  assert.equal(view.sent("call_audio").length, 2);
  assert.deepEqual(
    context.sources.map((source) => [Number(source.at.toFixed(2)), Boolean(source.stopped)]),
    [
      [0.04, false],
      [0.12, false],
      [0.2, false],
    ],
  );
});

test("playback drops audio beyond the queue limit and audio of another generation", async () => {
  const view = await connect(2);
  const [context] = contexts.slice(-1);
  for (let i = 0; i < 20; i++) {
    view.handlers.call_play({ generation: 2, pcm: pcm(1_920), rate: 24_000 });
  }
  const accepted = context.sources.length;
  assert.ok(accepted > 1 && accepted < 20);
  assert.ok(context.sources.every((source) => source.at <= MAX_PLAYBACK_AHEAD));
  view.handlers.call_play({ generation: 1, pcm: pcm(1_920), rate: 24_000 });
  assert.equal(context.sources.length, accepted);
  context.currentTime = 0.5;
  view.handlers.call_play({ generation: 2, pcm: pcm(1_920), rate: 24_000 });
  assert.equal(context.sources.length, accepted + 1);
});

test("stop releases the microphone, playback and context and ignores later events", async () => {
  const view = await connect(3);
  const [context] = contexts.slice(-1);
  view.handlers.call_play({ generation: 3, pcm: pcm(1_920), rate: 24_000 });
  view.click("stop");
  assert.deepEqual(view.sent("call_stop").at(-1).payload, { generation: 3 });
  assert.ok(microphone.track.stopped);
  assert.ok(microphone.node.disconnected);
  assert.ok(context.sources.every((source) => source.stopped));
  assert.equal(context.state, "closed");
  view.handlers.call_play({ generation: 3, pcm: pcm(1_920), rate: 24_000 });
  assert.equal(context.sources.length, 1);
});

test("server stop, disconnect and a stop during startup all release the call", async () => {
  const stopped = await connect(4);
  stopped.handlers.call_stopped({ generation: 3 });
  assert.ok(!microphone.track.stopped);
  stopped.handlers.call_stopped({ generation: 4 });
  assert.ok(microphone.track.stopped);

  const view = await connect(6);
  view.hook.disconnected();
  assert.ok(microphone.track.stopped);

  const early = mount();
  grantMicrophone();
  early.click("start");
  assert.equal(early.buttons.stop.disabled, false);
  await tick();
  early.click("stop");
  assert.equal(early.buttons.start.disabled, false);
  assert.ok(microphone.track.stopped);
  early.sent("call_start")[0].reply({ ok: true, generation: 8 });
  assert.deepEqual(early.sent("call_stop").at(-1).payload, { generation: 8 });
});

test("microphone denial and device loss report a failure and release capture", async () => {
  const denied = mount();
  microphone = {
    grant: async () => {
      throw new Error("Permission denied");
    },
  };
  denied.click("start");
  await tick();
  assert.deepEqual(denied.sent("call_failed").at(-1).payload, { message: "Permission denied" });
  assert.equal(contexts.at(-1).state, "closed");
  assert.equal(denied.sent("call_start").length, 0);

  const lost = await connect(9);
  microphone.track.onended();
  assert.deepEqual(lost.sent("call_failed").at(-1).payload, { message: "Microphone disconnected" });
  assert.ok(microphone.track.stopped);
});

test("a microphone request that does not finish times out and releases a late grant", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const view = mount();
  const mic = grantMicrophone();
  let grant;
  mic.grant = () => new Promise((resolve) => { grant = resolve; });
  view.click("start");
  t.mock.timers.tick(20_000);
  assert.equal(view.hook.call, null);
  assert.match(view.sent("call_failed").at(-1).payload.message, /microphone/i);
  grant({ getTracks: () => [mic.track] });
  await tick();
  assert.ok(mic.track.stopped);
  assert.equal(view.sent("call_start").length, 0);
});
