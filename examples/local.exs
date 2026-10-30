# Benchmark config: shared models and one mono 16 kHz s16le utterance.
# Set AUDIOFLOW_ML=1, AUDIOFLOW_PCM, and AUDIOFLOW_LLM.
options = Code.eval_file(Path.join(__DIR__, "models.exs")) |> elem(0)

audio = %AudioFlow.Audio{
  data: File.read!(System.fetch_env!("AUDIOFLOW_PCM")),
  sample_rate: 16_000
}

{options, audio}
