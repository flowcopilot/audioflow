defmodule AudioFlow.Agent do
  @moduledoc """
  An agent definition for durable calls. A call record stores the module
  name, not the session options: options hold functions and PIDs, which do
  not survive a restart. Any node can start the call again from the record
  (similar to the LiveKit agent `entrypoint`).

  `session_options/1` gets the call map (`:id`, `:room`, `:metadata`) and
  returns `AudioFlow.Session` options. History must be enabled for the
  history to be saved. `participant_options/1` returns
  `AudioFlow.SFU.Participant` options other than the session, such as `:vad`
  and `:voice_input`.
  """
  @callback session_options(call :: map()) :: keyword()
  @callback participant_options(call :: map()) :: keyword()

  @doc """
  The agent module of a call record: a loaded module, or one on the code
  path, that implements this behaviour. A name from storage never creates
  atoms for other names.
  """
  def module(%{agent: "Elixir." <> _ = name}) do
    with {:ok, module} <- existing(name),
         true <- Code.ensure_loaded?(module) and function_exported?(module, :session_options, 1) do
      {:ok, module}
    else
      _ -> {:error, {:unknown_agent, name}}
    end
  end

  def module(%{agent: name}), do: {:error, {:unknown_agent, name}}

  defp existing(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError ->
      case :code.where_is_file(String.to_charlist(name <> ".beam")) do
        path when is_list(path) -> {:ok, String.to_atom(name)}
        :non_existing -> :error
      end
  end
end
