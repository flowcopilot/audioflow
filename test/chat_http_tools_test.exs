defmodule AudioFlow.ChatHTTPToolsTest do
  use ExUnit.Case, async: true
  alias AudioFlow.Adapters.ChatHTTP
  alias AudioFlow.Test.HTTPFixture, as: HTTP

  defmodule Weather do
    use Jido.Action,
      name: "weather",
      description: "Returns the forecast for a city.",
      schema: [city: [type: :string, required: true]]

    @impl true
    def run(%{city: city}, context), do: {:ok, %{city: city, forecast: "sun", unit: context.unit}}
  end

  defp server(handler) do
    {child, listener, endpoint} = HTTP.start(self(), handler)
    start_supervised!(child)
    on_exit(fn -> :gen_tcp.close(listener) end)
    [endpoint: endpoint, model: "fixture-model"]
  end

  defp data(delta, finish \\ nil),
    do:
      "data: " <>
        JSON.encode!(%{choices: [%{index: 0, delta: delta, finish_reason: finish}]}) <> "\n\n"

  defp call(index, fields), do: data(%{tool_calls: [Map.put(fields, :index, index)]})
  defp tool_turn?(request), do: Enum.any?(request.body["messages"], &(&1["role"] == "tool"))

  defp reply(socket, body) do
    HTTP.headers(socket)
    HTTP.chunk(socket, body)
    HTTP.finish(socket)
  end

  defp collect(input, options) do
    owner = self()

    result =
      ChatHTTP.run(input, options, fn text ->
        send(owner, {:text, text})
        :ok
      end)

    {result, texts([])}
  end

  defp texts(acc) do
    receive do
      {:text, text} -> texts([text | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "streamed calls run Jido actions and functions, and the results reach the next request" do
    owner = self()

    options =
      server(fn socket, request ->
        if tool_turn?(request) do
          reply(socket, HTTP.event("It is sunny.", "stop") <> HTTP.done())
        else
          reply(
            socket,
            call(0, %{id: "call_a", type: "function", function: %{name: "wea", arguments: ""}}) <>
              call(0, %{function: %{name: "ther", arguments: "{\"ci"}}) <>
              call(0, %{function: %{arguments: "ty\":\"Oslo\"}"}}) <>
              call(1, %{id: "call_b", function: %{name: "clock", arguments: ""}}) <>
              data(%{}, "tool_calls") <> HTTP.done()
          )
        end
      end)

    clock = %{
      name: "clock",
      description: "Returns the time.",
      run: fn arguments ->
        send(owner, {:clock, arguments})
        {:ok, "12:00"}
      end
    }

    options =
      options ++
        [tools: [Weather, clock], tool_context: %{unit: "C"}, tool_filler: "One moment."]

    assert {:ok, ["One moment.", "It is sunny."]} = collect("Weather?", options)

    assert_receive {:http_request, _, first}

    assert [
             %{"type" => "function", "function" => %{"name" => "weather"} = weather},
             %{"function" => %{"name" => "clock", "description" => "Returns the time."}}
           ] = Enum.sort_by(first.body["tools"], &(&1["function"]["name"] != "weather"))

    assert weather["parameters"]["required"] == ["city"]
    assert_receive {:clock, %{}}
    assert_receive {:http_request, _, second}

    assert [_system, _user, assistant, weather_result, clock_result] = second.body["messages"]
    assert assistant["role"] == "assistant" and assistant["content"] == nil

    assert assistant["tool_calls"] == [
             %{
               "id" => "call_a",
               "type" => "function",
               "function" => %{"name" => "weather", "arguments" => "{\"city\":\"Oslo\"}"}
             },
             %{
               "id" => "call_b",
               "type" => "function",
               "function" => %{"name" => "clock", "arguments" => ""}
             }
           ]

    assert %{"role" => "tool", "tool_call_id" => "call_a", "content" => content} = weather_result
    assert JSON.decode!(content) == %{"city" => "Oslo", "forecast" => "sun", "unit" => "C"}
    assert clock_result == %{"role" => "tool", "tool_call_id" => "call_b", "content" => "12:00"}
  end

  test "text before a call is spoken in place of the filler and kept in the assistant message" do
    options =
      server(fn socket, request ->
        if tool_turn?(request),
          do: reply(socket, HTTP.event("Done.", "stop") <> HTTP.done()),
          else:
            reply(
              socket,
              HTTP.event("Let me check. ") <>
                call(0, %{id: "c", function: %{name: "missing", arguments: "{}"}}) <>
                data(%{}, "tool_calls") <> HTTP.done()
            )
      end)

    options = options ++ [tools: [Weather], tool_filler: "One moment."]
    assert {:ok, ["Let me check. ", "Done."]} = collect("Hi", options)
    assert_receive {:http_request, _, _}
    assert_receive {:http_request, _, second}
    [_, _, assistant, result] = second.body["messages"]
    assert assistant["content"] == "Let me check. "
    assert JSON.decode!(result["content"]) == %{"error" => "unknown tool missing"}
  end

  test "failed tools return errors to the model and endless calls stop at the round limit" do
    options =
      server(fn socket, _ ->
        reply(
          socket,
          call(0, %{id: "c", function: %{name: "weather", arguments: "{}"}}) <>
            data(%{}, "tool_calls") <> HTTP.done()
        )
      end)

    options = options ++ [tools: [Weather], max_tool_rounds: 2]
    assert {{:error, :tool_round_limit}, []} = collect("Hi", options)
    assert_receive {:http_request, _, _}
    assert_receive {:http_request, _, _}
    assert_receive {:http_request, _, third}
    refute_receive {:http_request, _, _}, 20
    results = Enum.filter(third.body["messages"], &(&1["role"] == "tool"))
    assert length(results) == 2
    assert Enum.all?(results, &Map.has_key?(JSON.decode!(&1["content"]), "error"))
  end

  test "invalid and excess calls return explicit errors" do
    for {body, extra, expected} <- [
          {call(0, %{function: %{name: "weather", arguments: "{}"}}) <>
             data(%{}, "tool_calls") <> HTTP.done(), [], :invalid_tool_call},
          {call(0, %{id: "a", function: %{name: "weather"}}) <>
             call(1, %{id: "b", function: %{name: "weather"}}), [max_tool_calls: 1],
           :tool_call_limit},
          {data(%{tool_calls: [%{index: "0"}]}), [], :invalid_event},
          {data(%{function_call: %{name: "weather"}}), [], :unsupported_tool_call}
        ] do
      options = server(fn socket, _ -> reply(socket, body) end)
      assert {{:error, ^expected}, []} = collect("Hi", options ++ [tools: [Weather]] ++ extra)
      assert_receive {:http_request, _, _}
    end
  end

  test "cancellation stops a running tool" do
    owner = self()

    options =
      server(fn socket, _ ->
        reply(
          socket,
          call(0, %{id: "c", function: %{name: "wait", arguments: "{}"}}) <>
            data(%{}, "tool_calls") <> HTTP.done()
        )
      end)

    wait = %{
      name: "wait",
      run: fn _ ->
        send(owner, {:tool, self()})
        Process.sleep(:infinity)
      end
    }

    llm = {ChatHTTP, options ++ [tools: [wait]]}

    {:ok, session} =
      AudioFlow.start_session(Keyword.put(AudioFlow.Adapters.Demo.options(), :llm, llm))

    on_exit(fn -> if Process.alive?(session), do: AudioFlow.stop_session(session) end)
    {:ok, turn} = AudioFlow.submit(session, %AudioFlow.Text{data: "Wait"})
    assert_receive {:tool, tool}
    ref = Process.monitor(tool)
    assert :ok = AudioFlow.cancel(session)
    assert_receive {AudioFlow, ^session, ^turn, {:cancelled, _}}
    assert_receive {:DOWN, ^ref, :process, ^tool, _}
  end
end
