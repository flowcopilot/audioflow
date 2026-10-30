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
  sentence-sized text chunks, with whitespace preserved. Only text chat is
  supported. Tool calls, refusals, truncated completions, and incomplete streams
  return errors. Earlier complete sentences may already have been emitted.

  Requests use a shared HTTP/1 pool with a five-second connection timeout.
  The response-read budget excludes pool checkout, connection setup, and time
  blocked in the output callback. Use session or worker deadlines to bound the
  complete operation.
  Caller exit closes the checked-out connection. The adapter does not follow
  redirects or retry HTTP failures. Use HTTPS for cloud endpoints.
  """
  @behaviour AudioFlow.Adapter
  alias AudioFlow.{SSE, TextChunks}

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

    body =
      parameters
      |> Map.merge(%{"model" => model, "messages" => messages, "stream" => true, "n" => 1})
      |> JSON.encode!()

    if byte_size(body) > positive!(options, :max_request_bytes, 65_536) do
      {:error, :request_too_large}
    else
      request = Finch.build(:post, endpoint, headers(options), body)

      state = %{
        parser: SSE.new(positive!(options, :max_event_bytes, 16_384)),
        response_limit: positive!(options, :max_response_bytes, 262_144),
        text_limit: positive!(options, :max_text_bytes, 8_192),
        response_bytes: 0,
        text_bytes: 0,
        has_text?: false,
        pending: "",
        finished?: false,
        done?: false,
        content_type?: false,
        error: nil,
        emit: emit
      }

      timeout_options = [
        request_timeout: positive!(options, :timeout_ms, 30_000),
        receive_timeout: positive!(options, :receive_timeout_ms, 10_000),
        pool_timeout: positive!(options, :pool_timeout_ms, 5_000)
      ]

      case Finch.stream_while(
             request,
             AudioFlow.HTTPClient,
             state,
             &receive_http/2,
             timeout_options
           ) do
        {:ok, %{error: reason}} when reason != nil -> {:error, reason}
        {:ok, %{done?: true}} -> :ok
        {:ok, _} -> {:error, :incomplete_stream}
        {:error, _, %{error: reason}} when reason != nil -> {:error, reason}
        {:error, error, _} -> {:error, {:http, Exception.message(error)}}
      end
    end
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

  defp event("[DONE]", %{finished?: true, has_text?: false} = state),
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
    cond do
      Map.get(delta, "tool_calls") not in [nil, []] or Map.get(delta, "function_call") != nil ->
        fail(state, :unsupported_tool_call)

      Map.get(delta, "refusal") not in [nil, ""] ->
        fail(state, :refusal)

      Map.get(choice, "finish_reason") not in [nil, "stop"] ->
        fail(state, {:finish_reason, Map.get(choice, "finish_reason")})

      state.finished? ->
        fail(state, :content_after_finish)

      true ->
        case Map.get(delta, "content") do
          nil ->
            finish(choice, state)

          text when is_binary(text) ->
            if state.text_bytes + byte_size(text) > state.text_limit do
              fail(state, :text_too_large)
            else
              {sentences, pending} = TextChunks.push(state.pending, text)
              Enum.each(sentences, fn sentence -> :ok = state.emit.(sentence) end)

              finish(choice, %{
                state
                | pending: pending,
                  text_bytes: state.text_bytes + byte_size(text),
                  has_text?: state.has_text? or String.trim(text) != ""
              })
            end

          _ ->
            fail(state, :invalid_event)
        end
    end
  end

  defp finish(choice, state), do: {:cont, %{state | finished?: choice["finish_reason"] == "stop"}}
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
