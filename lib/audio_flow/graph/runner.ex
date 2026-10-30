defmodule AudioFlow.Graph.Plan do
  @moduledoc "A compiled graph. Build it with `AudioFlow.Graph.session_options/2`."
  @enforce_keys [:steps, :inputs]
  defstruct [:steps, :inputs]

  @doc "The value kind of a session input."
  def input_kind(%AudioFlow.Audio{}), do: :audio
  def input_kind(%AudioFlow.Image{}), do: :image
  def input_kind(%AudioFlow.Text{}), do: :text
end

defmodule AudioFlow.Graph.Runner do
  @moduledoc """
  Runs one session turn through a compiled graph, in the turn task.

  The input goes to each input node of its kind. Only nodes with a path from
  those input nodes run. Each output goes to every target as it arrives, so a
  stream node, such as TTS, can start before the LLM finishes. A join node
  runs after all of its active sources finish. An empty joined text does not
  run the node, as an empty transcript does not run the LLM. A join node with
  several sources joins them in the order of its edges; text from different
  sources is separated by a line break. Branches run in sequence, in the order
  of the edges.

  `callbacks` has `:emit` (`fn step, value -> :ok end`, called for each node
  output) and `:context` (`fn text -> prompt end`, for the history node).
  """
  alias AudioFlow.{Adapter, Audio}
  alias AudioFlow.Graph.Plan

  def run(%Plan{} = plan, input, callbacks) do
    kind = Plan.input_kind(input)
    starts = Map.get(plan.inputs, kind, [])
    active = reach(plan, starts)

    pending =
      Map.new(active, fn id ->
        {id, plan.steps[id].sources |> Enum.filter(&MapSet.member?(active, &1)) |> MapSet.new()}
      end)

    key = make_ref()
    Process.put(key, %{pending: pending, buffers: %{}})
    run = %{plan: plan, key: key, callbacks: callbacks}

    try do
      value = input_value(input)

      for id <- starts do
        Enum.each(plan.steps[id].targets, &deliver(run, id, &1, value))
        finish(run, id)
      end

      :ok
    after
      Process.delete(key)
    end
  end

  defp input_value(%AudioFlow.Text{data: text}), do: String.trim(text)
  defp input_value(input), do: input

  defp reach(plan, ids), do: reach(plan, ids, MapSet.new())
  defp reach(_plan, [], seen), do: seen

  defp reach(plan, [id | rest], seen) do
    if MapSet.member?(seen, id),
      do: reach(plan, rest, seen),
      else: reach(plan, plan.steps[id].targets ++ rest, MapSet.put(seen, id))
  end

  defp deliver(run, source, id, value) do
    case run.plan.steps[id] do
      %{input_mode: :stream} = step ->
        run_step(run, step, value)

      _ ->
        update(run, :buffers, fn buffers ->
          Map.update(buffers, {id, source}, [value], &[value | &1])
        end)
    end
  end

  defp finish(run, id) do
    for target <- run.plan.steps[id].targets do
      update(
        run,
        :pending,
        &Map.update!(&1, target, fn sources -> MapSet.delete(sources, id) end)
      )

      if MapSet.size(state(run).pending[target]) == 0 do
        step = run.plan.steps[target]

        if step.input_mode == :join do
          {groups, buffers} =
            Enum.map_reduce(step.sources, state(run).buffers, fn source, buffers ->
              {values, buffers} = Map.pop(buffers, {target, source}, [])
              {Enum.reverse(values), buffers}
            end)

          update(run, :buffers, fn _ -> buffers end)

          case join(Enum.reject(groups, &(&1 == []))) do
            nil -> :ok
            value -> run_step(run, step, value)
          end
        end

        finish(run, target)
      end
    end
  end

  defp run_step(run, step, value) do
    value = if step.history, do: run.callbacks.context.(value), else: value

    Adapter.run(step.adapter, value, fn output ->
      :ok = run.callbacks.emit.(step, output)
      Enum.each(step.targets, &deliver(run, step.id, &1, output))
      :ok
    end)
  end

  # `groups` has the values of each source, in edge order.
  defp join([]), do: nil

  defp join([[value | _] | _] = groups) when is_binary(value) do
    text =
      groups
      |> Enum.map(&(&1 |> Enum.join("") |> String.trim()))
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    if text != "", do: text
  end

  defp join([[%Audio{sample_rate: rate} | _] | _] = groups) do
    values = List.flatten(groups)

    if Enum.any?(values, &(&1.sample_rate != rate)),
      do: raise(ArgumentError, "cannot join PCM with different sample rates")

    %Audio{data: values |> Enum.map(& &1.data) |> IO.iodata_to_binary(), sample_rate: rate}
  end

  defp join([[value]]), do: value

  defp join(_groups),
    do:
      raise(
        ArgumentError,
        "a join input accepts several text or PCM values, but only one other value"
      )

  defp state(run), do: Process.get(run.key)
  defp update(run, field, fun), do: Process.put(run.key, Map.update!(state(run), field, fun))
end
