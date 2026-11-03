defmodule AudioFlow.Graph.Handoff do
  @moduledoc """
  Jido action for a model-selected conversation intent. Register this action in
  a chat tool profile. Graph.Runner supplies session and turn in tool context.
  The destination is allowlisted by the current conversation transition map.
  """
  use Jido.Action,
    name: "handoff",
    description: "Select the next conversation intent and transfer after this turn succeeds.",
    schema: [intent: [type: :string, required: true]]

  @impl true
  def run(%{intent: intent}, %{session: session, turn: turn}) do
    case GenServer.call(session, {:conversation_event, turn, {:intent, intent}}) do
      :ok -> {:ok, %{handoff: intent}}
      error -> error
    end
  end

  def run(_, _), do: {:error, :missing_session_context}
end
