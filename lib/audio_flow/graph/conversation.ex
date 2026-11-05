defmodule AudioFlow.Graph.Conversation do
  @moduledoc """
  Conversation states over independently validated DAGs. Transitions may cycle;
  graph edges may not. Events are explicit classified intents or tool results,
  never guesses from generated text. Each state selects a complete graph (and
  therefore its prompt and tools). The session, owner, transport and history stay.

  Jido's FSM strategy controls instruction execution phases, not conversation
  states. This layer composes with Jido actions through `event/2` and `tool/3`
  without changing the execution-phase strategy or running inference itself.
  """
  @enforce_keys [:states, :current, :transitions]
  defstruct @enforce_keys

  def new(states, initial, transitions, catalog \\ AudioFlow.Graph.catalog()) do
    unless is_map(states) and map_size(states) > 0 and Map.has_key?(states, initial),
      do: raise(ArgumentError, "initial state must name a graph")

    plans = Map.new(states, fn {name, graph} -> {name, state_plan(name, graph, catalog)} end)

    unless is_map(transitions) and Enum.all?(transitions, &valid_transition?(&1, states)),
      do: raise(ArgumentError, "transitions must map {state, event} to an existing state")

    %__MODULE__{states: plans, current: initial, transitions: transitions}
  end

  defp state_plan(name, graph, catalog) do
    case AudioFlow.Graph.session_options(graph, catalog) do
      {:ok, options} ->
        unless Keyword.get(options, :history, false),
          do: raise(ArgumentError, "conversation graphs require history")

        Keyword.fetch!(options, :graph)

      {:error, errors} ->
        raise ArgumentError, "state #{inspect(name)}: #{Enum.join(errors, "; ")}"
    end
  end

  defp valid_transition?({{from, _event}, to}, states),
    do: Map.has_key?(states, from) and Map.has_key?(states, to)

  defp valid_transition?(_, _states), do: false

  def plan(%__MODULE__{} = flow), do: Map.fetch!(flow.states, flow.current)

  def transition(%__MODULE__{} = flow, event) do
    case Map.fetch(flow.transitions, {flow.current, event}) do
      {:ok, next} -> {:ok, %{flow | current: next}}
      :error -> {:error, :invalid_transition}
    end
  end

  @doc "Starts one ordinary AudioFlow session, with history enabled."
  def start_session(%__MODULE__{} = flow, options \\ []) do
    options = Keyword.drop(options, [:graph, :conversation])

    AudioFlow.start_session(
      Keyword.merge(options, conversation: flow, graph: plan(flow), history: true)
    )
  end

  @doc "During a turn, transitions commit only if that turn succeeds; otherwise immediately."
  def event(session, event), do: GenServer.call(session, {:conversation_event, event})
  def state(session), do: GenServer.call(session, :conversation_state)

  @doc "A tool that stages an explicit handoff. Also usable beside Jido action tools."
  def tool(session, name, event) do
    AudioFlow.Tool.new(%{
      name: name,
      description: "Transfer the conversation to #{name}",
      run: fn _arguments ->
        case event(session, event) do
          :ok -> {:ok, %{handoff: name}}
          error -> error
        end
      end
    })
  end
end
