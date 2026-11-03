# Raw PCM WebSocket transport with the synthetic Demo adapters.
# Run: mix run --no-halt examples/websocket.exs, then open http://127.0.0.1:4000.
# Hold the button to speak, or type a message. Demo replies are silent PCM.
# AUDIOFLOW_WS_PORT changes the port. Bandit is a dev and test dependency.
defmodule WebSocketExample do
  @behaviour Plug
  import Plug.Conn

  @page """
  <!doctype html>
  <meta charset="utf-8">
  <title>AudioFlow WebSocket</title>
  <button id="talk">Hold to talk</button>
  <form id="form"><input id="text" placeholder="Message"> <button>Send</button></form>
  <pre id="log"></pre>
  <script>
  const log = (line) => (document.getElementById("log").textContent += line + "\\n");
  const ws = new WebSocket(`ws://${location.host}/ws`);
  ws.binaryType = "arraybuffer";
  let player, outputRate = 16000, playAt = 0, sources = [], input, starting;

  ws.onmessage = ({ data }) => {
    if (typeof data !== "string") return play(new Int16Array(data));
    const event = JSON.parse(data);
    log(data);
    if (event.type === "output_format") outputRate = event.sample_rate;
    if (event.type === "flush") { sources.forEach((s) => s.stop()); sources = []; playAt = 0; }
  };

  function play(pcm) {
    player ??= new AudioContext();
    const buffer = player.createBuffer(1, pcm.length, outputRate);
    buffer.getChannelData(0).set(Float32Array.from(pcm, (s) => s / 32768));
    const source = player.createBufferSource();
    source.buffer = buffer;
    source.connect(player.destination);
    playAt = Math.max(playAt, player.currentTime);
    source.start(playAt);
    playAt += buffer.duration;
    sources.push(source);
    source.onended = () => (sources = sources.filter((s) => s !== source));
  }

  const worklet = `registerProcessor("pcm", class extends AudioWorkletProcessor {
    process([[channel]]) {
      if (channel) this.port.postMessage(Int16Array.from(channel, (s) =>
        Math.max(-32768, Math.min(32767, Math.round(s * 32768)))).buffer);
      return true;
    }
  });`;

  async function start() {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: { channelCount: 1 } });
    const context = new AudioContext({ sampleRate: 16000 });
    await context.audioWorklet.addModule(URL.createObjectURL(new Blob([worklet])));
    const node = new AudioWorkletNode(context, "pcm");
    node.port.onmessage = ({ data }) => ws.send(data);
    context.createMediaStreamSource(stream).connect(node);
    input = { stream, context };
  }

  function stop() {
    if (!input) return;
    input.stream.getTracks().forEach((t) => t.stop());
    input.context.close();
    input = null;
    ws.send(JSON.stringify({ type: "commit" }));
  }

  const talk = document.getElementById("talk");
  talk.onpointerdown = () => { ws.send(JSON.stringify({ type: "cancel" })); starting = start(); };
  talk.onpointerup = async () => { await starting; stop(); };
  document.getElementById("form").onsubmit = (e) => {
    e.preventDefault();
    const text = document.getElementById("text");
    ws.send(JSON.stringify({ type: "text", text: text.value }));
    text.value = "";
  };
  </script>
  """

  def init(options), do: options

  def call(%{request_path: "/ws"} = conn, _options) do
    conn
    |> WebSockAdapter.upgrade(AudioFlow.WebSocket, [session: AudioFlow.Adapters.Demo.options()],
      max_frame_size: 1_000_000
    )
    |> halt()
  end

  def call(conn, _options),
    do: conn |> put_resp_content_type("text/html") |> send_resp(200, @page)
end

port = String.to_integer(System.get_env("AUDIOFLOW_WS_PORT", "4000"))
{:ok, _} = Bandit.start_link(plug: WebSocketExample, port: port, ip: {127, 0, 0, 1})
