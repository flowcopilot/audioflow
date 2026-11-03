import WebSocket from "ws";
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import {
  PipecatClient,
  RTVIMessage,
  logger,
  LogLevel,
} from "@pipecat-ai/client-js";
import { AudioFlowTransport } from "./transport.ts";

const playback = { started: 0, stopped: 0, closed: 0 };
// Web Audio fixture tests scheduling/cleanup without using an audio device.
class FixtureAudioContext {
  currentTime = 0;
  destination = {};
  async resume() {}
  async close() {
    playback.closed++;
  }
  createBuffer(_channels: number, length: number, rate: number) {
    const data = new Float32Array(length);
    return { duration: length / rate, getChannelData: () => data };
  }
  createBufferSource() {
    return {
      buffer: undefined,
      onended: undefined,
      connect() {},
      disconnect() {},
      start() {
        playback.started++;
      },
      stop() {
        playback.stopped++;
      },
    };
  }
}

test(
  "official PipecatClient connects, sends text, dispatches events and reconnects to AudioFlow",
  { timeout: 30000 },
  async () => {
    Object.defineProperty(globalThis, "window", {
      value: { navigator: globalThis.navigator },
      configurable: true,
    });
    Object.defineProperty(globalThis, "WebSocket", {
      value: WebSocket,
      configurable: true,
    });
    Object.defineProperty(globalThis, "AudioContext", {
      value: FixtureAudioContext,
      configurable: true,
    });
    logger.setLevel(LogLevel.ERROR);
    const server = spawn(
      "mix",
      ["run", "--no-halt", "examples/rtvi-client/server.exs"],
      {
        cwd: new URL("../../", import.meta.url),
        env: { ...process.env, MIX_ENV: "test" },
        detached: true,
      },
    );
    let output = "";
    server.stderr.on("data", (d) => {
      output += d;
    });
    try {
      const port = await new Promise<string>((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error(output)), 20000);
        server.stdout.on("data", (data) => {
          output += String(data);
          const match = output.match(/RTVI_PORT=(\d+)/);
          if (match) {
            clearTimeout(timer);
            resolve(match[1]);
          }
        });
        server.on("exit", (code) => {
          clearTimeout(timer);
          reject(new Error(`server exit ${code}: ${output}`));
        });
      });
      const messages: RTVIMessage[] = [];
      const transport = new AudioFlowTransport(`ws://127.0.0.1:${port}`);
      // Observe the server wire as well as SDK callbacks; bot-tts-audio is custom media.
      const initialize = transport.initialize.bind(transport);
      transport.initialize = (options, handler) =>
        initialize(options, (message) => {
          messages.push(message);
          handler(message);
        });
      let text = "";
      const client = new PipecatClient({
        transport,
        enableMic: false,
        enableCam: false,
        callbacks: {
          onLlmRawText: (data) => {
            text += data.text;
          },
        },
      });
      const ready = await client.connect();
      assert.equal(ready.version, "2.0.0");
      assert.equal(transport.state, "ready");
      const id = await client.sendText("SDK fixture");
      assert.equal(typeof id, "string");
      await waitFor(() => messages.some((m) => m.type === "bot-tts-audio"));
      assert.equal(text, "You said: SDK fixture.");
      const audio = messages.find((m) => m.type === "bot-tts-audio")!.data as {
        audio: string;
        sample_rate: number;
      };
      assert.equal(audio.sample_rate, 16000);
      assert.equal(Buffer.from(audio.audio, "base64").length, 3200);
      transport.sendMessage(
        new RTVIMessage("update-config", {}, "unsupported"),
      );
      await waitFor(() =>
        messages.some(
          (m) => m.type === "error-response" && m.id === "unsupported",
        ),
      );
      assert.throws(() => transport.enableMic(true), /unsupported/);
      assert.throws(
        () =>
          transport.sendMessage(
            new RTVIMessage("send-text", { content: "x".repeat(64000) }),
          ),
        /limit/,
      );
      assert.equal(playback.started, 1);
      await client.disconnect();
      assert.equal(playback.stopped, 1);
      assert.equal(playback.closed, 1);
      assert.equal(transport.state, "disconnected");
      await client.connect();
      assert.equal(transport.state, "ready");
      await client.disconnect();
    } finally {
      process.kill(-server.pid!, "SIGTERM");
      await once(server, "exit");
    }
  },
);
async function waitFor(check: () => boolean) {
  for (let i = 0; i < 100; i++) {
    if (check()) return;
    await new Promise((r) => setTimeout(r, 20));
  }
  throw new Error("Timed out waiting for SDK/server event");
}
