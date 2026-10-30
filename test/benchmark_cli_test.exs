defmodule AudioFlow.BenchmarkCLITest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  @tag :tmp_dir
  test "CSV output keeps errors and metadata separate from logs", %{tmp_dir: tmp_dir} do
    config = Path.join(tmp_dir, "config.exs")
    output = Path.join(tmp_dir, "result.csv")

    File.write!(config, """
    {Keyword.put(AudioFlow.Adapters.Demo.options(), :max_input_bytes, 1),
     %AudioFlow.Audio{data: <<0, 0>>, sample_rate: 16000}, %{label: "failure,test"}}
    """)

    capture_io(fn ->
      Mix.Tasks.AudioFlow.Bench.run([
        "--config",
        config,
        "--output",
        output,
        "--runs",
        "2",
        "--warmup",
        "1"
      ])
    end)

    [header, warmup, first, second] = File.read!(output) |> String.split("\n", trim: true)

    assert header ==
             "phase,run,status,concurrency,duration_us,first_transcript_us,first_text_us,first_audio_us,error"

    assert String.starts_with?(warmup, "warmup,1,error,1,")
    assert String.starts_with?(first, "measured,1,error,1,")
    assert String.starts_with?(second, "measured,2,error,1,")
    assert String.ends_with?(first, ",\"{:submit, :input_too_large}\"")
    metadata = File.read!(output <> ".meta.json") |> JSON.decode!()
    assert metadata["config"]["label"] == "failure,test"

    assert metadata["audio"]["sha256"] ==
             "96a296d224f285c67bee93c30f8a309157f0daa35dc5b87e410b78630a09cfc7"

    assert metadata["options"]["runs"] == 2
    assert metadata["options"]["warmup"] == 1
    assert is_integer(metadata["setup_us"]) and metadata["setup_us"] >= 0
  end
end
