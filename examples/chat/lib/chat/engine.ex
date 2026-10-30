defmodule Chat.Engine do
  @moduledoc """
  Builds the AudioFlow session options once, at startup.

  * `AUDIOFLOW_ML=1` loads Whisper, the language model, and Kokoro or VITS
    through `examples/models.exs`. Its environment variables apply.
  * `AUDIOFLOW_CHAT_ENDPOINT` uses an OpenAI-compatible chat server for text.
    `AUDIOFLOW_LLM` names its model.
  * Otherwise the example uses an echo reply. No model is downloaded.

  Without `AUDIOFLOW_ML=1`, speech recognition returns a fixed transcript and
  speech output is a short tone per sentence. These check the audio path only.
  """
  use GenServer

  alias AudioFlow.Adapters.{ChatHTTP, Function}
  alias AudioFlow.Audio

  @models Path.expand("../../../models.exs", __DIR__)

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Session options and a short label for the active engine."
  def session, do: :persistent_term.get(__MODULE__)

  @impl true
  def init(nil) do
    # models.exs links its model supervisor to this process.
    :persistent_term.put(__MODULE__, build())
    {:ok, nil}
  end

  defp build do
    cond do
      System.get_env("AUDIOFLOW_ML") == "1" ->
        {options, metadata} = Code.eval_file(@models) |> elem(0)
        {options, "#{metadata.mode}: #{metadata.llm[:repository] || metadata.llm[:model]}"}

      endpoint = System.get_env("AUDIOFLOW_CHAT_ENDPOINT") ->
        llm =
          {ChatHTTP,
           endpoint: endpoint,
           model: System.fetch_env!("AUDIOFLOW_LLM"),
           api_key: api_key(),
           parameters: %{max_tokens: 256}}

        {demo(llm), "http: #{System.fetch_env!("AUDIOFLOW_LLM")}"}

      true ->
        {demo({Function, run: &echo/2}), "demo echo"}
    end
  end

  defp demo(llm) do
    [
      stt: {Function, run: fn _audio, emit -> emit.("Hello from the microphone.") end},
      llm: llm,
      tts: {Function, run: fn _text, emit -> emit.(tone()) end},
      history: true,
      timeout_ms: 120_000
    ]
  end

  defp api_key do
    if System.get_env("AUDIOFLOW_CHAT_API_KEY"),
      do: fn -> System.fetch_env!("AUDIOFLOW_CHAT_API_KEY") end
  end

  defp echo(messages, emit) do
    emit.("You said: #{List.last(messages).content}")
  end

  # 0.2 seconds of a quiet 440 Hz tone at 16 kHz.
  defp tone do
    data =
      for i <- 0..3199, into: <<>> do
        sample = round(4000 * :math.sin(2 * :math.pi() * 440 * i / 16_000))
        <<sample::signed-little-16>>
      end

    %Audio{data: data, sample_rate: 16_000}
  end
end
