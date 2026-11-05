defmodule AudioFlow.Evaluation.Conversation do
  @moduledoc """
  Scripted ExUnit assertions against a real session owned by the calling test.

  `run!/3` submits text turns sequentially and waits for each terminal event.
  Each step is a map with `:input`, optional `:reply` (exact string, regex, or
  predicate), and optional `:tools` (an exact ordered list of `{name, arguments}`).
  Results contain `:reply`, `:tools`, `:events`, `:metrics`, and `:turn`.

  Use `observe_tools/1` before starting the session and pass its reference as
  `observer: ref`. Wrapped tools execute their original function or Jido action
  with the original context. Only actual invocations are observed; malformed or
  unknown calls rejected by an adapter are not invocations. This helper does
  not simulate inference, judge acoustic quality, or supply a simulated user.

  Enable session history explicitly for conversations that need it. For graphs
  with several text outputs, use `node: "reply-node"` to select the reply.
  The default timeout is 5 seconds per turn (not per event). A timeout cancels
  the active turn. The caller owns session startup and cleanup.
  """
  alias AudioFlow.Text
  alias AudioFlow.Tool

  @doc "Wrap tool definitions, returning `{tools, observer_reference}` for this process."
  def observe_tools(definitions) do
    owner = self()
    ref = make_ref()

    tools =
      Enum.map(definitions, fn definition ->
        tool = Tool.new(definition)
        original = tool.run

        %{
          tool
          | run: fn arguments, context ->
              send(owner, {__MODULE__, ref, {tool.name, arguments}})
              original.(arguments, context)
            end
        }
      end)

    {tools, ref}
  end

  @doc "Run steps and assert their expectations, raising ExUnit.AssertionError on failure."
  def run!(session, steps, options \\ []) do
    timeout = Keyword.get(options, :timeout_ms, 5_000)

    unless is_integer(timeout) and timeout > 0,
      do: raise(ArgumentError, "timeout_ms must be positive")

    for {step, index} <- Enum.with_index(steps, 1),
        do: run_step!(session, step, index, timeout, options)
  end

  defp run_step!(session, step, index, timeout, options) do
    input = validate_step!(step, options)
    turn = submit!(session, input, index)
    deadline = System.monotonic_time(:millisecond) + timeout
    {events, metrics} = collect(session, turn, deadline, [], index)
    reply = Enum.map_join(events, &text(&1, options[:node]))
    calls = tool_calls(options[:observer], [])
    result = %{turn: turn, reply: reply, tools: calls, events: events, metrics: metrics}
    assert_step!(step, index, reply, calls)
    result
  end

  defp validate_step!(step, options) do
    input = Map.fetch!(step, :input)
    unless is_binary(input), do: raise(ArgumentError, "step input must be a string")

    if Map.has_key?(step, :tools) and not is_reference(options[:observer]),
      do: raise(ArgumentError, "tool assertions require observe_tools/1 and observer: ref")

    input
  end

  defp submit!(session, input, index) do
    case AudioFlow.submit(session, %Text{data: input}) do
      {:ok, turn} -> turn
      error -> fail!(index, "submission failed: #{inspect(error)}")
    end
  end

  defp assert_step!(step, index, reply, calls) do
    if Map.has_key?(step, :reply) and not matches?(reply, step.reply),
      do: fail!(index, "reply #{inspect(reply)} did not match #{inspect(step.reply)}")

    if Map.has_key?(step, :tools) and calls != step.tools,
      do: fail!(index, "tool calls #{inspect(calls)} did not equal #{inspect(step.tools)}")
  end

  defp collect(session, turn, deadline, events, index) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {AudioFlow, ^session, ^turn, {:done, metrics}} ->
        {Enum.reverse(events), metrics}

      {AudioFlow, ^session, ^turn, {:error, reason, _}} ->
        fail!(index, "turn failed: #{inspect(reason)}")

      {AudioFlow, ^session, ^turn, {:cancelled, _}} ->
        fail!(index, "turn was cancelled")

      {AudioFlow, ^session, ^turn, event} ->
        collect(session, turn, deadline, [event | events], index)
    after
      remaining ->
        AudioFlow.cancel(session)
        fail!(index, "timed out waiting for turn completion")
    end
  end

  defp text({:text, text}, nil), do: text
  defp text({:text, text, node}, selected) when selected == nil or selected == node, do: text
  defp text(_, _), do: ""

  defp tool_calls(nil, _), do: []

  defp tool_calls(ref, acc) do
    receive do
      {__MODULE__, ^ref, call} -> tool_calls(ref, [call | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp matches?(reply, expected) when is_binary(expected), do: reply == expected
  defp matches?(reply, %Regex{} = expected), do: Regex.match?(expected, reply)
  defp matches?(reply, expected) when is_function(expected, 1), do: expected.(reply) == true
  defp matches?(_, _), do: raise(ArgumentError, "reply must be a string, regex, or predicate")

  defp fail!(index, message),
    do: raise(ExUnit.AssertionError, message: "conversation step #{index}: #{message}")
end
