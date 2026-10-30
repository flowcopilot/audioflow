# Sequential recorded turns on one session with shared native or HTTP models.
# Requires AUDIOFLOW_ML=1, AUDIOFLOW_HISTORY=1, and AUDIOFLOW_LLM.
# Usage: mix run examples/conversation.exs OUTPUT_DIR FIRST.s16le SECOND.s16le
# Inputs are mono 16 kHz s16le. Outputs are PCM plus JSON metadata. No sound device opens.
if System.get_env("AUDIOFLOW_HISTORY") != "1", do: raise("Set AUDIOFLOW_HISTORY=1")
[output_dir | [_ | _] = inputs] = System.argv()
{options, model_metadata} = Code.eval_file(Path.join(__DIR__, "models.exs")) |> elem(0)
{:ok, session} = AudioFlow.start_session(options)
File.mkdir_p!(output_dir)

collect = fn collect, turn, state ->
  receive do
    {AudioFlow, ^session, ^turn, {kind, text}} when kind in [:transcript, :text] ->
      collect.(collect, turn, Map.update!(state, kind, &[text | &1]))

    {AudioFlow, ^session, ^turn, {:audio, audio}} ->
      if state.sample_rate != nil and state.sample_rate != audio.sample_rate,
        do: raise("Output sample rate changed within a turn")

      collect.(collect, turn, %{
        state
        | pcm: [audio.data | state.pcm],
          sample_rate: audio.sample_rate
      })

    {AudioFlow, ^session, ^turn, {:done, metrics}} ->
      Map.put(state, :metrics, metrics)

    {AudioFlow, ^session, ^turn, {:error, reason, _}} ->
      raise "Turn failed: #{inspect(reason)}"

    {AudioFlow, ^session, ^turn, {:cancelled, _}} ->
      raise "Turn cancelled"
  after
    125_000 -> raise "Turn timed out"
  end
end

try do
  for {path, index} <- Enum.with_index(inputs, 1) do
    {:ok, turn} =
      AudioFlow.submit(session, %AudioFlow.Audio{data: File.read!(path), sample_rate: 16_000})

    state = collect.(collect, turn, %{transcript: [], text: [], pcm: [], sample_rate: nil})
    pcm = state.pcm |> Enum.reverse() |> IO.iodata_to_binary()
    reply = state.text |> Enum.reverse() |> Enum.join("")

    metadata = %{
      models: model_metadata,
      metrics: state.metrics,
      sample_rate: state.sample_rate,
      transcript: state.transcript |> Enum.reverse() |> Enum.join(""),
      reply: reply,
      bytes: byte_size(pcm)
    }

    File.write!(Path.join(output_dir, "#{index}.s16le"), pcm)
    File.write!(Path.join(output_dir, "#{index}.json"), JSON.encode!(metadata))
    IO.puts("Turn #{index}: #{reply}")
  end
after
  AudioFlow.stop_session(session)
end
