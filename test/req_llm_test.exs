defmodule AudioFlow.ReqLLMTest do
  use ExUnit.Case, async: true
  alias AudioFlow.Adapters.ReqLLM, as: Bridge
  alias AudioFlow.Test.HTTPFixture, as: HTTP

  defp server(handler) do
    {child, listener, endpoint} = HTTP.start(self(), handler)
    start_supervised!(child)
    on_exit(fn -> :gen_tcp.close(listener) end)

    [
      model: %{provider: :openai, id: "fixture-model"},
      base_url: String.replace_suffix(endpoint, "/chat/completions", ""),
      api_key: "local"
    ]
  end

  test "ReqLLM context, generation options and byte-split framing work directly" do
    options =
      server(fn socket, _ ->
        HTTP.headers(socket)

        bytes =
          <<239, 187, 191>> <>
            ": comment\r" <>
            "data: {\"choices\":\r\ndata: [{\"index\":0,\"delta\":{\"content\":\"Héllo. \"}}]}\r\r" <>
            HTTP.event("World", "stop") <> HTTP.done()

        for <<byte <- bytes>>, do: HTTP.chunk(socket, <<byte>>)
        HTTP.finish(socket)
      end)

    context =
      ReqLLM.Context.new([ReqLLM.Context.system("Speak briefly."), ReqLLM.Context.user("Hi")])

    owner = self()

    assert :ok =
             Bridge.run(context, options ++ [temperature: 0.25, max_tokens: 19], fn text ->
               send(owner, {:text, text})
               :ok
             end)

    assert_receive {:http_request, _, request}
    assert request.body["temperature"] == 0.25
    assert request.body["max_tokens"] == 19
    assert hd(request.body["messages"]) == %{"role" => "system", "content" => "Speak briefly."}
    assert_receive {:text, "Héllo. "}
    assert_receive {:text, "World"}
  end

  test "blocked output has no producer queue and killing its turn closes the socket" do
    owner = self()

    options =
      server(fn socket, _ ->
        HTTP.headers(socket)
        HTTP.chunk(socket, HTTP.event("First. "))
        send(owner, {:socket_result, :gen_tcp.recv(socket, 0, 5_000)})
      end)

    turn =
      spawn(fn ->
        Bridge.run("Hi", options, fn _ ->
          send(owner, {:blocked, self(), Process.info(self(), :links)})

          receive do
            :continue -> :ok
          end
        end)
      end)

    ref = Process.monitor(turn)
    assert_receive {:http_request, _, _}
    assert_receive {:blocked, ^turn, {:links, links}}
    refute Enum.any?(links, &is_pid/1)
    # The callback runs in the checked-out socket's consumer. No producer or
    # metadata helper exists to queue output while this process is blocked.
    assert {:message_queue_len, 0} = Process.info(turn, :message_queue_len)
    Process.exit(turn, :kill)
    assert_receive {:DOWN, ^ref, :process, ^turn, :killed}
    assert_receive {:socket_result, {:error, :closed}}
  end

  test "native ReqLLM tools execute with bounded results and reach the next context" do
    owner = self()

    options =
      server(fn socket, request ->
        HTTP.headers(socket)

        if Enum.any?(request.body["messages"], &(&1["role"] == "tool")) do
          HTTP.chunk(socket, HTTP.event("Done.", "stop") <> HTTP.done())
        else
          HTTP.chunk(
            socket,
            "data: " <>
              JSON.encode!(%{
                choices: [
                  %{
                    index: 0,
                    delta: %{
                      tool_calls: [
                        %{
                          index: 0,
                          id: "c",
                          type: "function",
                          function: %{name: "clock", arguments: "{}"}
                        }
                      ]
                    },
                    finish_reason: "tool_calls"
                  }
                ]
              }) <> "\n\n" <> HTTP.done()
          )
        end

        HTTP.finish(socket)
      end)

    tool =
      ReqLLM.Tool.new!(
        name: "clock",
        description: "Time",
        parameter_schema: %{"type" => "object", "properties" => %{}},
        callback: fn args ->
          send(owner, {:called, args})
          {:ok, "oversized"}
        end
      )

    assert :ok =
             Bridge.run(
               "Hi",
               options ++ [tools: [tool], audio_flow: [max_tool_result_bytes: 2]],
               fn _ -> :ok end
             )

    assert_receive {:called, %{}}
    assert_receive {:http_request, _, _}
    assert_receive {:http_request, _, second}
    result = Enum.find(second.body["messages"], &(&1["role"] == "tool"))
    assert JSON.decode!(result["content"])["error"] =~ "larger than 2 bytes"
  end

  test "an unterminated SSE field is bounded before EOF" do
    owner = self()

    options =
      server(fn socket, _ ->
        HTTP.headers(socket)
        HTTP.chunk(socket, "data: " <> String.duplicate("x", 17))
        send(owner, {:socket_result, :gen_tcp.recv(socket, 0, 5_000)})
      end)

    assert {:error, :event_too_large} =
             Bridge.run("Hi", options ++ [audio_flow: [max_event_bytes: 16]], fn _ -> :ok end)

    assert_receive {:socket_result, {:error, :closed}}
  end

  test "ReqLLM Anthropic decoding is used without an OpenAI protocol facade" do
    options =
      server(fn socket, _ ->
        HTTP.headers(socket)

        for event <- [
              %{
                type: "content_block_delta",
                index: 0,
                delta: %{type: "text_delta", text: "Hello."}
              },
              %{type: "message_delta", delta: %{stop_reason: "end_turn"}},
              %{type: "message_stop"}
            ],
            do: HTTP.chunk(socket, "data: " <> JSON.encode!(event) <> "\n\n")

        HTTP.finish(socket)
      end)

    options = Keyword.put(options, :model, %{provider: :anthropic, id: "fixture-model"})
    owner = self()

    assert :ok =
             Bridge.run("Hi", options ++ [max_tokens: 16], fn text ->
               send(owner, {:text, text})
               :ok
             end)

    assert_receive {:text, "Hello."}
  end

  test "malformed upstream tool arguments never execute a callback" do
    owner = self()

    options =
      server(fn socket, request ->
        HTTP.headers(socket)

        if Enum.any?(request.body["messages"], &(&1["role"] == "tool")) do
          HTTP.chunk(socket, HTTP.event("Done.", "stop") <> HTTP.done())
        else
          HTTP.chunk(
            socket,
            "data: " <>
              JSON.encode!(%{
                choices: [
                  %{
                    index: 0,
                    delta: %{
                      tool_calls: [
                        %{
                          index: 0,
                          id: "bad",
                          type: "function",
                          function: %{name: "clock", arguments: "{broken"}
                        }
                      ]
                    },
                    finish_reason: "tool_calls"
                  }
                ]
              }) <> "\n\n" <> HTTP.done()
          )
        end

        HTTP.finish(socket)
      end)

    tool =
      ReqLLM.Tool.new!(
        name: "clock",
        description: "Time",
        parameter_schema: %{"type" => "object", "properties" => %{}},
        callback: fn _ ->
          send(owner, :unsafe_execution)
          {:ok, "time"}
        end
      )

    assert :ok = Bridge.run("Hi", options ++ [tools: [tool]], fn _ -> :ok end)
    assert_receive {:http_request, _, _}
    assert_receive {:http_request, _, second}
    result = Enum.find(second.body["messages"], &(&1["role"] == "tool"))
    assert JSON.decode!(result["content"])["error"] =~ "JSON object"
    refute_receive :unsafe_execution
  end
end
