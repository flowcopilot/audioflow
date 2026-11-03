defmodule AudioFlow.Adapters.ReqLLM do
  @moduledoc """
  ReqLLM model/context/options executed in the AudioFlow turn process.

  Pass `:model` as any static ReqLLM model input, and the remaining ReqLLM
  generation options directly (`:base_url`, `:api_key`, `:temperature`,
  `:max_tokens`, `:provider_options`, `:tools`, etc.). Input accepts a
  `ReqLLM.Context`, a prompt, or ReqLLM messages. No system prompt is added
  unless supplied through ReqLLM's `:system_prompt` option.

  AudioFlow execution limits and Jido tools live under `:audio_flow`:
  `:tools`, `:tool_context`, `:tool_filler`, `:max_tool_rounds`,
  `:max_tool_calls`, `:tool_timeout_ms`, `:max_tool_result_bytes`,
  `:max_request_bytes`, `:max_response_bytes`, `:max_event_bytes`,
  `:max_text_bytes`, `:timeout_ms`, `:receive_timeout_ms`, `:pool_timeout_ms`.

  This bounded HTTP/SSE bridge uses ReqLLM request construction, SSE parsing,
  provider decoding and chunk accumulation. Finch runs synchronously in the
  turn process: output callbacks apply backpressure and killing the turn closes
  its checked-out socket. There are no producer queues or helper processes.
  Redirects, retries, cache replay and non-HTTP transports are not executed.
  """
  @behaviour AudioFlow.Adapter
  alias AudioFlow.TextChunks
  alias AudioFlow.Tool
  alias ReqLLM.Context
  alias ReqLLM.Provider.ChunkAccumulator, as: Acc
  alias ReqLLM.Provider.Options
  alias ReqLLM.Streaming.SSE
  alias ReqLLM.ToolCall

  @impl true
  def run(input, options, emit) do
    {execution, opts} = Keyword.pop(options, :audio_flow, [])
    {model_spec, opts} = Keyword.pop!(opts, :model)
    opts = ReqLLM.ModelInput.merge_tuple_defaults(model_spec, :chat, opts)
    model = ReqLLM.model!(model_spec)
    {:ok, provider} = ReqLLM.ProviderDispatch.get(model, :chat, stream: true)

    {:ok, opts} =
      Options.normalize_namespaced_provider_options(provider, :chat, model, opts)

    {:ok, context} = Context.normalize(input, opts)
    tools = tools(execution)
    native_tools = Keyword.get(opts, :tools, [])

    converted =
      Enum.map(Map.values(tools), fn tool ->
        ReqLLM.Tool.new!(
          name: tool.name,
          description: tool.description,
          parameter_schema: tool.parameters,
          callback: fn _ -> {:error, :execution_bridge_only} end
        )
      end)

    names = Enum.map(native_tools ++ converted, & &1.name)

    if length(names) != length(Enum.uniq(names)),
      do: raise(ArgumentError, "tool names must be unique")

    opts = Keyword.put(opts, :tools, native_tools ++ converted)
    options = execution
    filler = Keyword.get(options, :tool_filler)

    if not (filler == nil or (is_binary(filler) and String.valid?(filler))),
      do: raise(ArgumentError, "tool_filler must be a string")

    tool_context = Keyword.get(options, :tool_context, %{})
    if not is_map(tool_context), do: raise(ArgumentError, "tool_context must be a map")

    config = %{
      model: model,
      provider: provider,
      options: opts,
      native_tools: Map.new(native_tools, &{&1.name, &1}),
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
        request_timeout:
          positive!(options, :timeout_ms, Keyword.get(opts, :request_timeout, 30_000)),
        receive_timeout:
          positive!(options, :receive_timeout_ms, Keyword.get(opts, :receive_timeout, 10_000)),
        pool_timeout:
          positive!(options, :pool_timeout_ms, Keyword.get(opts, :pool_timeout, 5_000))
      ]
    }

    round(config, context, 0, 0)
  end

  defp round(config, messages, round, text_bytes) do
    case request(config, messages, text_bytes) do
      {:ok, %{calls: calls}} when calls == [] -> :ok
      {:ok, _} when round >= config.max_rounds -> {:error, :tool_round_limit}
      {:ok, state} -> tool_round(config, messages, round, state)
      {:error, _} = error -> error
    end
  end

  defp tool_round(config, messages, round, state) do
    content = IO.iodata_to_binary(state.content)
    filler = if config.filler != nil and String.trim(content) == "", do: config.filler, else: ""
    text_bytes = state.text_bytes + byte_size(filler)

    cond do
      Enum.any?(state.calls, &(&1.id == "" or &1.name == "")) ->
        {:error, :invalid_tool_call}

      text_bytes > config.text_limit ->
        {:error, :text_too_large}

      true ->
        if filler != "", do: :ok = config.emit.(filler)
        messages = Context.append(messages, tool_messages(config, state.calls, content))
        round(config, messages, round + 1, text_bytes)
    end
  end

  defp tool_messages(config, calls, content) do
    results =
      Enum.map(calls, fn call ->
        Context.tool_result(call.id, call.name, call_tool(config, call))
      end)

    assistant =
      Context.assistant(content,
        tool_calls:
          Enum.map(calls, fn call ->
            ToolCall.new(call.id, call.name, JSON.encode!(call.arguments))
          end)
      )

    [assistant | results]
  end

  defp request(config, messages, text_bytes) do
    {:ok, request} =
      config.provider.attach_stream(config.model, messages, config.options, AudioFlow.HTTPClient)

    if IO.iodata_length(request.body) > config.request_limit do
      {:error, :request_too_large}
    else
      state = %{
        parser: nil,
        event_limit: config.event_limit,
        config: config,
        accumulator: Acc.new(),
        provider_state: nil,
        response_limit: config.response_limit,
        text_limit: config.text_limit,
        tools?: config.tools != %{} or config.native_tools != %{},
        max_calls: config.max_calls,
        response_bytes: 0,
        text_bytes: text_bytes,
        has_text?: false,
        pending: "",
        content: [],
        calls: MapSet.new(),
        call_names: %{},
        call_ids: %{},
        finished?: false,
        done?: false,
        content_type?: false,
        error: nil,
        emit: config.emit
      }

      case Finch.stream_while(
             request,
             AudioFlow.HTTPClient,
             state,
             &receive_http/2,
             config.timeouts
           ) do
        {:ok, %{error: reason}} when reason != nil ->
          {:error, reason}

        {:ok, %{done?: true} = state} ->
          {:ok, %{state | calls: finalize_calls(state)}}

        {:ok, _} ->
          {:error, :incomplete_stream}

        {:error, _, %{error: reason}} when reason != nil ->
          {:error, reason}

        {:error, error, _} ->
          {:error, {:http, Exception.message(error)}}
      end
    end
  end

  defp call_tool(config, call) do
    arguments = call.arguments

    cond do
      match?({:args_lost, _}, get_in(call, [:metadata, :error])) ->
        JSON.encode!(%{"error" => "tool arguments must be a JSON object"})

      not is_map(arguments) ->
        JSON.encode!(%{"error" => "tool arguments must be a JSON object"})

      tool = config.tools[call.name] ->
        Tool.call(tool, arguments, config.tool_options)

      native = config.native_tools[call.name] ->
        bridge =
          Tool.new(%{name: native.name, run: fn args -> ReqLLM.Tool.execute(native, args) end})

        Tool.call(bridge, arguments, config.tool_options)

      true ->
        JSON.encode!(%{"error" => "unknown tool #{call.name}"})
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
        parse_events(chunk, state)
    end
  end

  defp receive_http({:trailers, _}, state), do: {:cont, state}

  defp parse_events(chunk, state) do
    {events, parser} = SSE.accumulate_and_parse(chunk, state.parser)

    # Bound both completed payloads and retained parser fields. Transport
    # reads are already bounded by max_response_bytes before parsing.
    if retained_bytes(parser) > state.event_limit or
         Enum.any?(events, &(byte_size(&1.data) > state.event_limit)) do
      fail(state, :event_too_large)
    else
      events(events, %{state | parser: parser})
    end
  end

  defp retained_bytes(parser) do
    IO.iodata_length(parser.value || "") +
      if(is_binary(parser.key), do: byte_size(parser.key), else: 0) +
      Enum.reduce(parser.event || %{}, 0, fn {_, value}, n -> n + field_bytes(value) end)
  end

  defp field_bytes(value) when is_binary(value) or is_list(value), do: IO.iodata_length(value)
  defp field_bytes(_value), do: 0

  defp events([], state), do: {:cont, state}

  defp events([event | rest], state) do
    case event(event, state) do
      {:cont, state} -> events(rest, state)
      {:halt, state} -> {:halt, state}
    end
  end

  defp event(%{data: "[DONE]"}, state), do: complete(state)

  defp event(%{data: data} = raw_event, state) do
    with {:ok, decoded} when is_map(decoded) <- JSON.decode(data),
         :ok <- validate_event(decoded, state),
         {:ok, state} <- track_calls(decoded, state) do
      %{raw_event | data: decoded}
      |> provider_chunks(state)
      |> push_chunks(decoded)
    else
      {:error, reason}
      when is_atom(reason) or (is_tuple(reason) and elem(reason, 0) == :finish_reason) ->
        fail(state, reason)

      _ ->
        fail(state, :invalid_event)
    end
  end

  defp provider_chunks(event, state) do
    provider = state.config.provider

    {chunks, provider_state} =
      if function_exported?(provider, :decode_stream_event, 3),
        do: provider.decode_stream_event(event, state.config.model, state.provider_state),
        else: {provider.decode_stream_event(event, state.config.model), state.provider_state}

    {chunks, %{state | provider_state: provider_state}}
  end

  defp push_chunks({chunks, state}, decoded) do
    case Enum.reduce_while(chunks, {:cont, state}, &push_chunk/2) do
      {:cont, state} -> if terminal?(decoded), do: complete(state), else: {:cont, state}
      error -> error
    end
  end

  defp push_chunk(chunk, {:cont, state}) do
    case chunk(chunk, state) do
      {:cont, state} -> {:cont, {:cont, state}}
      {:halt, state} -> {:halt, {:halt, state}}
    end
  end

  # ReqLLM deliberately ignores some malformed/unsupported OpenAI fields.
  # These checks preserve AudioFlow's fail-closed contract; framing, text and
  # tool-call decoding/assembly are entirely owned by ReqLLM.
  defp validate_event(%{"error" => _}, _), do: {:error, :remote_error}
  defp validate_event(%{"type" => "response.refusal.delta"}, _), do: {:error, :refusal}

  defp validate_event(%{"choices" => choices}, _)
       when not is_list(choices), do: {:error, :invalid_event}

  defp validate_event(%{"choices" => []}, _), do: :ok

  defp validate_event(%{"choices" => [%{"index" => 0}]} = event, state),
    do: validate_choice(event, state)

  defp validate_event(%{"choices" => _}, _), do: {:error, :invalid_event}
  defp validate_event(_, _), do: :ok

  defp validate_choice(%{"choices" => choices}, state) do
    Enum.reduce_while(choices, :ok, fn choice, :ok ->
      if reason = choice_error(choice, state),
        do: {:halt, {:error, reason}},
        else: {:cont, :ok}
    end)
  end

  defp choice_error(choice, state) do
    delta = choice["delta"] || %{}

    if is_map(delta),
      do: delta_error(delta) || finish_error(choice, delta, state),
      else: :invalid_event
  end

  defp delta_error(delta) do
    cond do
      delta["content"] != nil and not is_binary(delta["content"]) -> :invalid_event
      delta["refusal"] not in [nil, ""] -> :refusal
      delta["function_call"] != nil -> :unsupported_tool_call
      true -> nil
    end
  end

  defp finish_error(choice, delta, state) do
    cond do
      (delta["tool_calls"] not in [nil, []] or choice["finish_reason"] == "tool_calls") and
          not state.tools? ->
        :unsupported_tool_call

      choice["finish_reason"] not in [nil, "stop", "tool_calls"] ->
        {:finish_reason, choice["finish_reason"]}

      state.finished? ->
        :content_after_finish

      not valid_calls?(delta["tool_calls"]) ->
        :invalid_event

      true ->
        nil
    end
  end

  defp track_calls(%{"choices" => choices}, state) do
    Enum.reduce_while(choices, {:ok, state}, fn choice, {:ok, state} ->
      calls = get_in(choice, ["delta", "tool_calls"]) || []

      case Enum.reduce_while(calls, {:ok, state}, &track_call/2) do
        {:ok, state} -> {:cont, {:ok, state}}
        error -> {:halt, error}
      end
    end)
  end

  defp track_calls(_, state), do: {:ok, state}

  defp track_call(call, {:ok, state}) do
    calls = MapSet.put(state.calls, call["index"])

    cond do
      not MapSet.member?(state.calls, call["index"]) and call["id"] in [nil, ""] ->
        {:halt, {:error, :invalid_tool_call}}

      MapSet.size(calls) > state.max_calls ->
        {:halt, {:error, :tool_call_limit}}

      true ->
        id = call["id"] || state.call_ids[call["index"]]
        name = get_in(call, ["function", "name"]) || ""

        {:cont,
         {:ok,
          %{
            state
            | calls: calls,
              call_names: Map.update(state.call_names, id, name, &(&1 <> name)),
              call_ids: Map.put(state.call_ids, call["index"], id)
          }}}
    end
  end

  defp valid_calls?(nil), do: true

  defp valid_calls?(calls) when is_list(calls),
    do:
      Enum.all?(calls, fn call ->
        is_map(call) and is_integer(call["index"]) and call["index"] >= 0 and
          (is_nil(call["id"]) or is_binary(call["id"])) and
          (is_nil(call["function"]) or
             (is_map(call["function"]) and
                Enum.all?(["name", "arguments"], fn key ->
                  is_nil(call["function"][key]) or is_binary(call["function"][key])
                end)))
      end)

  defp valid_calls?(_), do: false

  defp chunk(chunk, state) do
    acc = Acc.push(state.accumulator, chunk)
    state = %{state | accumulator: acc}

    cond do
      length(acc.tool_calls) > state.max_calls ->
        fail(state, :tool_call_limit)

      acc.tool_calls != [] and not state.tools? ->
        fail(state, :unsupported_tool_call)

      chunk.type == :meta ->
        finish_reason(chunk.metadata[:finish_reason], state)

      chunk.type == :content and is_binary(chunk.text) ->
        content(chunk.text, state)

      true ->
        {:cont, state}
    end
  end

  defp finish_reason(nil, state), do: {:cont, state}

  defp finish_reason(reason, state) when reason in [:stop, :tool_calls, "stop", "tool_calls"],
    do: {:cont, %{state | finished?: true}}

  defp finish_reason(reason, state), do: fail(state, {:finish_reason, reason})

  defp content(text, state) do
    if state.text_bytes + byte_size(text) > state.text_limit do
      fail(state, :text_too_large)
    else
      {sentences, pending} = TextChunks.push(state.pending, text)
      Enum.each(sentences, fn sentence -> :ok = state.emit.(sentence) end)

      {:cont,
       %{
         state
         | pending: pending,
           content: [state.content, text],
           text_bytes: state.text_bytes + byte_size(text),
           has_text?: state.has_text? or String.trim(text) != ""
       }}
    end
  end

  defp terminal?(%{"type" => type}), do: type in ["message_stop", "response.completed"]
  defp terminal?(%{"done" => true}), do: true
  defp terminal?(_), do: false

  # ReqLLM 1.29 ignores name fragments after the first tool delta. Keep
  # only that missing field; arguments and JSON reconstruction remain upstream.
  defp finalize_calls(state) do
    state.accumulator
    |> Acc.finalize_tool_calls_for_response()
    |> Enum.map(fn call ->
      %{call | name: Map.get(state.call_names, call.id, call.name)}
    end)
  end

  defp complete(%{finished?: false} = state), do: fail(state, :incomplete_stream)

  defp complete(state) do
    calls = finalize_calls(state)

    cond do
      Enum.any?(
        calls,
        &(not is_binary(&1.id) or &1.id == "" or not is_binary(&1.name) or &1.name == "")
      ) ->
        fail(state, :invalid_tool_call)

      not state.has_text? and calls == [] ->
        fail(state, :empty_response)

      true ->
        if state.pending != "", do: :ok = state.emit.(state.pending)
        {:halt, %{state | done?: true, pending: ""}}
    end
  end

  defp fail(state, reason), do: {:halt, %{state | error: reason}}

  defp positive!(options, key, default) do
    value = Keyword.get(options, key, default)
    if not (is_integer(value) and value > 0), do: raise(ArgumentError, "#{key} must be positive")
    value
  end
end
