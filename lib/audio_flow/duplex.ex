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
            max_response_bytes: [
              type: :pos_integer,
              default: 67_108_864,
              doc:
                "Incoming WebSocket bytes in one `:response_window_ms` window, including partial frames."
            ],
            response_window_ms: [
              type: :pos_integer,
              default: 60_000,
              doc: "Length of the window of `:max_response_bytes`."
            ],
            max_message_bytes: [
              type: :pos_integer,
              default: 16_777_216,
              doc:
                "Incoming bytes of one WebSocket message, or of a partial frame that does not complete."
            ],
            clock: [
              type: {:fun, 0},
              default: &__MODULE__.now/0,
              doc:
                "Monotonic time in milliseconds, for the input pacing and the byte window. Replace it to control time."
            ],
            max_input_lead_ms: [
              type: :pos_integer,
              default: 2_000,
              doc:
                "Input lead. With adapter input flow `:answered`: pushed audio not yet answered by model audio. With `:realtime`: pushed audio ahead of the wall clock since `:ready`."
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
               * Adapters with model turn detection also send `{:speech_started, item}`,
                 `{:transcript, item, text | :failed}`, `{:response, id, status}` and
                 `{:output, item}`. See `AudioFlow.Duplex.Adapter`.
               * `{:error, reason}` when the session fails. `:closed` follows.
               * `:closed` once, when the session stops for any reason except owner exit.

             Failure reasons: `:connect_failed`, `:connect_timeout`, `{:http_status, status}`,
             `:idle_timeout`, `:session_timeout`, `:connection_closed`, `:socket_error`,
             `:invalid_frame`, `:invalid_event`, `:owner_overloaded`, `:send_failed` and
             adapter reasons.

             The session stops when the owner exits. It stops with reason `:normal` on
             failure, timeout and `stop/1`, so a link to it does not stop the owner.

             ## Bounds

             The adapter selects the input flow. With `:answered` (Moshi, one output
             frame for each input frame), input that the model has not answered is at
             most `:max_input_lead_ms`. With `:realtime` (OpenAI, output only when the
             model speaks), pushed audio is at most `:max_input_lead_ms` ahead of the
             wall clock since `:ready`, so continuous silence never overloads. A push
             past the bound returns `{:error, :overloaded}` and the chunk is not
             sent. Output is sent to the owner at once and is not buffered. If the owner
             mailbox has `:max_owner_queue` messages or more, the session fails with
             `:owner_overloaded`. The session reads the mailbox length only as often
             as the bound needs: after a read it skips the next events that cannot
             reach the bound (at most 32), so a large queue limit costs no round trip
             for each event. The owner must be a local process.

             Incoming bytes are bounded per message and per time window, not per
             session, so a long conversation does not end early. A message (or a
             partial frame) of more than `:max_message_bytes` fails the session with
             `:response_too_large`, and so do more than `:max_response_bytes` in one
             `:response_window_ms` window. OpenAI Realtime sends model speech as
             base64 JSON, about 64 KB for each second of speech, so the default
             window allows about 17 minutes of continuous speech in each minute of
             wall time. Windows do not slide, so a burst can use two windows.

             """ <> NimbleOptions.docs(@schema)
  use GenServer
  alias AudioFlow.Adapters.Providers.Socket
  alias AudioFlow.Audio
  alias Mint.WebSocket, as: WS

  @call_timeout 5_000

  @doc "Starts a session. Raises `ArgumentError` for invalid options."
  def start_link(options), do: start_session(options, :linked)

  @doc "Starts an unlinked session. The session still monitors its owner."
  def start(options), do: start_session(options, :unlinked)

  defp start_session(options, link) do
    options = NimbleOptions.validate!(options, @schema)
    owner = options[:owner]

    unless node(owner) == node(), do: raise(ArgumentError, "owner must be a local process")

    {module, adapter_options} = options[:adapter]
    Code.ensure_loaded!(module)
    config = module.config(adapter_options)
    Socket.endpoint!(config.url)

    unless Map.get(config, :input_flow, :answered) in [:answered, :realtime],
      do: raise(ArgumentError, "input_flow must be :answered or :realtime")

    args = {options, module, config}

    if link == :linked,
      do: GenServer.start_link(__MODULE__, args),
      else: GenServer.start(__MODULE__, args)
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

  @doc """
  Sends an adapter control command, for example playback progress. Returns
  `:ok`, `{:error, :not_ready}`, `{:error, :unsupported}` (the adapter has no
  controls), adapter errors such as `{:error, :stale}` (these leave the session
  open), `{:error, :timeout}` or `{:error, :closed}`.
  """
  def control(pid, command) when is_pid(pid) do
    GenServer.call(pid, {:control, command}, @call_timeout)
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

  # State version for hot code upgrades. Bump it when the state shape changes,
  # and migrate the old state in code_change/3 (see the hot-upgrades guide).
  @vsn 2

  @impl true
  def code_change(1, state, _extra) do
    {:ok,
     state
     |> Map.delete(:response_bytes)
     |> Map.merge(%{
       window_ms: 60_000,
       window_start: now(),
       window_bytes: 0,
       max_message: 16_777_216,
       partial_bytes: 0,
       clock: &__MODULE__.now/0,
       check_in: 0
     })}
  end

  def code_change({:down, 1}, state, _extra) do
    {:ok,
     state
     |> Map.drop([:window_ms, :window_start, :window_bytes, :max_message, :partial_bytes, :clock])
     |> Map.drop([:check_in])
     |> Map.put(:response_bytes, 0)}
  end

  def code_change(_old_vsn, state, _extra), do: {:ok, state}

  @doc false
  def now, do: System.monotonic_time(:millisecond)

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
       input_flow: Map.get(config, :input_flow, :answered),
       ready_at: nil,
       phase: :connecting,
       connector: connector,
       conn: nil,
       ws: nil,
       ref: nil,
       pushed: 0,
       received: 0,
       clock: options[:clock],
       window_ms: options[:response_window_ms],
       window_start: options[:clock].(),
       window_bytes: 0,
       partial_bytes: 0,
       max_response_bytes: options[:max_response_bytes],
       max_message: options[:max_message_bytes],
       check_in: 0,
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
  def handle_call({_kind, _value}, _from, %{phase: phase} = state) when phase != :ready,
    do: {:reply, {:error, :not_ready}, state}

  def handle_call({:control, command}, _from, state) do
    with true <- function_exported?(state.module, :handle_control, 2),
         {:ok, frames, adapter} <- state.module.handle_control(command, state.adapter),
         {:ok, state} <- send_frames(%{state | adapter: adapter}, frames) do
      {:reply, :ok, state}
    else
      false -> {:reply, {:error, :unsupported}, state}
      {:error, reason, state} -> fail({:error, reason}, state, reason)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

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
    cond do
      not Audio.valid?(audio) or audio.sample_rate != state.rate ->
        {:error, :invalid_audio}

      byte_size(audio.data) > state.max_chunk ->
        {:error, :too_large}

      state.pushed + div(byte_size(audio.data), 2) - allowance(state) > state.max_lead ->
        {:error, :overloaded}

      true ->
        :ok
    end
  end

  defp check_audio(_audio, _state), do: {:error, :invalid_audio}

  # Samples that the bound already counts as consumed.
  defp allowance(%{input_flow: :answered} = state), do: state.received

  defp allowance(%{input_flow: :realtime} = state),
    do: div((state.clock.() - state.ready_at) * state.rate, 1000)

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
    case account(state, byte_size(data)) do
      {:ok, state} -> decode_response(state, data, rest)
      :error -> failed(state, :response_too_large)
    end
  end

  defp responses(%{ref: ref} = state, [{:done, ref} | _]), do: failed(state, :connection_closed)
  defp responses(state, [_ | rest]), do: responses(state, rest)

  # Bytes count against the window, and against the message that is not
  # complete yet. A decode that returns frames ends the message.
  defp account(state, size) do
    now = state.clock.()

    {start, bytes} =
      if now - state.window_start >= state.window_ms,
        do: {now, 0},
        else: {state.window_start, state.window_bytes}

    bytes = bytes + size
    partial = state.partial_bytes + size

    if bytes > state.max_response_bytes or partial > state.max_message,
      do: :error,
      else: {:ok, %{state | window_start: start, window_bytes: bytes, partial_bytes: partial}}
  end

  defp decode_response(state, data, rest) do
    case WS.decode(state.ws, data) do
      {:ok, ws, frames} ->
        state = %{
          state
          | ws: ws,
            partial_bytes: if(frames == [], do: state.partial_bytes, else: 0)
        }

        case frames(state, frames) do
          {:ok, state} -> responses(state, rest)
          {:error, reason, state} -> failed(state, reason)
        end

      {:error, ws, _} ->
        failed(%{state | ws: ws}, :invalid_frame)
    end
  end

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

    state =
      restart_idle(%{
        state
        | phase: :ready,
          connect_timer: nil,
          ready_at: state.clock.()
      })

    with {:ok, state} <- notify(state, :ready), do: events(state, rest)
  end

  defp events(state, [{:audio, %Audio{} = audio} = event | rest]) do
    state = %{state | received: state.received + div(byte_size(audio.data), 2)}
    with {:ok, state} <- notify(state, event), do: events(state, rest)
  end

  defp events(state, [event | rest]) do
    if valid_event?(event) do
      with {:ok, state} <- notify(state, event), do: events(state, rest)
    else
      {:error, :invalid_event, state}
    end
  end

  @statuses [:created, :completed, :cancelled, :incomplete, :failed]

  defp valid_event?({:text, text}), do: is_binary(text)
  defp valid_event?({:speech_started, item}), do: is_binary(item)
  defp valid_event?({:output, item}), do: is_binary(item)

  defp valid_event?({:transcript, item, text}),
    do: is_binary(item) and (is_binary(text) or text == :failed)

  defp valid_event?({:response, id, status}), do: is_binary(id) and status in @statuses
  defp valid_event?(_event), do: false

  # The mailbox length is a signal to the owner. The owner only takes messages
  # out, so after a read of `length`, the next `max_queue - length - 1` events
  # cannot reach the bound from this session alone. Other senders can fill the
  # mailbox too, so the read is repeated every `@queue_check_every` events.
  @queue_check_every 32

  defp notify(%{check_in: 0} = state, event) do
    case Process.info(state.owner, :message_queue_len) do
      {:message_queue_len, length} when length >= state.max_queue ->
        {:error, :owner_overloaded, state}

      {:message_queue_len, length} ->
        check_in = min(state.max_queue - length - 1, @queue_check_every)
        send(state.owner, {__MODULE__, self(), event})
        {:ok, %{state | check_in: check_in}}

      nil ->
        send(state.owner, {__MODULE__, self(), event})
        {:ok, state}
    end
  end

  defp notify(state, event) do
    send(state.owner, {__MODULE__, self(), event})
    {:ok, %{state | check_in: state.check_in - 1}}
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
    # A header function keeps credentials out of the session state.
    headers = if is_function(config.headers, 0), do: config.headers.(), else: config.headers

    case Socket.open(config.url, headers, deadline,
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
