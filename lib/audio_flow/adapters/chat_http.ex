defmodule AudioFlow.Adapters.ChatHTTP do
  @moduledoc """
  Streaming chat completions over HTTP/1 for compatible local and cloud engines.

  Required options: `:endpoint` (complete chat-completions URL), `:model`.
  Optional: `:api_key` (string or zero-argument function), `:system`, `:parameters`
  (JSON object), `:headers`, `:timeout_ms` (30,000), `:receive_timeout_ms` (10,000),
  `:pool_timeout_ms` (5,000), `:max_request_bytes` (65,536), `:max_response_bytes`
  (262,144), `:max_event_bytes` (16,384), and `:max_text_bytes` (8,192).

  Input is a string or a list of `%{role: :user | :assistant, content: text}`
  messages. The system instruction is prepended once. Output consists of
  sentence-sized text chunks, with whitespace preserved. Refusals, truncated
  completions, and incomplete streams return errors. Earlier complete sentences
  may already have been emitted.

  `:tools` is a list of `Jido.Action` modules or tool maps (see `AudioFlow.Tool`).
  Without tools, a tool call returns `{:error, :unsupported_tool_call}`. With
  tools, the adapter collects the streamed calls, runs them in sequence in the
  turn process, adds the results to the messages, and sends a new request. The
  text of every request goes to the output callback. If a request has tool calls
  but no text, `:tool_filler` (for example `"One moment."`) is emitted before the
  tools run. Tool failures go back to the model as `{"error": ...}` results.
  Tool options: `:tool_context` (map for Jido actions), `:max_tool_rounds` (4),
  `:max_tool_calls` per request (8), `:tool_timeout_ms` (10,000), and
  `:max_tool_result_bytes` (8,192). More rounds return
  `{:error, :tool_round_limit}`. `:max_text_bytes` counts the text of all rounds.
  The legacy `function_call` field is not supported.

  Requests use a shared HTTP/1 pool with a five-second connection timeout.
  The response-read budget excludes pool checkout, connection setup, and time
  blocked in the output callback. Use session or worker deadlines to bound the
  complete operation.
  Caller exit closes the checked-out connection. The adapter does not follow
  redirects or retry HTTP failures. Use HTTPS for cloud endpoints.
  """
  @behaviour AudioFlow.Adapter
  alias AudioFlow.{SSE, TextChunks, Tool}

  @impl true
  def run(input, options, emit) do
    endpoint = Keyword.fetch!(options, :endpoint)
    model = Keyword.fetch!(options, :model)
    uri = URI.parse(endpoint)

    if uri.scheme not in ["http", "https"] or uri.host == nil or uri.userinfo != nil,
      do: raise(ArgumentError, "endpoint must be an HTTP or HTTPS URL without user information")

    messages = [
      %{role: "system", content: Keyword.get(options, :system, AudioFlow.Prompt.default_system())}
      | messages(input)
    ]

    parameters =
      Map.new(Keyword.get(options, :parameters, %{}), fn {key, value} ->
        {to_string(key), value}
      end)

    parameters =
      if Map.has_key?(parameters, "max_tokens") or
           Map.has_key?(parameters, "max_completion_tokens"),
         do: parameters,
         else: Map.put(parameters, "max_tokens", 128)

    tools = tools(options)

    parameters =
      if tools == %{},
        do: parameters,
        else: Map.put(parameters, "tools", tools |> Map.values() |> Enum.map(&Tool.spec/1))

    filler = Keyword.get(options, :tool_filler)

    if not (filler == nil or (is_binary(filler) and String.valid?(filler))),
      do: raise(ArgumentError, "tool_filler must be a string")

    tool_context = Keyword.get(options, :tool_context, %{})
    if not is_map(tool_context), do: raise(ArgumentError, "tool_context must be a map")

    config = %{
      request: Finch.build(:post, endpoint, headers(options), ""),
      parameters: Map.merge(parameters, %{"model" => model, "stream" => true, "n" => 1}),
      request_limit: positive!(options, :max_request_bytes, 65_536),
      event_limit: positive!(options, :max_event_bytes, 16_384),
      response_limit: positive!(options, :max_response_bytes, 262_144),
      text_limit: positive!(options, :max_text_bytes, 8_192),
      tools: tools,
      max_rounds: positive!(options, :max_tool_rounds, 4),
      max_calls: positive!(options, :max_tool_calls, 8),
      tool_options: [
        context: tool_context,
        timeout_ms: positive!(options, :tool_timeout_ms, 10_000),
        max_result_bytes: positive!(options, :max_tool_result_bytes, 8_192)
      ],
      filler: filler,
      emit: emit,
      timeouts: [
        request_timeout: positive!(options, :timeout_ms, 30_000),
        receive_timeout: positive!(options, :receive_timeout_ms, 10_000),
        pool_timeout: positive!(options, :pool_timeout_ms, 5_000)
      ]
    }

    round(config, messages, 0, 0)
  end

  defp round(config, messages, round, text_bytes) do
    case request(config, messages, text_bytes) do
      {:ok, %{calls: calls}} when calls == %{} ->
        :ok

      {:ok, _} when round >= config.max_rounds ->
        {:error, :tool_round_limit}

      {:ok, state} ->
        calls = calls(state.calls)

        if Enum.any?(calls, &(&1.id == "" or &1.name == "")) do
          {:error, :invalid_tool_call}
        else
          content = IO.iodata_to_binary(state.content)

          if config.filler != nil and String.trim(content) == "",
            do: :ok = config.emit.(config.filler)

          results =
            Enum.map(calls, fn call ->
              %{role: "tool", tool_call_id: call.id, content: call_tool(config, call)}
            end)

          assistant = %{
            role: "assistant",
            content: if(content == "", do: nil, else: content),
            tool_calls:
              Enum.map(calls, fn call ->
                %{
                  id: call.id,
                  type: "function",
                  function: %{name: call.name, arguments: call.arguments}
                }
              end)
          }

          round(config, messages ++ [assistant | results], round + 1, state.text_bytes)
        end

      {:error, _} = error ->
        error
    end
  end

  defp request(config, messages, text_bytes) do
    body = config.parameters |> Map.put("messages", messages) |> JSON.encode!()

    if byte_size(body) > config.request_limit do
      {:error, :request_too_large}
    else
      state = %{
        parser: SSE.new(config.event_limit),
        response_limit: config.response_limit,
        text_limit: config.text_limit,
        tools?: config.tools != %{},
        max_calls: config.max_calls,
        response_bytes: 0,
        text_bytes: text_bytes,
        has_text?: false,
        pending: "",
        content: [],
        calls: %{},
        finished?: false,
        done?: false,
        content_type?: false,
        error: nil,
        emit: config.emit
      }

      case Finch.stream_while(
             %{config.request | body: body},
             AudioFlow.HTTPClient,
             state,
             &receive_http/2,
             config.timeouts
           ) do
        {:ok, %{error: reason}} when reason != nil -> {:error, reason}
        {:ok, %{done?: true} = state} -> {:ok, state}
        {:ok, _} -> {:error, :incomplete_stream}
        {:error, _, %{error: reason}} when reason != nil -> {:error, reason}
        {:error, error, _} -> {:error, {:http, Exception.message(error)}}
      end
    end
  end

  defp calls(calls) do
    calls |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
  end

  defp call_tool(config, call) do
    arguments = if String.trim(call.arguments) == "", do: "{}", else: call.arguments

    case {Map.fetch(config.tools, call.name), JSON.decode(arguments)} do
      {:error, _} ->
        JSON.encode!(%{"error" => "unknown tool #{call.name}"})

      {{:ok, tool}, {:ok, arguments}} when is_map(arguments) ->
        Tool.call(tool, arguments, config.tool_options)

      _ ->
        JSON.encode!(%{"error" => "tool arguments must be a JSON object"})
    end
  end

  defp tools(options) do
    tools = options |> Keyword.get(:tools, []) |> Enum.map(&Tool.new/1)
    names = Enum.map(tools, & &1.name)

    if length(Enum.uniq(names)) != length(names),
      do: raise(ArgumentError, "tool names must be unique")

    Map.new(tools, &{&1.name, &1})
  end

  defp receive_http({:status, 200}, state), do: {:cont, state}
  defp receive_http({:status, status}, state), do: fail(state, {:http_status, status})

  defp receive_http({:headers, headers}, state) do
    type =
      headers |> Enum.find_value("", fn {key, value} -> if key == "content-type", do: value end)

    if type |> String.downcase() |> String.split(";") |> hd() |> String.trim() ==
         "text/event-stream",
       do: {:cont, %{state | content_type?: true}},
       else: fail(state, :invalid_content_type)
  end

  defp receive_http({:data, chunk}, state) do
    state = %{state | response_bytes: state.response_bytes + byte_size(chunk)}

    cond do
      not state.content_type? ->
        fail(state, :invalid_content_type)

      state.response_bytes > state.response_limit ->
        fail(state, :response_too_large)

      true ->
        case SSE.push(state.parser, chunk) do
          {:ok, events, parser} -> events(events, %{state | parser: parser})
          {:error, reason} -> fail(state, reason)
        end
    end
  end

  defp receive_http({:trailers, _}, state), do: {:cont, state}

  defp events([], state), do: {:cont, state}

  defp events([event | rest], state) do
    case event(event, state) do
      {:cont, state} -> events(rest, state)
      {:halt, state} -> {:halt, state}
    end
  end

  defp event("[DONE]", %{finished?: true, has_text?: false, calls: calls} = state)
       when calls == %{},
       do: fail(state, :empty_response)

  defp event("[DONE]", %{finished?: true} = state) do
    if state.pending != "", do: :ok = state.emit.(state.pending)
    {:halt, %{state | done?: true, pending: ""}}
  end

  defp event("[DONE]", state), do: fail(state, :incomplete_stream)

  defp event(data, state) do
    case JSON.decode(data) do
      {:ok, %{"error" => _}} ->
        fail(state, :remote_error)

      {:ok, %{"choices" => []}} ->
        {:cont, state}

      {:ok, %{"choices" => [%{"index" => 0, "delta" => delta} = choice]}} when is_map(delta) ->
        choice(choice, delta, state)

      _ ->
        fail(state, :invalid_event)
    end
  end

  defp choice(choice, delta, state) do
    tool_calls = Map.get(delta, "tool_calls")
    finish_reason = Map.get(choice, "finish_reason")

    cond do
      Map.get(delta, "function_call") != nil ->
        fail(state, :unsupported_tool_call)

      (tool_calls not in [nil, []] or finish_reason == "tool_calls") and not state.tools? ->
        fail(state, :unsupported_tool_call)

      Map.get(delta, "refusal") not in [nil, ""] ->
        fail(state, :refusal)

      finish_reason not in [nil, "stop", "tool_calls"] ->
        fail(state, {:finish_reason, finish_reason})

      state.finished? ->
        fail(state, :content_after_finish)

      true ->
        case tool_deltas(tool_calls, state) do
          {:ok, state} -> content(choice, Map.get(delta, "content"), state)
          {:error, reason} -> fail(state, reason)
        end
    end
  end

  defp content(choice, nil, state), do: finish(choice, state)

  defp content(choice, text, state) when is_binary(text) do
    if state.text_bytes + byte_size(text) > state.text_limit do
      fail(state, :text_too_large)
    else
      {sentences, pending} = TextChunks.push(state.pending, text)
      Enum.each(sentences, fn sentence -> :ok = state.emit.(sentence) end)

      finish(choice, %{
        state
        | pending: pending,
          content: [state.content | text],
          text_bytes: state.text_bytes + byte_size(text),
          has_text?: state.has_text? or String.trim(text) != ""
      })
    end
  end

  defp content(_, _, state), do: fail(state, :invalid_event)

  # Streamed calls arrive as fragments keyed by index. The name and the
  # arguments are concatenated; the first fragment usually holds the id.
  defp tool_deltas(nil, state), do: {:ok, state}

  defp tool_deltas(deltas, state) when is_list(deltas) do
    Enum.reduce_while(deltas, {:ok, state}, fn delta, {:ok, state} ->
      case tool_delta(delta, state) do
        {:ok, state} -> {:cont, {:ok, state}}
        error -> {:halt, error}
      end
    end)
  end

  defp tool_deltas(_, _), do: {:error, :invalid_event}

  defp tool_delta(%{"index" => index} = delta, state) when is_integer(index) and index >= 0 do
    function = Map.get(delta, "function") || %{}
    call = Map.get(state.calls, index, %{id: "", name: "", arguments: ""})

    with true <- is_map(function),
         id when is_binary(id) <- Map.get(delta, "id") || call.id,
         name when is_binary(name) <- Map.get(function, "name") || "",
         arguments when is_binary(arguments) <- Map.get(function, "arguments") || "" do
      call = %{id: id, name: call.name <> name, arguments: call.arguments <> arguments}
      calls = Map.put(state.calls, index, call)

      if map_size(calls) > state.max_calls,
        do: {:error, :tool_call_limit},
        else: {:ok, %{state | calls: calls}}
    else
      _ -> {:error, :invalid_event}
    end
  end

  defp tool_delta(_, _), do: {:error, :invalid_event}

  defp finish(choice, state),
    do: {:cont, %{state | finished?: choice["finish_reason"] in ["stop", "tool_calls"]}}

  defp fail(state, reason), do: {:halt, %{state | error: reason}}

  defp messages(text) when is_binary(text), do: [%{role: "user", content: text}]

  defp messages(messages) when is_list(messages) and messages != [] do
    Enum.map(messages, fn %{role: role, content: content}
                          when role in [:user, :assistant, "user", "assistant"] and
                                 is_binary(content) ->
      %{role: to_string(role), content: content}
    end)
  end

  defp headers(options) do
    headers =
      [{"content-type", "application/json"}, {"accept", "text/event-stream"}] ++
        Keyword.get(options, :headers, [])

    case Keyword.get(options, :api_key) do
      nil -> headers
      fun when is_function(fun, 0) -> [{"authorization", "Bearer " <> fun.()} | headers]
      key when is_binary(key) -> [{"authorization", "Bearer " <> key} | headers]
    end
  end

  defp positive!(options, key, default) do
    value = Keyword.get(options, key, default)
    if not (is_integer(value) and value > 0), do: raise(ArgumentError, "#{key} must be positive")
    value
  end
end
