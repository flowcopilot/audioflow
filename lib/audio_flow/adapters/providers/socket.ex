defmodule AudioFlow.Adapters.Providers.Socket do
  @moduledoc false
  alias Mint.WebSocket, as: WS

  # Synchronous, caller-owned socket: terminating the turn closes the connection.
  # The byte budget also bounds fragmented messages before WebSocket decoding.
  def run(url, headers, frames, state, handler, options) do
    uri = URI.parse(url)

    unless (uri.scheme in ["ws", "wss"] and uri.host) && is_nil(uri.userinfo),
      do: raise(ArgumentError, "expected ws/wss endpoint without user information")

    timeout = positive!(options, :timeout_ms, 30_000)
    limit = positive!(options, :max_response_bytes, 16_777_216)
    deadline = System.monotonic_time(:millisecond) + timeout
    scheme = if uri.scheme == "wss", do: :https, else: :http
    port = uri.port || if(scheme == :https, do: 443, else: 80)
    path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")

    case Mint.HTTP.connect(scheme, uri.host, port,
           mode: :passive,
           protocols: [:http1],
           transport_opts: [timeout: timeout]
         ) do
      {:ok, conn} ->
        try do
          {:ok, conn, ref} =
            check(WS.upgrade(if(scheme == :https, do: :wss, else: :ws), conn, path, headers))

          {conn, status, headers, pending} = handshake(conn, ref, deadline, nil, [])
          {:ok, conn, ws} = check(WS.new(conn, ref, status, headers, mode: :passive))

          socket = %{
            conn: conn,
            ws: ws,
            ref: ref,
            deadline: deadline,
            bytes: 0,
            limit: limit
          }

          socket = send_frames(socket, frames)
          loop(socket, pending, state, handler)
        catch
          {:provider_socket, reason} -> {:error, reason}
        after
          Mint.HTTP.close(conn)
        end

      {:error, _} ->
        {:error, :connect_failed}
    end
  end

  defp check({:error, _, _}), do: throw({:provider_socket, :socket_error})
  defp check(result), do: result

  defp receive_data(conn, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining <= 0, do: throw({:provider_socket, :timeout})

    case WS.recv(conn, 0, remaining) do
      {:ok, conn, responses} ->
        {conn, responses}

      {:error, _, %Mint.TransportError{reason: :timeout}, _} ->
        throw({:provider_socket, :timeout})

      {:error, _, :timeout, _} ->
        throw({:provider_socket, :timeout})

      _ ->
        throw({:provider_socket, :incomplete_stream})
    end
  end

  defp handshake(conn, ref, deadline, status, headers) do
    {conn, responses} = receive_data(conn, deadline)

    {status, headers, done, data} =
      Enum.reduce(responses, {status, headers, false, []}, fn
        {:status, ^ref, value}, {_, h, d, rest} -> {value, h, d, rest}
        {:headers, ^ref, value}, {s, h, d, rest} -> {s, h ++ value, d, rest}
        {:done, ^ref}, {s, h, _, rest} -> {s, h, true, rest}
        response, {s, h, d, rest} -> {s, h, d, rest ++ [response]}
      end)

    cond do
      status && status != 101 -> throw({:provider_socket, {:http_status, status}})
      done -> {conn, status, headers, data}
      true -> handshake(conn, ref, deadline, status, headers)
    end
  end

  defp send_frames(socket, frames) do
    Enum.reduce(frames, socket, fn frame, socket ->
      {:ok, ws, data} = check(WS.encode(socket.ws, frame))
      {:ok, conn} = check(WS.stream_request_body(socket.conn, socket.ref, data))
      %{socket | ws: ws, conn: conn}
    end)
  end

  defp loop(socket, [], state, handler) do
    {conn, responses} = receive_data(socket.conn, socket.deadline)
    loop(%{socket | conn: conn}, responses, state, handler)
  end

  defp loop(socket, [{:data, _, data} | rest], state, handler) do
    socket = %{socket | bytes: socket.bytes + byte_size(data)}
    if socket.bytes > socket.limit, do: throw({:provider_socket, :response_too_large})
    {:ok, ws, frames} = check(WS.decode(socket.ws, data))

    case frames(%{socket | ws: ws}, frames, state, handler) do
      {:cont, socket, state} -> loop(socket, rest, state, handler)
      result -> result
    end
  end

  defp loop(_, _, _, _), do: {:error, :incomplete_stream}

  defp frames(socket, [], state, _), do: {:cont, socket, state}

  defp frames(socket, [{:ping, data} | rest], state, handler),
    do: frames(send_frames(socket, [{:pong, data}]), rest, state, handler)

  defp frames(socket, [{:pong, _} | rest], state, handler),
    do: frames(socket, rest, state, handler)

  defp frames(_socket, [{:close, _, _} | _], _state, _handler), do: {:error, :incomplete_stream}

  defp frames(socket, [{kind, data} | rest], state, handler) when kind in [:text, :binary] do
    case JSON.decode(data) do
      {:ok, event} when is_map(event) ->
        case handler.(event, state) do
          {:cont, state, outgoing} -> frames(send_frames(socket, outgoing), rest, state, handler)
          :done -> :ok
          {:error, _} = error -> error
        end

      _ ->
        {:error, :invalid_event}
    end
  end

  defp frames(_, _, _, _), do: {:error, :invalid_frame}

  def json(value), do: {:text, JSON.encode!(value)}

  def key(options) do
    case Keyword.fetch!(options, :api_key) do
      fun when is_function(fun, 0) -> fun.()
      key when is_binary(key) -> key
    end
  end

  def url(endpoint, params) do
    uri = URI.parse(endpoint)
    query = Map.merge(URI.decode_query(uri.query || ""), Map.new(params)) |> URI.encode_query()
    URI.to_string(%{uri | query: query})
  end

  def audio!(audio, rate \\ nil) do
    unless AudioFlow.Audio.valid?(audio) and audio.data != <<>> and
             byte_size(audio.data) <= 2_000_000 and (rate == nil or audio.sample_rate == rate),
           do:
             raise(
               ArgumentError,
               "expected nonempty mono s16le PCM, at most 2 MB, at the provider rate"
             )

    audio
  end

  def audio_event(data, rate, emit) when is_binary(data) do
    case Base.decode64(data) do
      {:ok, pcm} when rem(byte_size(pcm), 2) == 0 ->
        :ok = emit.({:audio, %AudioFlow.Audio{data: pcm, sample_rate: rate}})
        :ok

      _ ->
        {:error, :invalid_audio}
    end
  end

  def audio_event(_, _, _), do: {:error, :invalid_audio}

  def positive!(options, key, default) do
    value = Keyword.get(options, key, default)

    unless is_integer(value) and value > 0,
      do: raise(ArgumentError, "#{key} must be a positive integer")

    value
  end
end
