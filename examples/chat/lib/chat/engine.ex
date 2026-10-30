defmodule Chat.Engine do
  @moduledoc """
  Loads the shared models once, at startup, through `examples/models.exs`.

  Defaults: Whisper tiny for speech recognition, `Qwen/Qwen3-0.6B` for replies,
  and Kokoro for speech, with conversation history. The environment variables
  that `examples/models.exs` reads override these defaults. For example, set
  `AUDIOFLOW_LLM_ENGINE=http` and `AUDIOFLOW_CHAT_ENDPOINT` to use a chat server.
  """
  use GenServer

  @models Path.expand("../../../models.exs", __DIR__)
  @defaults %{"AUDIOFLOW_LLM" => "Qwen/Qwen3-0.6B", "AUDIOFLOW_HISTORY" => "1"}

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Session options and a short label for the loaded models."
  def session, do: :persistent_term.get(__MODULE__)

  @impl true
  def init(nil) do
    for {name, value} <- @defaults, System.get_env(name) == nil, do: System.put_env(name, value)

    # models.exs links its model supervisor to this process.
    {options, metadata} = Code.eval_file(@models) |> elem(0)
    llm = metadata.llm[:repository] || metadata.llm[:model]
    :persistent_term.put(__MODULE__, {options, "whisper-tiny · #{llm} · #{metadata.tts.engine}"})
    {:ok, nil}
  end
end
