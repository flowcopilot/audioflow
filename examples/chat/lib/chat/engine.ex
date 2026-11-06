defmodule Chat.Engine do
  @moduledoc "Profile boundary: only native builds start model processes."
  @compile {:no_warn_undefined, Chat.LocalEngine}
  def native?, do: Application.fetch_env!(:chat, :native_profile)

  def child_spec(_) do
    if native?(),
      do: %{
        id: __MODULE__,
        start:
          {Supervisor, :start_link,
           [[AudioFlow.Servings, Chat.LocalEngine], [strategy: :one_for_one]]}
      },
      else: %{id: __MODULE__, start: {Agent, :start_link, [fn -> nil end]}}
  end

  def topic, do: "models"

  def status do
    if native?(),
      do: Chat.LocalEngine.status(),
      else: %{
        selection: Chat.Catalog.defaults(),
        status: %{},
        memory_gb: 0
      }
  end

  def select(stage, id),
    do:
      if(native?(),
        do: Chat.LocalEngine.select(stage, id),
        else: {:error, :native_profile_required}
      )

  def adapter(stage), do: if(native?(), do: Chat.LocalEngine.adapter(stage))

  def transcribe(audio),
    do: if(native?(), do: Chat.LocalEngine.transcribe(audio), else: {:error, :synthetic_demo})
end
