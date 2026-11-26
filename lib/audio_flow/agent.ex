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

  @doc "The agent module of a call record. Only loaded modules are accepted."
  def module(%{agent: name}) when is_binary(name) do
    module = String.to_existing_atom(name)

    if Code.ensure_loaded?(module) and function_exported?(module, :session_options, 1),
      do: {:ok, module},
      else: {:error, {:unknown_agent, name}}
  rescue
    ArgumentError -> {:error, {:unknown_agent, name}}
  end
end
