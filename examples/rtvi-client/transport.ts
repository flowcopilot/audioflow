import {
  Transport,
  RTVIMessage,
  type PipecatClientOptions,
  type TransportState,
  type Tracks,
} from "@pipecat-ai/client-js";

/** Text input and PCM audio output. No microphone, camera or WebRTC support. */
export class AudioFlowTransport extends Transport {
  private socket?: WebSocket;
  private audio?: AudioContext;
  private sources = new Set<AudioBufferSourceNode>();
  private nextAudio = 0;
  private ready?: {
    id: string;
    resolve: () => void;
    reject: (error: Error) => void;
  };
  private readyTimer?: ReturnType<typeof setTimeout>;
  constructor(
    private readonly url: string,
    private readonly playback = true,
  ) {
    super();
  }
  initialize(
    options: PipecatClientOptions,
    handler: (message: RTVIMessage) => void,
  ) {
    this._options = options;
    this._callbacks = options.callbacks ?? {};
    this._onMessage = handler;
  }
  async initDevices() {
    this.state = "initializing";
    if (this.playback) {
      this.audio = new AudioContext();
      await this.audio.resume(); // Call connect() from a user gesture.
    }
    this.state = "initialized";
  }
  _validateConnectionParams(params?: unknown) {
    if (params !== undefined)
      throw new Error("Pass the WebSocket URL to the constructor");
    if (!/^wss?:\/\//.test(this.url))
      throw new Error("Expected ws:// or wss:// URL");
    return params;
  }
  async _connect() {
    if (this.playback && !this.audio) await this.initDevices();
    this.state = "connecting";
    await new Promise<void>((resolve, reject) => {
      const socket = (this.socket = new WebSocket(this.url));
      const timeout = setTimeout(() => {
        reject(new Error("WebSocket connect timeout"));
        socket.close();
      }, 10_000);
      socket.onopen = () => {
        clearTimeout(timeout);
        this.state = "connected";
        this._callbacks.onConnected?.();
        resolve();
      };
      socket.onerror = (event) => {
        clearTimeout(timeout);
        reject(
          new Error(
            "WebSocket connection failed: " + (event as ErrorEvent).message,
          ),
        );
      };
      socket.onclose = () => {
        clearTimeout(timeout);
        if (this.socket !== socket) return;
        reject(new Error("WebSocket closed before connecting"));
        this.rejectReady(new Error("WebSocket closed"));
        this.stopAudio();
        void this.audio?.close();
        this.audio = undefined;
        this.state = "disconnected";
        this._callbacks.onDisconnected?.();
      };
      socket.onmessage = (event) => {
        if (this.socket !== socket) return;
        try {
          const message = JSON.parse(String(event.data)) as RTVIMessage;
          if (message.label !== "rtvi-ai" || typeof message.type !== "string")
            throw new Error("Invalid RTVI message");
          if (
            message.type === "bot-ready" &&
            this.ready &&
            message.id === this.ready.id
          ) {
            this.state = "ready";
            clearTimeout(this.readyTimer);
            this.ready?.resolve();
            this.ready = undefined;
          }
          if (
            message.type === "error-response" &&
            this.ready &&
            message.id === this.ready.id
          ) {
            const data = message.data as { error?: unknown } | undefined;
            this.rejectReady(
              new Error(String(data?.error ?? "RTVI negotiation failed")),
            );
          }
          if (message.type === "bot-interrupted") this.stopAudio();
          if (message.type === "bot-tts-audio" && this.playback)
            this.play(message.data);
          this._onMessage(message);
        } catch (error) {
          this._callbacks.onError?.(RTVIMessage.error(String(error), true));
          void this.disconnect();
        }
      };
    });
  }
  sendReadyMessage(): Promise<void> {
    return new Promise((resolve, reject) => {
      const message = RTVIMessage.clientReady();
      this.ready = { id: message.id, resolve, reject };
      this.readyTimer = setTimeout(() => {
        this.rejectReady(new Error("bot-ready timeout"));
        void this.disconnect();
      }, 10_000);
      try {
        this.sendMessage(message);
      } catch (error) {
        this.rejectReady(
          error instanceof Error ? error : new Error(String(error)),
        );
      }
    });
  }
  private rejectReady(error: Error) {
    clearTimeout(this.readyTimer);
    this.ready?.reject(error);
    this.ready = undefined;
  }
  async _disconnect() {
    this.rejectReady(new Error("Disconnected"));
    this.stopAudio();
    this.socket?.close();
    this.socket = undefined;
    await this.audio?.close();
    this.audio = undefined;
    this.state = "disconnected";
    this._callbacks.onDisconnected?.();
  }
  sendMessage(message: RTVIMessage) {
    const encoded = JSON.stringify(message);
    if (new TextEncoder().encode(encoded).length > 64_000)
      throw new Error("Message exceeds server limit");
    if (this.socket?.readyState !== WebSocket.OPEN)
      throw new Error("Socket is not connected");
    this.socket.send(encoded);
  }
  private play(value: unknown) {
    const data = value as {
      audio: string;
      sample_rate: number;
      num_channels: number;
    };
    if (
      !this.audio ||
      data.num_channels !== 1 ||
      !Number.isInteger(data.sample_rate) ||
      data.sample_rate < 8000 ||
      data.sample_rate > 192000
    )
      throw new Error("Invalid audio format");
    const bytes = Uint8Array.from(atob(data.audio), (c) => c.charCodeAt(0));
    if (bytes.length % 2 || this.nextAudio - this.audio.currentTime > 10)
      throw new Error("Audio limit exceeded");
    if (!bytes.length) return;
    const buffer = this.audio.createBuffer(
      1,
      bytes.length / 2,
      data.sample_rate,
    );
    const view = new DataView(bytes.buffer),
      samples = buffer.getChannelData(0);
    for (let i = 0; i < samples.length; i++)
      samples[i] = view.getInt16(i * 2, true) / 32768;
    const source = this.audio.createBufferSource();
    source.buffer = buffer;
    source.connect(this.audio.destination);
    this.sources.add(source);
    source.onended = () => {
      this.sources.delete(source);
      source.disconnect();
    };
    const start = Math.max(this.nextAudio, this.audio.currentTime);
    source.start(start);
    this.nextAudio = start + buffer.duration;
  }
  private stopAudio() {
    for (const source of this.sources) {
      source.stop();
      source.disconnect();
    }
    this.sources.clear();
    this.nextAudio = 0;
  }
  get state() {
    return this._state;
  }
  set state(value: TransportState) {
    if (this._state !== value) {
      this._state = value;
      this._callbacks.onTransportStateChanged?.(value);
    }
  }
  get mediaSupport() {
    return {
      mic: false,
      cam: false,
      screenShare: false,
      botAudio: this.playback,
      botVideo: false,
    };
  }
  get maxMessageSize() {
    return 64_000;
  }
  async getAllMics() {
    return [];
  }
  async getAllCams() {
    return [];
  }
  async getAllSpeakers() {
    return [];
  }
  get selectedMic() {
    return {};
  }
  get selectedCam() {
    return {};
  }
  get selectedSpeaker() {
    return {};
  }
  updateMic(_id: string) {
    throw new Error("Microphone unsupported");
  }
  updateCam(_id: string) {
    throw new Error("Camera unsupported");
  }
  updateSpeaker(_id: string) {
    throw new Error("Uses browser default audio output");
  }
  enableMic(value: boolean) {
    if (value) throw new Error("Microphone unsupported");
  }
  enableCam(value: boolean) {
    if (value) throw new Error("Camera unsupported");
  }
  enableScreenShare(value: boolean) {
    if (value) throw new Error("Screen share unsupported");
  }
  get isMicEnabled() {
    return false;
  }
  get isCamEnabled() {
    return false;
  }
  get isSharingScreen() {
    return false;
  }
  tracks(): Tracks {
    return { local: {} };
  }
}
