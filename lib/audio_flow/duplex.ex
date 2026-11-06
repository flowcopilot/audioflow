defmodule AudioFlow.Duplex do
  @schema NimbleOptions.new!(
            owner: [type: :pid, required: true, doc: "Receives the session messages."],
            adapter: [
              type: {:tuple, [:atom, :keyword_list]},
              required: true,
              doc: "`{module, options}` that implements `AudioFlow.Duplex.Adapter`."
            ],
            connect_timeout_ms: [
              type: :pos_integer,
              default: 15_000,
              doc: "Time from start to the model handshake."
            ],
            idle_timeout_ms: [
              type: :pos_integer,
              default: 30_000,
              doc: "Time after `:ready` or the last accepted push."
            ],
            max_session_ms: [type: :pos_integer, default: 1_800_000, doc: "Total session time."],
            max_chunk_bytes: [type: :pos_integer, default: 48_000, doc: "Largest push."],
            max_input_lead_ms: [
              type: :pos_integer,
              default: 2_000,
              doc: "Pushed audio not yet answered by model audio."
            ],
            max_owner_queue: [
              type: :pos_integer,
              default: 250,
              doc: "Owner mailbox length that fails the session."
            ],
            send_timeout_ms: [type: :pos_integer, default: 5_000, doc: "TCP send timeout."]
          )

  @moduledoc """
             One continuous full-duplex model connection. Input and output flow at the
             same time. There are no turns: no end-of-turn detection, no silence gate and
             no output drop while the user speaks. For committed turns, use
             `AudioFlow.Session`.

                 {:ok, duplex} =
                   AudioFlow.Duplex.start_link(owner: self(), adapter: {AudioFlow.Duplex.Moshi, []})

                 receive do
                   {AudioFlow.Duplex, ^duplex, :ready} -> :ok
                 end

                 :ok = AudioFlow.Duplex.push(duplex, %AudioFlow.Audio{data: pcm, sample_rate: 24_000})

             `start_link/1` returns before the connection opens. The owner then receives
             `{AudioFlow.Duplex, pid, event}` messages:

               * `:ready` after the model handshake. `push/2` returns
                 `{:error, :not_ready}` before it.
               * `{:audio, %AudioFlow.Audio{}}` and `{:text, text}` with model output, in
                 wire order.
               * `{:error, reason}` when the session fails. `:closed` follows.
               * `:closed` once, when the session stops for any reason except owner exit.

             Failure reasons: `:connect_failed`, `:connect_timeout`, `{:http_status, status}`,
             `:idle_timeout`, `:session_timeout`, `:connection_closed`, `:socket_error`,
             `:invalid_frame`, `:invalid_event`, `:owner_overloaded`, `:send_failed` and
             adapter reasons.

             The session stops when the owner exits. It stops with reason `:normal` on
             failure, timeout and `stop/1`, so a link to it does not stop the owner.

             ## Bounds

             Input that the model has not answered is at most `:max_input_lead_ms`.
             A push past that bound returns `{:error, :overloaded}` and the chunk is not
             sent. Output is sent to the owner at once and is not buffered. If the owner
             mailbox has `:max_owner_queue` messages or more, the session fails with
             `:owner_overloaded`. The owner must be a local process.

             """ <> NimbleOptions.docs(@schema)
  use GenServer
  alias AudioFlow.Adapters.Providers.Socket
  alias AudioFlow.Audio
  alias Mint.WebSocket, as: WS

  @call_timeout 5_000

  @doc "Starts a session. Raises `ArgumentError` for invalid options."
  def start_link(options) do
    options = NimbleOptions.validate!(options, @schema)
    owner = options[:owner]

    unless node(owner) == node(), do: raise(ArgumentError, "owner must be a local process")

    {module, adapter_options} = options[:adapter]
    Code.ensure_loaded!(module)
    config = module.config(adapter_options)
    Socket.endpoint!(config.url)
    GenServer.start_link(__MODULE__, {options, module, config})
  end

  @doc """
  Sends one mono s16le chunk at the adapter sample rate. Returns `:ok` after
  the frames are written to the socket.

  These errors leave the session open: `:not_ready`, `:invalid_audio`,
  `:too_large`, `:overloaded` and `:timeout` (no answer in 5 s). `:closed`
  means the session stopped. Other reasons fail the session.
  """
  def push(pid, audio) when is_pid(pid) do
    GenServer.call(pid, {:push, audio}, @call_timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :closed}
  end

  @doc "Stops the session and closes the connection. Returns `:ok` if it already stopped."
  def stop(pid) when is_pid(pid) do
    GenServer.stop(pid, :normal, @call_timeout)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init({options, module, config}) do
    Process.flag(:trap_exit, true)
    owner = options[:owner]
    server = self()
    lead = div(options[:max_input_lead_ms] * config.sample_rate, 1000)

    connector =
      spawn_link(fn ->
        send(
          server,
          {:connector, self(),
           connect(server, config, options[:connect_timeout_ms], options[:send_timeout_ms])}
        )
      end)

    {:ok,
     %{
       owner: owner,
       owner_ref: Process.monitor(owner),
       owner_alive: true,
       module: module,
       adapter: module.init(config.options),
       rate: config.sample_rate,
       phase: :connecting,
       connector: connector,
       conn: nil,
       ws: nil,
       ref: nil,
       pushed: 0,
       received: 0,
       max_lead: lead,
       max_chunk: options[:max_chunk_bytes],
       max_queue: options[:max_owner_queue],
       idle_ms: options[:idle_timeout_ms],
       connect_timer: :erlang.start_timer(options[:connect_timeout_ms], self(), :connect),
       session_timer: :erlang.start_timer(options[:max_session_ms], self(), :session),
       idle_timer: nil
     }}
  end

  @impl true
  def handle_call({:push, _audio}, _from, %{phase: phase} = state) when phase != :ready,
    do: {:reply, {:error, :not_ready}, state}

  def handle_call({:push, audio}, _from, state) do
    with :ok <- check_audio(audio, state),
         {:ok, frames, adapter} <- state.module.handle_audio(audio, state.adapter),
         {:ok, state} <- send_frames(%{state | adapter: adapter}, frames) do
      state = %{state | pushed: state.pushed + div(byte_size(audio.data), 2)}
      {:reply, :ok, restart_idle(state)}
    else
      {:error, reason} when reason in [:invalid_audio, :too_large, :overloaded] ->
        {:reply, {:error, reason}, state}

      {:error, reason, state} ->
        fail({:error, reason}, state, reason)

      {:error, reason} ->
        fail({:error, reason}, state, reason)
    end
  end

  defp check_audio(%Audio{} = audio, state) do
    samples = div(byte_size(audio.data), 2)

    cond do
      not Audio.valid?(audio) or audio.sample_rate != state.rate -> {:error, :invalid_audio}
      byte_size(audio.data) > state.max_chunk -> {:error, :too_large}
      state.pushed + samples - state.received > state.max_lead -> {:error, :overloaded}
      true -> :ok
    end
  end

  defp check_audio(_audio, _state), do: {:error, :invalid_audio}

  defp fail(reply, state, reason) do
    notify!(state, {:error, reason})
    {:stop, :normal, reply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, %{owner_ref: ref} = state),
    do: {:stop, :normal, %{state | owner_alive: false}}

  def handle_info({:EXIT, pid, reason}, %{connector: pid} = state) do
    state = %{state | connector: nil}
    if reason == :normal, do: {:noreply, state}, else: failed(state, :connect_failed)
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({:timeout, timer, kind}, state) do
    case {kind, state} do
      {:connect, %{connect_timer: ^timer}} -> failed(state, :connect_timeout)
      {:session, %{session_timer: ^timer}} -> failed(state, :session_timeout)
      {:idle, %{idle_timer: ^timer}} -> failed(state, :idle_timeout)
      _stale -> {:noreply, state}
    end
  end

  def handle_info({:connector, pid, {:ok, conn, ws, ref, pending}}, %{connector: pid} = state) do
    case Mint.HTTP.set_mode(conn, :active) do
      {:ok, conn} ->
        responses(%{state | conn: conn, ws: ws, ref: ref, phase: :open}, pending)

      {:error, _} ->
        Mint.HTTP.close(conn)
        failed(state, :socket_error)
    end
  end

  def handle_info({:connector, pid, {:error, reason}}, %{connector: pid} = state),
    do: failed(state, reason)

  def handle_info(message, %{conn: conn} = state) when conn != nil do
    case WS.stream(conn, message) do
      {:ok, conn, responses} ->
        responses(%{state | conn: conn}, responses)

      {:error, conn, %Mint.TransportError{reason: :closed}, _} ->
        failed(%{state | conn: conn}, :connection_closed)

      {:error, conn, _, _} ->
        failed(%{state | conn: conn}, :socket_error)

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.connector, do: Process.exit(state.connector, :kill)

    if state.conn do
      _ = send_frames(state, [{:close, 1000, ""}])
      Mint.HTTP.close(state.conn)
    end

    if state.owner_alive, do: send(state.owner, {__MODULE__, self(), :closed})
    :ok
  end

  defp failed(state, reason) do
    notify!(state, {:error, reason})
    {:stop, :normal, state}
  end

  defp responses(state, []), do: {:noreply, state}

  defp responses(%{ref: ref} = state, [{:data, ref, data} | rest]) do
    case WS.decode(state.ws, data) do
      {:ok, ws, frames} ->
        case frames(%{state | ws: ws}, frames) do
          {:ok, state} -> responses(state, rest)
          {:error, reason, state} -> failed(state, reason)
        end

      {:error, ws, _} ->
        failed(%{state | ws: ws}, :invalid_frame)
    end
  end

  defp responses(%{ref: ref} = state, [{:done, ref} | _]), do: failed(state, :connection_closed)
  defp responses(state, [_ | rest]), do: responses(state, rest)

  defp frames(state, []), do: {:ok, state}

  defp frames(state, [{:ping, data} | rest]) do
    with {:ok, state} <- send_frames(state, [{:pong, data}]), do: frames(state, rest)
  end

  defp frames(state, [{:pong, _} | rest]), do: frames(state, rest)
  defp frames(state, [{:close, _, _} | _]), do: {:error, :connection_closed, state}

  defp frames(state, [{kind, _} = frame | rest]) when kind in [:text, :binary] do
    with {:ok, events, outgoing, adapter} <- state.module.handle_frame(frame, state.adapter),
         {:ok, state} <- send_frames(%{state | adapter: adapter}, outgoing),
         {:ok, state} <- events(state, events) do
      frames(state, rest)
    else
      {:error, reason, state} -> {:error, reason, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp frames(state, _), do: {:error, :invalid_frame, state}

  defp events(state, []), do: {:ok, state}

  defp events(%{phase: :open} = state, [:ready | rest]) do
    :erlang.cancel_timer(state.connect_timer)
    state = restart_idle(%{state | phase: :ready, connect_timer: nil})
    with :ok <- notify(state, :ready), do: events(state, rest)
  end

  defp events(state, [{:audio, %Audio{} = audio} = event | rest]) do
    state = %{state | received: state.received + div(byte_size(audio.data), 2)}
    with :ok <- notify(state, event), do: events(state, rest)
  end

  defp events(state, [{:text, text} = event | rest]) when is_binary(text) do
    with :ok <- notify(state, event), do: events(state, rest)
  end

  defp events(state, _), do: {:error, :invalid_event, state}

  defp notify(state, event) do
    case Process.info(state.owner, :message_queue_len) do
      {:message_queue_len, length} when length >= state.max_queue ->
        {:error, :owner_overloaded, state}

      _ ->
        send(state.owner, {__MODULE__, self(), event})
        :ok
    end
  end

  defp notify!(state, event), do: send(state.owner, {__MODULE__, self(), event})

  defp restart_idle(state) do
    if state.idle_timer, do: :erlang.cancel_timer(state.idle_timer)
    %{state | idle_timer: :erlang.start_timer(state.idle_ms, self(), :idle)}
  end

  defp send_frames(state, frames) do
    Enum.reduce_while(frames, {:ok, state}, fn frame, {:ok, state} ->
      result =
        case WS.encode(state.ws, frame) do
          {:ok, ws, data} -> write(%{state | ws: ws}, data)
          {:error, ws, _} -> {:error, :send_failed, %{state | ws: ws}}
        end

      if match?({:ok, _}, result), do: {:cont, result}, else: {:halt, result}
    end)
  end

  defp write(state, data) do
    case WS.stream_request_body(state.conn, state.ref, data) do
      {:ok, conn} ->
        {:ok, %{state | conn: conn}}

      {:error, conn, %Mint.TransportError{reason: reason}}
      when reason in [:closed, :epipe, :econnreset] ->
        {:error, :connection_closed, %{state | conn: conn}}

      {:error, conn, _} ->
        {:error, :send_failed, %{state | conn: conn}}
    end
  end

  # Runs in a linked process, so the session answers calls while it connects.
  # The socket moves to the session after the WebSocket upgrade.
  defp connect(server, config, timeout, send_timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    transport = [send_timeout: send_timeout, send_timeout_close: true]

    case Socket.open(config.url, config.headers, deadline,
           mode: :active,
           transport_opts: transport
         ) do
      {:ok, conn, ws, ref, pending} ->
        case Mint.HTTP.controlling_process(conn, server) do
          {:ok, conn} ->
            {:ok, conn, ws, ref, pending}

          {:error, _} ->
            Mint.HTTP.close(conn)
            {:error, :connect_failed}
        end

      {:error, :timeout} ->
        {:error, :connect_timeout}

      {:error, {:http_status, _}} = error ->
        error

      {:error, _} ->
        {:error, :connect_failed}
    end
  end
end
