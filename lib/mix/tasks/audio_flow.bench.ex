defmodule Mix.Tasks.AudioFlow.Bench do
  @shortdoc "Measure turn latency; use --config for real inference"
  @moduledoc """
  mix audio_flow.bench [--config path.exs] [--runs 10] [--concurrency 1]

  Config scripts return `{session_options, %AudioFlow.Audio{}}`. They may start
  shared model services before returning. Without a config, this measures
  synthetic orchestration only. CSV is written to standard output.
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [config: :string, runs: :integer, concurrency: :integer])

    if rest != [] or invalid != [], do: Mix.raise("invalid benchmark arguments")
    runs = Keyword.get(opts, :runs, 10)
    concurrency = Keyword.get(opts, :concurrency, 1)
    if runs < 1 or concurrency < 1, do: Mix.raise("runs and concurrency must be positive")
    Mix.Task.run("app.start")

    {options, audio} =
      case opts[:config] do
        nil ->
          IO.puts(:stderr, "Synthetic benchmark. These results do not measure speech inference.")

          {AudioFlow.Adapters.Demo.options(),
           %AudioFlow.Audio{data: <<0, 0>>, sample_rate: 16_000}}

        path ->
          elem(Code.eval_file(path), 0)
      end

    IO.puts("run,status,concurrency,duration_us,first_transcript_us,first_text_us,first_audio_us")

    for result <- AudioFlow.Benchmark.run(options, audio, runs, concurrency) do
      status = if result.status == :ok, do: "ok", else: "error"
      if status == "error", do: IO.puts(:stderr, inspect(result.status))

      IO.puts(
        Enum.join(
          [
            result.run,
            status,
            concurrency,
            result.duration_us,
            result.first_transcript_us,
            result.first_text_us,
            result.first_audio_us
          ],
          ","
        )
      )
    end
  end
end
