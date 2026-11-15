# Micro-benchmarks for AudioFlow's CPU paths. No models, no network.
#
#     mix run bench/hot_paths.exs
#
# Each row is the median and p99 wall time of one call, the reductions the
# calling process spent on it, and, for audio paths, the real-time factor
# (seconds of audio handled per CPU second, higher is better).
defmodule Bench.NullDetector do
  @behaviour AudioFlow.VoiceDetector
  @impl true
  def init(options), do: {512, 16_000, Keyword.get(options, :probability, 0.0)}
  @impl true
  def predict(_audio, probability), do: {probability, probability}
end

defmodule Bench do
  alias AudioFlow.Audio

  def pcm(samples), do: :crypto.strong_rand_bytes(samples * 2)
  def audio(ms, rate), do: %Audio{data: pcm(div(ms * rate, 1000)), sample_rate: rate}

  def run(name, fun, options \\ []) do
    audio_ms = Keyword.get(options, :audio_ms)
    budget_us = Keyword.get(options, :budget_ms, 1500) * 1000
    fun.()
    {first, _} = :timer.tc(fun)
    iterations = min(20_000, max(5, div(budget_us, max(first, 1))))

    # Sessions send events to their owner, so the calls stay in this process.
    times = Enum.sort(for _ <- 1..iterations, do: elem(:timer.tc(fun), 0))
    {:reductions, before} = Process.info(self(), :reductions)
    fun.()
    {:reductions, after_call} = Process.info(self(), :reductions)
    median = Enum.at(times, div(iterations, 2))
    p99 = Enum.at(times, min(iterations - 1, trunc(iterations * 0.99)))

    factor =
      if audio_ms && median > 0,
        do: :erlang.float_to_binary(audio_ms * 1000 / median, decimals: 1) <> "x",
        else: "-"

    IO.puts(
      String.pad_trailing(name, 46) <>
        String.pad_leading("#{median}", 10) <>
        String.pad_leading("#{p99}", 10) <>
        String.pad_leading("#{after_call - before}", 12) <>
        String.pad_leading(factor, 12) <> String.pad_leading("#{iterations}", 8)
    )
  end

  def header(title) do
    IO.puts("\n== #{title}")

    IO.puts(
      String.pad_trailing("case", 46) <>
        String.pad_leading("p50 us", 10) <>
        String.pad_leading("p99 us", 10) <>
        String.pad_leading("reductions", 12) <>
        String.pad_leading("realtime", 12) <> String.pad_leading("n", 8)
    )
  end
end

alias AudioFlow.Audio
alias AudioFlow.Telephony.MuLaw
alias AudioFlow.Telephony.Packetizer
alias AudioFlow.Telephony.RateConverter

Bench.header("Telephony codec (20 ms packets)")
ulaw = :crypto.strong_rand_bytes(160)
pcm8 = Bench.pcm(160)
pcm16 = Bench.pcm(320)
{_, up} = RateConverter.up(pcm8, %RateConverter{})
{_, down} = RateConverter.down(pcm16, %RateConverter{})
Bench.run("MuLaw.decode 160 B", fn -> MuLaw.decode(ulaw) end, audio_ms: 20)
Bench.run("MuLaw.encode 160 samples", fn -> MuLaw.encode(pcm8) end, audio_ms: 20)

Bench.run("RateConverter.up 8k->16k", fn -> RateConverter.up(pcm8, up) end,
  audio_ms: 20
)

Bench.run("RateConverter.down 16k->8k", fn -> RateConverter.down(pcm16, down) end,
  audio_ms: 20
)

second16 = Bench.audio(1000, 16_000)
second8 = Bench.audio(1000, 8000)

Bench.run("Packetizer.push 1 s @16k", fn -> Packetizer.push(second16, %Packetizer{}) end,
  audio_ms: 1000
)

Bench.run("Packetizer.push 1 s @8k", fn -> Packetizer.push(second8, %Packetizer{}) end,
  audio_ms: 1000
)

Bench.header("Resampler (1 s of audio)")

for {from, to} <- [
      {48_000, 16_000},
      {24_000, 16_000},
      {8000, 16_000},
      {16_000, 24_000},
      {44_100, 16_000}
    ] do
  audio = Bench.audio(1000, from)

  Bench.run("Resampler.convert #{from}->#{to}", fn -> AudioFlow.Resampler.convert(audio, to) end,
    audio_ms: 1000
  )
end

Bench.header("VoiceInput (null detector, 512-sample frames)")
chunk20 = %Audio{data: Bench.pcm(320), sample_rate: 16_000}
silent = AudioFlow.VoiceInput.new({Bench.NullDetector, [probability: 0.0]})
speech = AudioFlow.VoiceInput.new({Bench.NullDetector, [probability: 1.0]})

feed = fn state, count ->
  Enum.reduce(1..count, state, fn _, state ->
    elem(AudioFlow.VoiceInput.push(state, chunk20), 1)
  end)
end

Bench.run("push 1 s silence in 20 ms chunks", fn -> feed.(silent, 50) end, audio_ms: 1000)
Bench.run("push 1 s speech in 20 ms chunks", fn -> feed.(speech, 50) end, audio_ms: 1000)
Bench.run("push 10 s speech in 20 ms chunks", fn -> feed.(speech, 500) end, audio_ms: 10_000)
big = %Audio{data: Bench.pcm(16_000 * 10), sample_rate: 16_000}

Bench.run("push 10 s speech as one chunk", fn -> AudioFlow.VoiceInput.push(speech, big) end,
  audio_ms: 10_000
)

long = feed.(speech, 1400)
Bench.run("flush a 28 s utterance", fn -> AudioFlow.VoiceInput.flush(long) end)

