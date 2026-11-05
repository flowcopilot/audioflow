defmodule AudioFlow.Avatars.LiveAvatar do
  @moduledoc """
  Finite-utterance LiveAvatar LITE publisher (not the retired Streaming Avatar API).

  `start_link/1` accepts `:owner`, `:api_key`, `:avatar_id`, and `:audio` (mono
  s16le at 24 kHz, at most ten seconds). It provisions a provider session and
  sends `{LiveAvatar, pid, {:published, %{url: url, token: token}}}` once the
  media websocket is connected. An authorized LiveKit client subscribes to
  that room's provider-generated synchronized audio and video tracks. Do not
  play the original PCM separately. The subscription token is sensitive.

  Set `:wait_for_viewer` to true to hold PCM until `viewer_ready/1` is called
  after subscribing to both tracks and enabling playback. The gate times out
  after 15 seconds and cleans up; default callers send immediately as before.

  The process ends after `agent.speak_ended`, failure, owner exit, cancellation
  or a 60 second deadline, and requests provider session stop. Cancellation
  closes the media websocket and stops the provider session; it cannot retract
  audio already rendered. No live service or lip-sync quality is certified.
  """
  use GenServer
  alias AudioFlow.Adapters.Providers.Socket

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  @doc "Release the opt-in `:wait_for_viewer` gate after subscribing both tracks."
  def viewer_ready(pid), do: GenServer.cast(pid, :viewer_ready)
  def cancel(pid), do: GenServer.stop(pid, :normal, 12_000)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    audio = Socket.audio!(Keyword.fetch!(opts, :audio), 24_000)

    if byte_size(audio.data) > 480_000,
      do: raise(ArgumentError, "maximum utterance is ten seconds")

    owner = Keyword.fetch!(opts, :owner)
    Process.monitor(owner)
    state = %{owner: owner, opts: opts, audio: audio, token: nil, worker: nil, timer: nil}
    {:ok, state, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, s) do
    case request(s.opts, "/v1/sessions/token", [{"x-api-key", Socket.key(s.opts)}], %{
           mode: "LITE",
           avatar_id: Keyword.fetch!(s.opts, :avatar_id)
         }) do
      {:ok, %{"session_token" => token}} -> start_session(%{s | token: token})
      _ -> fail(:token_failed, s)
    end
  end

  defp start_session(s) do
    case request(s.opts, "/v1/sessions/start", auth(s.token), %{}) do
      {:ok, %{"ws_url" => ws, "livekit_url" => url, "livekit_client_token" => client_token}} ->
        worker = start_worker(s, ws, %{url: url, token: client_token})
        {:noreply, %{s | worker: worker, timer: Process.send_after(self(), :deadline, 60_000)}}

      _ ->
        fail(:start_failed, s)
    end
  end

  defp start_worker(s, ws, published) do
    parent = self()
    id = uuid()
    on_published = fn -> publish(s, parent, published) end
    handle = fn event, state -> event(event, state, s.audio.data, id, on_published) end

    Task.Supervisor.async_nolink(AudioFlow.Tasks, fn ->
      Socket.run(ws, [], [], :waiting, handle, timeout_ms: 60_000, max_response_bytes: 2_000_000)
    end)
  end

  defp publish(s, parent, published) do
    send(s.owner, {__MODULE__, parent, {:published, published}})
    if Keyword.get(s.opts, :wait_for_viewer, false), do: await_viewer()
  end

  defp await_viewer do
    receive do
      :viewer_ready -> :ok
    after
      15_000 -> throw({:provider_socket, :viewer_timeout})
    end
  end

  @impl true
  def handle_cast(:viewer_ready, %{worker: %Task{pid: pid}} = s) do
    send(pid, :viewer_ready)
    {:noreply, s}
  end

  def handle_cast(:viewer_ready, s), do: {:noreply, s}

  @doc false
  def event(
        %{"type" => "session.state_updated", "state" => "connected"},
        :waiting,
        pcm,
        id,
        ready
      ) do
    ready.()

    frames =
      for chunk <- chunks(pcm),
          do: Socket.json(%{type: "agent.speak", event_id: id, audio: Base.encode64(chunk)})

    {:cont, :speaking, frames ++ [Socket.json(%{type: "agent.speak_end", event_id: id})]}
  end

  def event(%{"type" => "agent.speak_ended", "source_event_id" => id}, :speaking, _, id, _),
    do: :done

  def event(%{"type" => "error"}, _, _, _, _), do: {:error, :provider_error}

  def event(%{"type" => "session.state_updated", "state" => "disconnected"}, _, _, _, _),
    do: {:error, :disconnected}

  def event(_, state, _, _, _), do: {:cont, state, []}

  @impl true
  def handle_info({ref, result}, %{worker: %Task{ref: ref}} = s) do
    Process.demonitor(ref, [:flush])
    send(s.owner, {__MODULE__, self(), {:done, result}})
    {:stop, :normal, %{s | worker: nil}}
  end

  def handle_info({:DOWN, _, :process, owner, _}, %{owner: owner} = s), do: {:stop, :normal, s}

  def handle_info({:DOWN, ref, :process, _, _}, %{worker: %Task{ref: ref}} = s),
    do: fail(:socket_failed, %{s | worker: nil})

  def handle_info(:deadline, s), do: fail(:timeout, s)
  def handle_info({:EXIT, _, _}, s), do: {:stop, :normal, s}
  def handle_info(_, s), do: {:noreply, s}

  @impl true
  def terminate(_, s) do
    if s.timer, do: Process.cancel_timer(s.timer)
    if s.worker, do: Task.shutdown(s.worker, :brutal_kill)

    if s.token do
      result = request(s.opts, "/v1/sessions/stop", auth(s.token), %{reason: "USER_CLOSED"})

      send(
        s.owner,
        {__MODULE__, self(),
         {:cleanup, if(match?({:ok, _}, result), do: :ok, else: {:error, :stop_failed})}}
      )
    end

    :ok
  end

  defp fail(reason, s) do
    send(s.owner, {__MODULE__, self(), {:done, {:error, reason}}})
    {:stop, :normal, s}
  end

  defp auth(token), do: [{"authorization", "Bearer " <> token}]

  defp request(opts, path, headers, body) do
    endpoint = Keyword.get(opts, :endpoint, "https://api.liveavatar.com")

    req =
      Finch.build(
        :post,
        endpoint <> path,
        [{"content-type", "application/json"} | headers],
        JSON.encode!(body)
      )

    case Finch.request(req, AudioFlow.HTTPClient,
           receive_timeout: 3000,
           request_timeout: 3000,
           pool_timeout: 1000
         ) do
      {:ok, %{status: status, body: data}} when status in [200, 201] ->
        case JSON.decode(data) do
          {:ok, %{"code" => 100, "data" => result}} -> {:ok, result}
          _ -> {:error, :invalid_response}
        end

      _ ->
        {:error, :http_failed}
    end
  end

  defp chunks(<<>>), do: []

  defp chunks(pcm) do
    size = min(byte_size(pcm), 48_000)
    <<chunk::binary-size(^size), rest::binary>> = pcm
    [chunk | chunks(rest)]
  end

  defp uuid do
    <<a::32, b::16, _::4, c::12, _::2, d::14, e::48>> = :crypto.strong_rand_bytes(16)

    Enum.map_join([{a, 8}, {b, 4}, {0x4000 + c, 4}, {0x8000 + d, 4}, {e, 12}], "-", fn {n, w} ->
      Integer.to_string(n, 16) |> String.pad_leading(w, "0")
    end)
  end
end
