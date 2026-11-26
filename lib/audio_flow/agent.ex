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
  The agent module of a call record. The name must be a module on the code
  path that implements this behaviour; a name from storage never creates
  other atoms.
  """
  def module(%{agent: name}) when is_binary(name) do
    with true <- String.starts_with?(name, "Elixir."),
         path when is_list(path) <- :code.where_is_file(String.to_charlist(name <> ".beam")),
         module = String.to_atom(name),
         true <- Code.ensure_loaded?(module) and function_exported?(module, :session_options, 1) do
      {:ok, module}
    else
      _ -> {:error, {:unknown_agent, name}}
    end
  end
end
