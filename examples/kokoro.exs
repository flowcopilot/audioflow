# AUDIOFLOW_ML=1 mix run examples/kokoro.exs "Hello from AudioFlow." output.wav
# Requires espeak-ng. Writes a WAV file; it does not open a playback device.
text = List.first(System.argv(), "Hello from AudioFlow.")
path = Enum.at(System.argv(), 1, Path.join(System.tmp_dir!(), "audioflow-kokoro.wav"))
voice = System.get_env("AUDIOFLOW_VOICE", "af_heart")
serving = AudioFlow.Kokoro.serving(voices: [voice])

{:ok, _} =
  Supervisor.start_link(
    [
      AudioFlow.Models.child_spec(AudioFlow.KokoroDemo, serving)
    ],
    strategy: :one_for_one
  )

pcm =
  Nx.Serving.batched_run(AudioFlow.KokoroDemo, text)
  |> AudioFlow.Kokoro.audio()
  |> Enum.map_join(& &1.data)

header =
  <<"RIFF", byte_size(pcm) + 36::little-32, "WAVEfmt ", 16::little-32, 1::little-16, 1::little-16,
    24_000::little-32, 48_000::little-32, 2::little-16, 16::little-16, "data",
    byte_size(pcm)::little-32>>

File.write!(path, header <> pcm)
IO.puts("Wrote #{path}")
