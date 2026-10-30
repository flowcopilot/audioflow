defmodule AudioFlow.ChatHTTPTest do
  use ExUnit.Case, async: true
  alias AudioFlow.Adapters.ChatHTTP
  alias AudioFlow.Test.HTTPFixture, as: HTTP

  defp server(handler) do
    {child, listener, endpoint} = HTTP.start(self(), handler)
    start_supervised!(child)
    on_exit(fn -> :gen_tcp.close(listener) end)
    [endpoint: endpoint, model: "fixture-model"]
  end

  test "text is emitted before EOF and chat roles and credentials reach the endpoint" do
    options =
      server(fn socket, _ ->
        HTTP.headers(socket)
        HTTP.chunk(socket, HTTP.event("Hello. "))

        receive do
          :continue -> :ok
        end

        HTTP.chunk(socket, HTTP.event("World!", "stop") <> HTTP.done())
        HTTP.finish(socket)
      end)

    owner = self()

    options =
      options ++
        [
          system: "Be brief.",
          api_key: fn -> "fixture-key" end,
          parameters: %{temperature: 0, max_completion_tokens: 64, stream: false, n: 9}
        ]

    task =
      Task.async(fn ->
        ChatHTTP.run(
          [
            %{role: :user, content: "First"},
            %{role: :assistant, content: "Answer"},
            %{role: :user, content: "Next"}
          ],
          options,
          fn text ->
            send(owner, {:text, text})
            :ok
          end
        )
      end)

    assert_receive {:http_request, server, request}
    assert request.line == "POST /v1/chat/completions HTTP/1.1"
    assert request.headers["authorization"] == "Bearer fixture-key"

    assert request.body == %{
             "model" => "fixture-model",
             "stream" => true,
             "n" => 1,
             "temperature" => 0,
             "max_completion_tokens" => 64,
             "messages" => [
               %{"role" => "system", "content" => "Be brief."},
               %{"role" => "user", "content" => "First"},
               %{"role" => "assistant", "content" => "Answer"},
               %{"role" => "user", "content" => "Next"}
             ]
           }

    assert_receive {:text, "Hello. "}
    send(server, :continue)
    assert :ok = Task.await(task)
    assert_receive {:text, "World!"}
  end

  test "HTTP failures and redirects return status errors without replaying the request" do
    for status <- [307, 429, 503] do
      options =
        server(fn socket, _ ->
          HTTP.headers(socket, status, [
            {"Location", "http://127.0.0.1:1/other"},
            {"Retry-After", "0"}
          ])

          HTTP.finish(socket)
        end)

      assert {:error, {:http_status, ^status}} = ChatHTTP.run("Hello", options, fn _ -> :ok end)
      assert_receive {:http_request, _, _}
      refute_receive {:http_request, _, _}, 20
    end
  end

  test "malformed, refused, tool, and incomplete responses return explicit errors" do
    owner = self()

    for {body, expected} <- [
          {"data: invalid JSON\n\n", :invalid_event},
          {HTTP.event("unfinished", "length") <> HTTP.done(), {:finish_reason, "length"}},
          {HTTP.event("unfinished") <> HTTP.done(), :incomplete_stream},
          {HTTP.event("unfinished", "stop"), :incomplete_stream},
          {HTTP.event("", "stop") <> HTTP.done(), :empty_response},
          {"data: {\"error\":{\"message\":\"fixture-key\"}}\n\n", :remote_error},
          {"data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{}]}}]}\n\n",
           :unsupported_tool_call},
          {"data: {\"choices\":[{\"index\":0,\"delta\":{\"refusal\":\"No\"}}]}\n\n", :refusal}
        ] do
      options =
        server(fn socket, _ ->
          HTTP.headers(socket)
          HTTP.chunk(socket, body)
          HTTP.finish(socket)
        end)

      assert {:error, ^expected} =
               ChatHTTP.run("Hello", options, fn text ->
                 send(owner, {:unverified_tail, text})
                 :ok
               end)

      assert_receive {:http_request, _, _}
      refute_receive {:unverified_tail, _}, 10
    end
  end

  test "response, event, and text size limits stop the response" do
    for {limit, expected} <- [
          {[max_response_bytes: 8], :response_too_large},
          {[max_event_bytes: 8], :event_too_large},
          {[max_text_bytes: 2], :text_too_large}
        ] do
      options =
        server(fn socket, _ ->
          HTTP.headers(socket)
          HTTP.chunk(socket, HTTP.event("Hello", "stop") <> HTTP.done())
          HTTP.finish(socket)
        end)

      assert {:error, ^expected} = ChatHTTP.run("Hello", options ++ limit, fn _ -> :ok end)
      assert_receive {:http_request, _, _}
    end
  end

  test "an oversized request is rejected before it reaches the server" do
    options = server(fn socket, _ -> HTTP.headers(socket) end)

    assert {:error, :request_too_large} =
             ChatHTTP.run("Hello", options ++ [max_request_bytes: 2], fn _ -> :ok end)

    refute_receive {:http_request, _, _}, 20
  end

  test "cancellation closes the HTTP socket and permits a later session turn" do
    owner = self()

    options =
      server(fn socket, _ ->
        HTTP.headers(socket)
        HTTP.chunk(socket, HTTP.event("Working. "))

        case :gen_tcp.recv(socket, 0, 5_000) do
          {:error, :closed} -> send(owner, :connection_closed)
          other -> send(owner, {:unexpected_socket, other})
        end
      end)

    session_options = Keyword.put(AudioFlow.Adapters.Demo.options(), :llm, {ChatHTTP, options})
    {:ok, session} = AudioFlow.start_session(session_options)
    on_exit(fn -> if Process.alive?(session), do: AudioFlow.stop_session(session) end)
    audio = %AudioFlow.Audio{data: <<0, 0>>, sample_rate: 16_000}
    {:ok, first} = AudioFlow.submit(session, audio)
    assert_receive {:http_request, _, _}
    assert_receive {AudioFlow, ^session, ^first, {:text, "Working. "}}
    assert :ok = AudioFlow.cancel(session)
    assert_receive {AudioFlow, ^session, ^first, {:cancelled, _}}
    assert_receive :connection_closed
    {:ok, second} = AudioFlow.submit(session, audio)
    assert_receive {:http_request, _, _}
    assert_receive {AudioFlow, ^session, ^second, {:text, "Working. "}}
    assert :ok = AudioFlow.cancel(session)
    assert_receive :connection_closed
  end

  test "an idle response times out and closes its socket" do
    owner = self()

    options =
      server(fn socket, _ ->
        HTTP.headers(socket)

        case :gen_tcp.recv(socket, 0, 5_000) do
          {:error, :closed} -> send(owner, :connection_closed)
          other -> send(owner, {:unexpected_socket, other})
        end
      end)

    assert {:error, {:http, _}} =
             ChatHTTP.run("Hello", options ++ [receive_timeout_ms: 100], fn _ -> :ok end)

    assert_receive :connection_closed
  end

  test "a consumer failure closes the socket while the caller remains alive" do
    owner = self()

    options =
      server(fn socket, _ ->
        HTTP.headers(socket)
        HTTP.chunk(socket, HTTP.event("First. "))
        send(owner, {:socket_result, :gen_tcp.recv(socket, 0, 5_000)})
      end)

    assert catch_throw(ChatHTTP.run("Hello", options, fn _ -> throw(:stop_consuming) end)) ==
             :stop_consuming

    assert_receive {:socket_result, {:error, :closed}}
  end

  test "a non-SSE response is rejected before body decoding" do
    options =
      server(fn socket, _ ->
        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}"
        )
      end)

    assert {:error, :invalid_content_type} = ChatHTTP.run("Hello", options, fn _ -> :ok end)
  end
end
