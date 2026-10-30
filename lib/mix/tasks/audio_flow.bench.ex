defmodule Mix.Tasks.AudioFlow.Bench do
  @shortdoc "Measure turn latency; use --config for real inference"
  @moduledoc """
  mix audio_flow.bench [--config path.exs] [--runs 10] [--concurrency 1]
    [--warmup 0] [--timeout-ms 35000] [--output results.csv]

  Config scripts return `{session_options, audio}` or
  `{session_options, audio, metadata}`. They may start shared models.
  Without a config, the run measures synthetic orchestration only.
  --output writes clean CSV and a .meta.json sidecar. Warmup rows and errors
  are retained. Without --output, CSV goes to stdout with any model logs.
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          config: :string,
          runs: :integer,
          concurrency: :integer,
          warmup: :integer,
          timeout_ms: :integer,
          output: :string
        ]
      )

    if rest != [] or invalid != [], do: Mix.raise("invalid benchmark arguments")
    runs = Keyword.get(opts, :runs, 10)
    concurrency = Keyword.get(opts, :concurrency, 1)
    warmup = Keyword.get(opts, :warmup, 0)

    if runs < 1 or concurrency < 1 or warmup < 0 or (opts[:timeout_ms] && opts[:timeout_ms] < 1),
      do:
        Mix.raise("runs, concurrency, and timeout must be positive; warmup must be non-negative")

    Mix.Task.run("app.start")
    setup_started = System.monotonic_time(:microsecond)

    {options, audio, config_metadata} =
      case opts[:config] do
        nil ->
          IO.puts(:stderr, "Synthetic benchmark. These results do not measure speech inference.")

          {AudioFlow.Adapters.Demo.options(),
           %AudioFlow.Audio{data: <<0, 0>>, sample_rate: 16_000}, %{mode: "synthetic"}}

        path ->
          case elem(Code.eval_file(path), 0) do
            {options, audio} ->
              {options, audio, %{config_file: path}}

            {options, audio, metadata} ->
              {options, audio, metadata}

            _ ->
              Mix.raise(
                "benchmark config must return {options, audio} or {options, audio, metadata}"
              )
          end
      end

    unless AudioFlow.Audio.valid?(audio),
      do: Mix.raise("benchmark input must be valid mono s16le PCM")

    setup_us = System.monotonic_time(:microsecond) - setup_started

    benchmark_options = Keyword.take(opts, [:warmup, :timeout_ms])
    rows = AudioFlow.Benchmark.run(options, audio, runs, concurrency, benchmark_options)
    csv = AudioFlow.BenchmarkReport.csv(rows)

    settings = %{
      runs: runs,
      concurrency: concurrency,
      warmup: warmup,
      timeout_ms:
        Keyword.get(
          benchmark_options,
          :timeout_ms,
          Keyword.get(options, :timeout_ms, 30_000) + 5000
        )
    }

    metadata =
      AudioFlow.BenchmarkReport.metadata(audio, settings, config_metadata)
      |> Map.put(:setup_us, setup_us)

    case opts[:output] do
      nil ->
        IO.write(csv)

      path ->
        json = JSON.encode!(metadata)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, csv)
        File.write!(path <> ".meta.json", json)
        IO.puts("Wrote #{path} and #{path}.meta.json")
    end
  end
end
