defmodule AudioFlow.Session.Durable do
  @moduledoc false
  # The durable part of a session: the snapshot that `:on_commit` receives and
  # the `:restore` option that rebuilds a session from it.
  alias AudioFlow.Graph.Conversation
  alias AudioFlow.History

  def snapshot(state) do
    %{
      history: History.snapshot(state.history),
      conversation_state: state.conversation && state.conversation.current,
      turns: state.turns
    }
  end

  def restore(nil, state), do: state

  def restore(%{} = saved, state) do
    history = History.restore(state.history, Map.get(saved, :history, []))
    conversation = restore_conversation(state.conversation, Map.get(saved, :conversation_state))
    graph = if conversation, do: Conversation.plan(conversation), else: state.graph
    turns = Map.get(saved, :turns, 0)
    %{state | history: history, conversation: conversation, graph: graph, turns: turns}
  end

  # Only a state of this conversation can be restored.
  defp restore_conversation(nil, _name), do: nil
  defp restore_conversation(flow, nil), do: flow

  defp restore_conversation(flow, name) do
    case Enum.find(Map.keys(flow.states), &(to_string(&1) == to_string(name))) do
      nil -> raise ArgumentError, "unknown conversation state #{inspect(name)}"
      state -> %{flow | current: state}
    end
  end
end