Bench.header("Text")

tokens =
  for i <- 1..400,
      do:
        Enum.at(
          ["The ", "quick ", "fox. ", "Dr. ", "Smith ", "said: ", "\"yes!\" ", "and "],
          rem(i, 8)
        )

stream = fn ->
  Enum.reduce(tokens, "", fn token, pending ->
    elem(AudioFlow.TextChunks.push(pending, token), 1)
  end)
end

Bench.run("TextChunks.push 400 tokens", stream)
no_break = for _ <- 1..400, do: "word "

Bench.run("TextChunks.push 400 tokens, no sentence end", fn ->
  Enum.reduce(no_break, "", fn token, pending ->
    elem(AudioFlow.TextChunks.push(pending, token), 1)
  end)
end)

history =
  Enum.reduce(1..8, AudioFlow.History.new(true), fn i, history ->
    {:ok, _, context} =
      AudioFlow.History.prompt(history, "question #{i} " <> String.duplicate("x", 200))

    {:ok, context} = AudioFlow.History.append(context, String.duplicate("y", 600))
    AudioFlow.History.commit(context)
  end)

Bench.run("History.prompt with 8 turns", fn ->
  AudioFlow.History.prompt(history, "next question")
end)

Bench.header("Session (in-process adapters)")
owner_options = fn options -> Keyword.put(options, :owner, self()) end

drain = fn session, turn ->
  receive_loop = fn loop ->
    receive do
      {AudioFlow, ^session, ^turn, {:done, _}} -> :ok
      {AudioFlow, ^session, ^turn, {:error, reason, _}} -> raise inspect(reason)
      {AudioFlow, ^session, ^turn, _} -> loop.(loop)
    end
  end

  receive_loop.(receive_loop)
end

input = %Audio{data: <<0, 0>>, sample_rate: 16_000}

Bench.run("start_session + stop_session", fn ->
  {:ok, session} = AudioFlow.start_session(owner_options.(AudioFlow.Adapters.Demo.options()))
  AudioFlow.stop_session(session)
end)

{:ok, demo} = AudioFlow.start_session(AudioFlow.Adapters.Demo.options())

Bench.run("demo turn on a warm session", fn ->
  {:ok, turn} = AudioFlow.submit(demo, input)
  drain.(demo, turn)
end)

function = fn run -> {AudioFlow.Adapters.Function, [run: run]} end
frame = %Audio{data: Bench.pcm(480), sample_rate: 24_000}

streaming = fn chunks, sentences ->
  [
    stt: function.(fn _, emit -> emit.("hello") end),
    llm: function.(fn _, emit -> Enum.each(1..sentences, fn _ -> emit.("A sentence. ") end) end),
    tts: function.(fn _, emit -> Enum.each(1..chunks, fn _ -> emit.(frame) end) end),
    max_events: 100_000
  ]
end

for {sentences, chunks} <- [{1, 50}, {10, 50}, {10, 100}] do
  {:ok, session} = AudioFlow.start_session(streaming.(chunks, sentences))

  Bench.run(
    "turn: #{sentences} sentences x #{chunks} audio frames (20 ms)",
    fn ->
      {:ok, turn} = AudioFlow.submit(session, input)
      drain.(session, turn)
    end,
    audio_ms: sentences * chunks * 20
  )
end

{:ok, with_history} =
  AudioFlow.start_session(Keyword.put(streaming.(50, 10), :history, true))

Bench.run(
  "turn: 10 x 50 frames, history on",
  fn ->
    {:ok, turn} = AudioFlow.submit(with_history, input)
    drain.(with_history, turn)
  end,
  audio_ms: 10_000
)

Bench.header("Telephony WebSocket endpoint (Twilio, inbound 20 ms frames)")

{:ok, socket} =
  AudioFlow.Telephony.WebSocket.init(
    provider: :twilio,
    session: AudioFlow.Adapters.Demo.options(),
    vad: {Bench.NullDetector, [probability: 0.0]}
  )

start =
  JSON.encode!(%{
    event: "start",
    streamSid: "MZ1",
    start: %{
      streamSid: "MZ1",
      mediaFormat: %{encoding: "audio/x-mulaw", sampleRate: 8000, channels: 1}
    }
  })

{:ok, socket} = AudioFlow.Telephony.WebSocket.handle_in({start, opcode: :text}, socket)

media = fn chunk ->
  JSON.encode!(%{
    event: "media",
    streamSid: "MZ1",
    media: %{track: "inbound", chunk: chunk, payload: Base.encode64(ulaw)}
  })
end

frames = for chunk <- 1..50, do: {media.(chunk), opcode: :text}

Bench.run(
  "handle_in 1 s of inbound media (50 frames)",
  fn ->
    Enum.reduce(frames, %{socket | last_chunk: nil}, fn message, state ->
      {:ok, state} = AudioFlow.Telephony.WebSocket.handle_in(message, state)
      state
    end)
  end,
  audio_ms: 1000
)

Bench.header("Recording")
store_root = Path.join(System.tmp_dir!(), "audioflow-bench-#{System.unique_integer([:positive])}")
{:ok, store} = AudioFlow.Recording.Store.new(store_root)
recorder = AudioFlow.Recording.new(self(), store, redactor: &{:ok, &1}, audio: true)
turn = make_ref()
second = Bench.audio(1000, 24_000)

Bench.run(
  "consume 1 s audio event (base64)",
  fn ->
    AudioFlow.Recording.consume(recorder, {AudioFlow, self(), turn, {:audio, second}})
  end, audio_ms: 1000)

File.rm_rf!(store_root)
