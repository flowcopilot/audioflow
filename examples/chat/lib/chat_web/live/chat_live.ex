defmodule ChatWeb.ChatLive do
  @moduledoc """
  One AudioFlow session per connected LiveView.

  The LiveView process owns the session and receives its turn events. Typed
  messages use `AudioFlow.Text`. While recording, the browser sends 16 kHz PCM
  chunks; the current STT model transcribes the recording so far and the user
  message shows that partial text. When recording stops, the complete audio is
  one session turn. Reply audio is pushed to the browser as it arrives, and the
  complete reply is kept as a WAV file for replay.

  The always-on modes (local Moshi and OpenAI live conversation) use
  `AudioFlow.Duplex`. From Start to Stop the browser sends 80 ms chunks of
  24 kHz PCM continuously, and the model audio and text come back at the same
  time. Moshi has no turns. OpenAI detects speech itself: when the user starts
  to speak, the browser flushes queued reply audio (the microphone stays open)
  and reports how much of the reply played, so the provider history keeps only
  that part. Each conversation has a generation number; events from an earlier
  generation are ignored.
  """
  use Phoenix.LiveView

  alias AudioFlow.Audio
  alias AudioFlow.Duplex
  alias AudioFlow.Recording.Store
  alias AudioFlow.Text
  alias Chat.Catalog
  alias Chat.Setup
  alias ChatWeb.Components.UI.Alert
  alias ChatWeb.Components.UI.Badge
  alias ChatWeb.Components.UI.Button
  alias ChatWeb.Components.UI.Card
  alias ChatWeb.Components.UI.Collapsible
  alias ChatWeb.Components.UI.Empty
  alias ChatWeb.Components.UI.Field
  alias ChatWeb.Components.UI.Item
  alias ChatWeb.Components.UI.NativeSelect
  alias ChatWeb.Components.UI.Spinner
  alias LiveAiElements.Components.AudioPlayer
  alias LiveAiElements.Components.Conversation
  alias LiveAiElements.Components.Message
  alias LiveAiElements.Components.PromptInput
  alias LiveAiElements.Components.Shimmer

  # Start a partial transcription after this much new audio (0.5 s).
  @partial_bytes 16_000
  # One duplex input chunk: 80 ms of 24 kHz mono s16le PCM.
  @call_chunk_bytes 3_840
  # Model text after this much silence starts a new message.
  @call_segment_ms 1_500
  @call_max_messages 200
  @call_max_message_bytes 4_000
  # User utterances that wait for their transcript.
  @call_max_pending 16
  # Seconds of model audio that the browser queues ahead of playback.
  @playback_ahead %{"moshi" => 1, "openai" => 60}

  @impl true
  def mount(_params, _session, socket) do
    settings = Setup.defaults()

    {session, setup_error} =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Chat.PubSub, Chat.Engine.topic())
        Process.send_after(self(), :retention, 60_000)
        open_session(settings)
      else
        {nil, nil}
      end

    {:ok,
     assign(socket,
       session: session,
       settings: settings,
       setup_error: setup_error,
       call: nil,
       call_status: "idle",
       call_error: nil,
       generation: 0,
       capture: nil,
       artifacts: [],
       playback_turn: nil,
       playback_token: nil,
       candidate: nil,
       control: nil,
       paused: false,
       played_ms: 0,
       models: Chat.Engine.status(),
       system_memory_gb: system_memory_gb(),
       turn: nil,
       status: "ready",
       messages: [],
       reply_id: nil,
       pcm: [],
       rate: nil,
       recording: nil
     )}
  end

  @impl true
  def handle_event("send", %{"text" => text}, socket) do
    settings = socket.assigns.settings

    case if(Setup.speech?(settings) or Setup.duplex?(settings), do: "", else: String.trim(text)) do
      "" ->
        {:reply, %{ok: false}, socket}

      text ->
        socket = cancel(socket) |> add_message("user", text)
        submit(socket, %Text{data: text})
    end
  end

  def handle_event(event, _params, %{assigns: %{session: nil}} = socket)
      when event in ["recording", "pause", "resume", "capture"],
      do: {:noreply, assign(socket, setup_error: "Not available without a turn-based session.")}

  def handle_event("recording", _params, socket) do
    socket = cancel(socket) |> add_message("user", "", pending: true, live: true)
    id = List.last(socket.assigns.messages).id

    {:noreply,
     assign(socket, recording: %{id: id, pcm: [], bytes: 0, task: nil, since: 0, invalid: false})}
  end

  def handle_event("voice_chunk", %{"pcm" => pcm}, %{assigns: %{recording: %{}}} = socket),
    do: {:noreply, socket |> append_audio(pcm) |> maybe_transcribe()}

  def handle_event("voice_end", %{"pcm" => pcm}, %{assigns: %{recording: %{}}} = socket) do
    socket = append_audio(socket, pcm)
    %{pcm: pcm, bytes: bytes, id: id, invalid: invalid} = socket.assigns.recording
    socket = assign(socket, recording: nil)

    if bytes == 0 or invalid do
      {:noreply, remove_message(socket, id)}
    else
      socket = update_message(socket, id, &%{&1 | text: "", pending: true})

      submit(socket, %Audio{
        data: IO.iodata_to_binary(pcm),
        sample_rate: Setup.rate(socket.assigns.settings)
      })
    end
  end

  def handle_event(event, _params, socket) when event in ["voice_chunk", "voice_end"],
    do: {:noreply, socket}

  def handle_event("recording_failed", %{"message" => message}, socket) do
    socket = if r = socket.assigns.recording, do: remove_message(socket, r.id), else: socket

    {:noreply,
     socket
     |> assign(recording: nil)
     |> add_message("assistant", "", note: "Microphone error: #{message}")}
  end

  def handle_event("pause", _, socket) do
    case AudioFlow.Output.provisional(socket.assigns.session, 10_000) do
      {:ok, id} -> {:noreply, assign(socket, candidate: id)}
      error -> {:noreply, assign(socket, setup_error: inspect(error))}
    end
  end

  def handle_event("resume", _, socket) do
    result = AudioFlow.Output.resolve(socket.assigns.session, socket.assigns.candidate, :resume)
    {:noreply, assign(socket, setup_error: if(result == :ok, do: nil, else: inspect(result)))}
  end

  def handle_event("output_ack", params, socket) do
    case socket.assigns.control do
      {turn, id, action} -> {:noreply, ack_output(socket, params, turn, id, action)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("output_failed", params, socket) do
    case socket.assigns.control do
      {turn, id, _} ->
        if params["token"] == Chat.Output.token(turn) and params["id"] == Chat.Output.token(id),
          do: {:noreply, cancel(socket)},
          else: {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("stop", _params, socket), do: {:noreply, cancel(socket)}

  def handle_event("new_chat", _params, socket) do
    socket = cancel(socket)
    if socket.assigns.session, do: AudioFlow.clear_history(socket.assigns.session)
    call = socket.assigns.call && %{socket.assigns.call | reply_id: nil}
    {:noreply, assign(socket, messages: [], call: call)}
  end

  def handle_event("call_start", _params, socket) do
    cond do
      not Setup.duplex?(socket.assigns.settings) ->
        {:reply, %{ok: false, error: "Select the full duplex pipeline first."}, socket}

      socket.assigns.call ->
        {:reply, %{ok: false, error: "A conversation is already active."}, socket}

      true ->
        # The adapter and endpoint come from the server settings, not from params.
        case Setup.options(socket.assigns.settings) do
          {:ok, [duplex: adapter]} ->
            start_call(socket, adapter, socket.assigns.settings["mode"] == "openai")

          {:error, message} ->
            {:reply, %{ok: false, error: message}, call_error(socket, message)}
        end
    end
  end

  def handle_event(
        "call_audio",
        %{"generation" => generation, "pcm" => pcm},
        %{assigns: %{call: %{generation: generation, ready: true} = call}} = socket
      )
      when is_binary(pcm) do
    with true <- byte_size(pcm) <= div(@call_chunk_bytes * 4, 3) + 4,
         {:ok, <<_::binary-size(@call_chunk_bytes)>> = data} <- Base.decode64(pcm),
         :ok <- Duplex.push(call.pid, %Audio{data: data, sample_rate: 24_000}) do
      {:reply, %{ok: true}, socket}
    else
      {:error, reason} -> {:reply, %{ok: false, error: describe(reason)}, socket}
      _ -> {:reply, %{ok: false, error: "invalid_chunk"}, socket}
    end
  end

  def handle_event("call_audio", _params, socket),
    do: {:reply, %{ok: false, error: "stale"}, socket}

  def handle_event("call_stop", %{"generation" => generation}, socket) do
    case socket.assigns.call do
      %{generation: ^generation} -> {:noreply, stop_call(socket, "idle")}
      _ -> {:noreply, socket}
    end
  end

  # Playback progress of the reply audio that a flush cut. The adapter caps it
  # to the received audio and ignores reports for any other reply.
  def handle_event(
        "call_played",
        %{"generation" => generation, "output" => output, "ms" => ms},
        %{assigns: %{call: %{generation: generation, ready: true} = call}} = socket
      )
      when is_binary(output) and byte_size(output) <= 256 and is_integer(ms) and ms >= 0 do
    _ = Duplex.control(call.pid, {:played, output, ms})
    {:noreply, socket}
  end

  def handle_event("call_played", _params, socket), do: {:noreply, socket}

  def handle_event("call_failed", %{"message" => message}, socket) when is_binary(message),
    do: {:noreply, call_error(socket, "Microphone error: " <> String.slice(message, 0, 200))}

  def handle_event("select_model", %{"_target" => [field]} = params, socket)
      when field in ["stt", "llm", "voice"] do
    result = Chat.Engine.select(String.to_existing_atom(field), params[field])

    {:noreply,
     assign(socket, setup_error: if(result == :ok, do: nil, else: "Native profile required"))}
  end

  def handle_event("configure", params, socket) do
    settings =
      Map.merge(socket.assigns.settings, Map.take(params, ["mode", "language", "voice", "tts"]))

    case Setup.options(settings) do
      {:error, message} ->
        {:noreply, assign(socket, setup_error: message)}

      {:ok, _options} ->
        if socket.assigns.recording || socket.assigns.turn || socket.assigns.call do
          {:noreply,
           assign(socket,
             setup_error:
               "Stop the current turn, recording or conversation before changing settings."
           )}
        else
          socket = cancel(socket)
          if socket.assigns.session, do: AudioFlow.stop_session(socket.assigns.session)
          Chat.Capture.close(socket.assigns.capture)
          {session, setup_error} = open_session(settings)

          {:noreply,
           assign(socket,
             session: session,
             settings: settings,
             messages: [],
             capture: nil,
             artifacts: [],
             setup_error: setup_error,
             call_status: "idle",
             call_error: nil
           )}
        end
    end
  end

  def handle_event("played", %{"token" => token, "ns" => ns}, socket)
      when is_integer(ns) and ns >= 0 do
    if token == socket.assigns.playback_token && socket.assigns.playback_turn do
      case GenServer.call(socket.assigns.session, {:played, socket.assigns.playback_turn, ns}) do
        :ok -> {:noreply, assign(socket, played_ms: div(ns, 1_000_000))}
        _ -> {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("capture", _, socket) do
    cond do
      socket.assigns.turn ->
        {:noreply, assign(socket, setup_error: "Change recording consent between turns.")}

      socket.assigns.capture ->
        Chat.Capture.close(socket.assigns.capture)
        {:noreply, assign(socket, capture: nil, artifacts: [])}

      true ->
        case Chat.Capture.open(socket.assigns.session) do
          {:ok, capture} -> {:noreply, assign(socket, capture: capture)}
          _ -> {:noreply, assign(socket, setup_error: "Cannot open recording store")}
        end
    end
  end

  def handle_event(action, %{"id" => id}, socket) when action in ["download", "delete"] do
    capture = socket.assigns.capture

    socket =
      if capture && id in Chat.Capture.list(capture),
        do: recording_action(socket, action, capture, id),
        else: assign(socket, setup_error: "Recording unavailable")

    {:noreply, socket}
  end

  defp ack_output(socket, params, turn, id, action) do
    with true <-
           params["token"] == Chat.Output.token(turn) and params["id"] == Chat.Output.token(id) and
             params["action"] == Atom.to_string(action),
         :ok <-
           AudioFlow.Output.control_ack(socket.assigns.session, turn, id, action, params["ns"]) do
      assign(socket,
        control: nil,
        paused: action == :pause,
        candidate: if(action == :pause, do: id),
        played_ms: div(params["ns"], 1_000_000)
      )
    else
      _ -> socket
    end
  end

  defp recording_action(socket, "delete", capture, id) do
    Store.delete(capture.store, id)
    assign(socket, artifacts: Chat.Capture.list(capture))
  end

  defp recording_action(socket, "download", capture, id) do
    case Store.read(capture.store, id) do
      {:ok, data} -> push_event(socket, "download", %{name: id, data: Jason.encode!(data)})
      _ -> assign(socket, setup_error: "Recording expired")
    end
  end

  defp open_session(settings) do
    case Setup.options(settings) do
      {:ok, [duplex: _]} ->
        {nil, nil}

      {:ok, options} ->
        {:ok, session} = AudioFlow.start_session(options ++ [output: {Chat.Output, self()}])
        {session, nil}

      {:error, message} ->
        {nil, message}
    end
  end

  # `turns`: the model marks user speech and replies (OpenAI). Without turns
  # (Moshi), a pause in the model text starts a new message.
  defp start_call(socket, adapter, turns) do
    generation = socket.assigns.generation + 1
    socket = assign(socket, generation: generation)

    case start_duplex(adapter) do
      {:ok, pid} ->
        call = %{
          pid: pid,
          monitor: Process.monitor(pid),
          generation: generation,
          ready: false,
          turns: turns,
          reply_id: nil,
          reply_response: nil,
          text_at: nil,
          output: nil,
          users: []
        }

        {:reply, %{ok: true, generation: generation},
         assign(socket, call: call, call_status: "connecting", call_error: nil)}

      {:error, reason} ->
        message = "Cannot start the conversation: " <> describe(reason)
        {:reply, %{ok: false, error: message}, call_error(socket, message)}
    end
  end

  # A model failure must not stop the LiveView. Duplex monitors this owner.
  defp start_duplex(adapter) do
    limits =
      if elem(adapter, 0) == Duplex.OpenAIRealtime,
        do: [max_response_bytes: 256 * 1024 * 1024],
        else: []

    Duplex.start([owner: self(), adapter: adapter] ++ limits)
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp call_event(%{assigns: %{call: %{turns: true} = call}} = socket, :ready) do
    socket
    |> assign(call: %{call | ready: true}, call_status: "live")
    |> push_event("call_ready", %{generation: call.generation})
  end

  defp call_event(socket, :ready) do
    %{call: call} = socket.assigns
    socket = add_message(socket, "assistant", "", pending: true, live: true)

    socket
    |> assign(
      call: %{call | ready: true, reply_id: List.last(socket.assigns.messages).id},
      call_status: "live"
    )
    |> push_event("call_ready", %{generation: call.generation})
  end

  defp call_event(socket, {:audio, %Audio{data: data, sample_rate: rate}}) do
    %{call: call} = socket.assigns

    push_event(socket, "call_play", %{
      generation: call.generation,
      output: call.output,
      pcm: Base.encode64(data),
      rate: rate
    })
  end

  defp call_event(socket, {:text, text}), do: call_text(socket, text)

  # The user starts to speak: queued reply audio is obsolete. The browser
  # flushes it and keeps the microphone open.
  defp call_event(socket, {:speech_started, item}) do
    %{call: call} = socket.assigns
    socket = add_message(socket, "user", "", pending: true, live: true)

    pending = call.users ++ [{item, List.last(socket.assigns.messages).id}]
    {removed, users} = Enum.split(pending, max(length(pending) - @call_max_pending, 0))
    socket = Enum.reduce(removed, socket, fn {_, id}, socket -> settle(socket, id) end)

    socket
    |> assign(call: %{call | output: nil, users: users})
    |> push_event("call_flush", %{generation: call.generation})
    |> trim_messages()
  end

  defp call_event(socket, {:transcript, item, text}) do
    %{call: call} = socket.assigns

    case List.keytake(call.users, item, 0) do
      {{_, id}, users} -> socket |> assign(call: %{call | users: users}) |> transcript(id, text)
      nil -> socket
    end
  end

  defp call_event(socket, {:response, id, :created}) do
    %{call: call} = socket.assigns
    socket = if call.reply_id, do: settle(socket, call.reply_id), else: socket
    socket = add_message(socket, "assistant", "", pending: true)

    assign(socket,
      call: %{call | reply_id: List.last(socket.assigns.messages).id, reply_response: id}
    )
    |> trim_messages()
  end

  defp call_event(
         %{assigns: %{call: %{reply_response: id} = call}} = socket,
         {:response, id, status}
       ) do
    socket
    |> update_message(call.reply_id, &%{&1 | note: reply_note(status, &1.text)})
    |> settle(call.reply_id)
    |> assign(call: %{call | reply_id: nil, reply_response: nil})
  end

  defp call_event(socket, {:response, _id, _status}), do: socket

  defp call_event(socket, {:output, item}),
    do: assign(socket, call: %{socket.assigns.call | output: item})

  defp call_event(socket, {:error, reason}),
    do: call_error(socket, "Conversation error: " <> describe(reason))

  defp call_event(socket, :closed), do: stop_call(socket, "closed")
  defp call_event(socket, _event), do: socket

  defp transcript(socket, id, :failed),
    do: update_message(socket, id, &%{&1 | pending: false, live: false, note: "Not transcribed."})

  defp transcript(socket, id, text) do
    case String.trim(text) do
      "" -> remove_message(socket, id)
      text -> update_message(socket, id, &%{&1 | text: text, pending: false, live: false})
    end
  end

  # A reply cancelled before any text gets no note, so `settle/2` removes it.
  defp reply_note(:cancelled, ""), do: nil
  defp reply_note(:cancelled, _text), do: "Interrupted."
  defp reply_note(:incomplete, _text), do: "Reply incomplete."
  defp reply_note(:failed, _text), do: "Reply failed."
  defp reply_note(:completed, _text), do: nil

  defp call_text(%{assigns: %{call: %{turns: true, reply_id: id}}} = socket, text)
       when id != nil,
       do: update_message(socket, id, &%{&1 | text: &1.text <> text, pending: false})

  defp call_text(%{assigns: %{call: %{turns: true}}} = socket, _text), do: socket

  # Moshi does not mark turns. A pause in the model text starts a new message,
  # and the conversation keeps only the latest messages.
  defp call_text(socket, text) do
    %{call: call, messages: messages} = socket.assigns
    now = System.monotonic_time(:millisecond)
    current = call.reply_id && Enum.find(messages, &(&1.id == call.reply_id))

    socket =
      if current == nil or (call.text_at != nil and now - call.text_at >= @call_segment_ms) or
           byte_size(current.text) >= @call_max_message_bytes do
        socket = if current, do: settle(socket, current.id), else: socket
        socket = add_message(socket, "assistant", "")
        assign(socket, call: %{call | reply_id: List.last(socket.assigns.messages).id})
      else
        socket
      end

    %{call: call} = socket.assigns

    socket
    |> update_message(call.reply_id, fn message ->
      text = if message.text == "", do: String.trim_leading(text), else: text
      %{message | text: message.text <> text, pending: false, live: false}
    end)
    |> trim_messages()
    |> assign(call: %{call | text_at: now})
  end

  defp trim_messages(socket),
    do: assign(socket, messages: Enum.take(socket.assigns.messages, -@call_max_messages))

  # A message without text or note is removed; otherwise it stops waiting.
  defp settle(socket, id) do
    case Enum.find(socket.assigns.messages, &(&1.id == id)) do
      %{text: "", note: nil} -> remove_message(socket, id)
      %{} -> update_message(socket, id, &%{&1 | pending: false, live: false})
      nil -> socket
    end
  end

  defp call_error(socket, message), do: stop_call(socket, "error", message)

  # Stops the conversation process and tells the browser to release the
  # microphone and the queued playback of this generation.
  defp stop_call(socket, status, error \\ nil) do
    socket =
      case socket.assigns.call do
        nil ->
          socket

        call ->
          Process.demonitor(call.monitor, [:flush])

          try do
            Duplex.stop(call.pid)
          catch
            :exit, _ -> :ok
          end

          call.users
          |> Enum.reduce(settle(socket, call.reply_id), fn {_, id}, socket ->
            settle(socket, id)
          end)
          |> push_event("call_stopped", %{generation: call.generation})
      end

    assign(socket, call: nil, call_status: status, call_error: error)
  end

  defp describe({:remote_error, code}) when is_binary(code), do: "provider error " <> code
  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp describe(reason), do: inspect(reason)

  @impl true
  def terminate(_, socket) do
    stop_call(socket, "closed")
    Chat.Capture.close(socket.assigns.capture)
    if socket.assigns.session, do: AudioFlow.stop_session(socket.assigns.session)
    :ok
  end

  @impl true
  def handle_info({Chat.Output, {:start, turn, token}}, socket),
    do:
      {:noreply,
       socket
       |> assign(playback_turn: turn, playback_token: token)
       |> push_event("output_start", %{token: token})}

  def handle_info({Chat.Output, {:pcm, turn, token, audio}}, socket) do
    if turn == socket.assigns.playback_turn do
      {:noreply,
       push_event(socket, "play", %{
         pcm: Base.encode64(audio.data),
         rate: audio.sample_rate,
         token: token
       })}
    else
      {:noreply, socket}
    end
  end

  def handle_info({Chat.Output, {:control, turn, id, action}}, socket) do
    {:noreply,
     socket
     |> assign(control: {turn, id, action})
     |> push_event(
       "output_control",
       %{token: Chat.Output.token(turn), id: Chat.Output.token(id), action: action}
     )}
  end

  def handle_info({Chat.Output, {:flush, turn}}, socket) do
    {:noreply,
     socket
     |> assign(candidate: nil, control: nil, paused: false)
     |> push_event("flush", %{token: Chat.Output.token(turn)})}
  end

  def handle_info(:retention, socket) do
    Process.send_after(self(), :retention, 60_000)
    {:noreply, assign(socket, artifacts: Chat.Capture.list(socket.assigns.capture))}
  end

  def handle_info(
        {AudioFlow, session, turn, event},
        %{assigns: %{session: session, turn: turn}} = socket
      ),
      do:
        {:noreply,
         socket |> capture_event({AudioFlow, session, turn, event}) |> turn_event(event)}

  def handle_info({AudioFlow, session, _, _} = event, %{assigns: %{session: session}} = socket),
    do: {:noreply, capture_event(socket, event)}

  def handle_info({AudioFlow, _, _, _}, socket), do: {:noreply, socket}

  def handle_info({Duplex, pid, event}, %{assigns: %{call: %{pid: pid}}} = socket),
    do: {:noreply, call_event(socket, event)}

  def handle_info({Duplex, _, _}, socket), do: {:noreply, socket}

  def handle_info(
        {:DOWN, ref, :process, _, reason},
        %{assigns: %{call: %{monitor: ref}}} = socket
      ),
      do: {:noreply, call_error(socket, "Conversation stopped: " <> describe(reason))}

  def handle_info({:models, models}, socket), do: {:noreply, assign(socket, models: models)}

  def handle_info({ref, result}, %{assigns: %{recording: %{task: ref} = recording}} = socket) do
    Process.demonitor(ref, [:flush])

    socket =
      case result do
        {:ok, text} -> update_message(socket, recording.id, &%{&1 | text: text})
        {:error, _} -> socket
      end

    {:noreply, socket |> assign(recording: %{recording | task: nil}) |> maybe_transcribe()}
  end

  def handle_info(
        {:DOWN, ref, :process, _, _},
        %{assigns: %{recording: %{task: ref} = r}} = socket
      ),
      do: {:noreply, assign(socket, recording: %{r | task: nil})}

  def handle_info({ref, _}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, socket}
  end

  def handle_info({:DOWN, _, :process, _, _}, socket), do: {:noreply, socket}

  defp capture_event(%{assigns: %{capture: nil}} = socket, _), do: socket

  defp capture_event(socket, event) do
    case AudioFlow.Recording.consume(socket.assigns.capture, event) do
      {:ok, capture, _} ->
        assign(socket, capture: capture, artifacts: Chat.Capture.list(capture))

      {:error, _, capture} ->
        assign(socket,
          capture: capture,
          artifacts: Chat.Capture.list(capture),
          setup_error: "Recording skipped: storage or recording limit. Inference continues."
        )
    end
  end

  defp turn_event(socket, {:transcript, text}) do
    update_last(socket, "user", fn message ->
      if message.live,
        do: %{message | text: text, live: false},
        else: %{message | text: message.text <> text}
    end)
  end

  defp turn_event(socket, {:text, text}) do
    socket
    |> assign(status: "streaming")
    |> update_last("user", &%{&1 | pending: false, live: false})
    |> update_message(socket.assigns.reply_id, &%{&1 | text: &1.text <> text})
  end

  defp turn_event(socket, {:audio, %Audio{data: data, sample_rate: rate}}) do
    socket
    |> assign(pcm: [socket.assigns.pcm, data], rate: rate)
  end

  defp turn_event(socket, {:done, metrics}) do
    audio =
      if socket.assigns.rate,
        do: %{
          media_type: "audio/wav",
          base64:
            Base.encode64(
              AudioFlow.Wav.encode(%AudioFlow.Audio{
                data: IO.iodata_to_binary(socket.assigns.pcm),
                sample_rate: socket.assigns.rate
              })
            )
        }

    finish(socket,
      audio: audio,
      note: if(metrics.first_text_us, do: nil, else: "No speech was recognized.")
    )
  end

  defp turn_event(socket, {:cancelled, _metrics}), do: finish(socket, note: "Stopped.")

  defp turn_event(socket, {:error, reason, _metrics}),
    do: finish(socket, note: "Error: #{inspect(reason)}")

  defp turn_event(socket, _event), do: socket

  defp submit(%{assigns: %{session: nil}} = socket, _input), do: {:reply, %{ok: false}, socket}

  defp submit(socket, input) do
    case AudioFlow.submit(socket.assigns.session, input) do
      {:ok, turn} ->
        socket = add_message(socket, "assistant", "", pending: true)

        {:reply, %{ok: true},
         assign(socket,
           turn: turn,
           playback_turn: turn,
           playback_token: Chat.Output.token(turn),
           played_ms: 0,
           status: "submitted",
           reply_id: List.last(socket.assigns.messages).id,
           pcm: [],
           rate: nil
         )}

      {:error, reason} ->
        {:reply, %{ok: false},
         socket
         |> update_last("user", &%{&1 | pending: false, live: false})
         |> add_message("assistant", "", note: "Not sent: #{inspect(reason)}")}
    end
  end

  defp append_audio(socket, pcm) do
    case Base.decode64(pcm) do
      {:ok, data} ->
        r = socket.assigns.recording

        if rem(byte_size(data), 2) == 0 and
             r.bytes + byte_size(data) <= Setup.rate(socket.assigns.settings) * 60,
           do:
             assign(socket,
               recording: %{r | pcm: [r.pcm, data], bytes: r.bytes + byte_size(data)}
             ),
           else: invalid_audio(socket)

      :error ->
        invalid_audio(socket)
    end
  end

  defp invalid_audio(socket) do
    assign(socket,
      recording: %{socket.assigns.recording | invalid: true, pcm: [], bytes: 0},
      setup_error: "Microphone input rejected: invalid PCM or duration exceeds 30 seconds."
    )
  end

  defp maybe_transcribe(%{assigns: %{recording: %{invalid: true}}} = socket), do: socket

  defp maybe_transcribe(%{assigns: %{settings: %{"mode" => mode}}} = socket) when mode != "local",
    do: socket

  defp maybe_transcribe(%{assigns: %{recording: %{task: nil} = r}} = socket)
       when r.bytes - r.since >= @partial_bytes do
    audio = %Audio{data: IO.iodata_to_binary(r.pcm), sample_rate: 16_000}
    task = Task.Supervisor.async_nolink(Chat.Tasks, fn -> Chat.Engine.transcribe(audio) end)
    assign(socket, recording: %{r | task: task.ref, since: r.bytes})
  end

  defp maybe_transcribe(socket), do: socket

  defp cancel(socket) do
    # The cancelled event arrives after this call and closes the reply.
    if socket.assigns.session, do: AudioFlow.cancel(socket.assigns.session)

    socket =
      if socket.assigns.turn,
        do: finish(socket, note: "Stopped."),
        else: socket

    socket |> assign(candidate: nil, control: nil, paused: false) |> push_event("flush", %{})
  end

  defp finish(socket, fields) do
    socket
    |> update_last("user", &%{&1 | pending: false, live: false})
    |> update_message(
      socket.assigns.reply_id,
      &Map.merge(&1, Map.new([pending: false] ++ fields))
    )
    |> assign(turn: nil, status: "ready", reply_id: nil, pcm: [], rate: nil)
  end

  defp add_message(socket, role, text, fields \\ []) do
    message =
      Map.merge(
        %{
          id: "m#{System.unique_integer([:positive])}",
          role: role,
          text: text,
          pending: false,
          live: false,
          note: nil,
          audio: nil
        },
        Map.new(fields)
      )

    assign(socket, messages: socket.assigns.messages ++ [message])
  end

  defp remove_message(socket, id),
    do: assign(socket, messages: Enum.reject(socket.assigns.messages, &(&1.id == id)))

  defp update_message(socket, id, fun) do
    messages = Enum.map(socket.assigns.messages, &if(&1.id == id, do: fun.(&1), else: &1))
    assign(socket, messages: messages)
  end

  defp update_last(socket, role, fun) do
    live = socket.assigns.recording && socket.assigns.recording.id

    case Enum.reverse(socket.assigns.messages)
         |> Enum.find(&(&1.role == role and &1.id != live)) do
      nil -> socket
      message -> update_message(socket, message.id, fun)
    end
  end

  defp system_memory_gb do
    case System.cmd("sysctl", ["-n", "hw.memsize"], stderr_to_stdout: true) do
      {bytes, 0} -> String.to_integer(String.trim(bytes)) / 1_073_741_824
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp status_text(:loading), do: "Loading…"
  defp status_text({:error, reason}), do: "Failed: #{reason}"
  defp status_text(_), do: nil

  # Apple Silicon shares memory between the CPU and GPU. Leave room for the system.
  defp fit_text(nil), do: "Larger models answer more slowly."

  defp fit_text(memory) do
    if Catalog.max_memory_gb() <= memory * 0.6,
      do: "Every combination fits in memory. Larger models answer more slowly.",
      else: "The largest combinations may not fit in memory."
  end

  defp call_label("connecting"), do: "Connecting…"
  defp call_label("live"), do: "Live · microphone on"
  defp call_label("closed"), do: "Conversation ended"
  defp call_label("error"), do: "Stopped by an error"
  defp call_label(_), do: "Not connected"

  defp call_variant("live"), do: "default"
  defp call_variant("error"), do: "destructive"
  defp call_variant(_), do: "secondary"

  defp gb(value), do: :erlang.float_to_binary(value * 1.0, decimals: 1)

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        stt_models: Catalog.stt(),
        llm_models: Catalog.llm(),
        voices: Catalog.voices(),
        duplex: Setup.duplex?(assigns.settings),
        playback_ahead: @playback_ahead
      )

    ~H"""
    <div id="chat" phx-hook="Player" class="mx-auto flex h-svh max-w-3xl flex-col gap-4 p-4">
      <header class="flex items-center justify-between gap-4">
        <h1 class="flex items-center gap-2.5 text-lg font-bold">
          <svg viewBox="0 0 32 32" aria-hidden="true" class="size-7">
            <rect width="32" height="32" rx="8" fill="#5B2E91" />
            <g stroke="#7CE0C3" stroke-width="2.4" stroke-linecap="round">
              <path d="M8 14v4" /><path d="M12 10v12" /><path d="M16 7v18" /><path d="M20 11v10" /><path d="M24 14v4" />
            </g>
          </svg>
          AudioFlow
        </h1>
        <Button.button variant="outline" size="sm" phx-click="new_chat">
          {if @duplex, do: "Clear text", else: "New chat"}
        </Button.button>
      </header>

      <form id="configuration" phx-submit="configure" class="flex flex-wrap items-end gap-3 text-sm">
        <Field.field class="w-auto gap-1.5">
          <Field.field_label for="setting-mode">Provider</Field.field_label>
          <NativeSelect.native_select id="setting-mode" name="mode" size="sm">
            <NativeSelect.native_select_option
              :for={{id, label} <- Setup.modes()}
              value={id}
              selected={@settings["mode"] == id}
            >
              {label}
            </NativeSelect.native_select_option>
          </NativeSelect.native_select>
        </Field.field>
        <Field.field :if={@settings["mode"] == "openai"} class="w-auto gap-1.5">
          <Field.field_label for="setting-voice">Voice</Field.field_label>
          <NativeSelect.native_select id="setting-voice" name="voice" size="sm">
            <NativeSelect.native_select_option
              :for={voice <- Setup.voices()}
              value={voice}
              selected={@settings["voice"] == voice}
            >
              {voice}
            </NativeSelect.native_select_option>
          </NativeSelect.native_select>
        </Field.field>
        <Field.field :if={@settings["mode"] == "remote"} class="w-auto gap-1.5">
          <Field.field_label for="setting-language">Language</Field.field_label>
          <NativeSelect.native_select id="setting-language" name="language" size="sm">
            <NativeSelect.native_select_option
              :for={lang <- Setup.languages()}
              value={lang}
              selected={@settings["language"] == lang}
            >
              {lang}
            </NativeSelect.native_select_option>
          </NativeSelect.native_select>
        </Field.field>
        <Field.field :if={@settings["mode"] == "remote"} class="w-auto gap-1.5">
          <Field.field_label for="setting-tts">Voice service</Field.field_label>
          <NativeSelect.native_select id="setting-tts" name="tts" size="sm">
            <NativeSelect.native_select_option
              :for={tts <- Setup.tts_providers()}
              value={tts}
              selected={@settings["tts"] == tts}
            >
              {tts}
            </NativeSelect.native_select_option>
          </NativeSelect.native_select>
        </Field.field>
        <Button.button type="submit" variant="outline" size="sm" disabled={@call != nil}>
          Apply
        </Button.button>
      </form>
      <Alert.alert :if={@setup_error} variant="destructive">
        <LiveShadcn.Icon.icon name="circle-alert" />
        <Alert.alert_description>{@setup_error}</Alert.alert_description>
      </Alert.alert>
      <form
        :if={@settings["mode"] == "local"}
        id="models"
        phx-change="select_model"
        class="grid gap-3 sm:grid-cols-3"
      >
        <.model_field label="Speech recognition" for="model-stt" status={@models.status[:stt]}>
          <NativeSelect.native_select id="model-stt" name="stt" size="sm" class="w-full">
            <NativeSelect.native_select_option
              :for={model <- @stt_models}
              value={model.id}
              selected={model.id == @models.selection.stt}
            >
              {model.label} · {gb(model.memory_gb)} GB
            </NativeSelect.native_select_option>
          </NativeSelect.native_select>
        </.model_field>
        <.model_field label="Reply model" for="model-llm" status={@models.status[:llm]}>
          <NativeSelect.native_select id="model-llm" name="llm" size="sm" class="w-full">
            <NativeSelect.native_select_option
              :for={model <- @llm_models}
              value={model.id}
              selected={model.id == @models.selection.llm}
            >
              {model.label} · {gb(model.memory_gb)} GB
            </NativeSelect.native_select_option>
          </NativeSelect.native_select>
        </.model_field>
        <.model_field label="Voice (Kokoro)" for="model-voice" status={@models.status[:tts]}>
          <NativeSelect.native_select id="model-voice" name="voice" size="sm" class="w-full">
            <NativeSelect.native_select_option
              :for={voice <- @voices}
              value={voice.id}
              selected={voice.id == @models.selection.voice}
            >
              {voice.label}
            </NativeSelect.native_select_option>
          </NativeSelect.native_select>
        </.model_field>
      </form>

      <Card.card :if={@duplex} id="duplex" size="sm">
        <Card.card_content class="flex flex-wrap items-center gap-3">
          <div
            id="duplex-io"
            phx-hook="Duplex"
            phx-update="ignore"
            data-playback-ahead={@playback_ahead[@settings["mode"]]}
          >
          </div>
          <Button.button type="button" data-call="start" disabled={@call != nil}>
            <LiveShadcn.Icon.icon name="phone" /> Start conversation
          </Button.button>
          <Button.button type="button" variant="destructive" data-call="stop" disabled={@call == nil}>
            <LiveShadcn.Icon.icon name="phone-off" /> Stop
          </Button.button>
          <div id="duplex-status" role="status" class="flex items-center gap-2 text-sm">
            <Spinner.spinner :if={@call_status == "connecting"} class="size-3" />
            <Badge.badge variant={call_variant(@call_status)}>{call_label(@call_status)}</Badge.badge>
          </div>
          <Alert.alert :if={@call_error} variant="destructive" class="w-full">
            <LiveShadcn.Icon.icon name="circle-alert" />
            <Alert.alert_description>{@call_error}</Alert.alert_description>
          </Alert.alert>
          <.disclosure id="duplex-diagnostics" title="Diagnostics" class="w-full">
            <span id="duplex-stats" phx-update="ignore"></span>
          </.disclosure>
        </Card.card_content>
      </Card.card>
      <.disclosure :if={not @duplex} id="settings" title="Settings">
        <div class="grid gap-2">
          <p :if={@settings["mode"] == "local"} class="text-xs text-muted-foreground">
            ≈ {gb(@models.memory_gb)} GB of model weights{if @system_memory_gb,
              do: " · #{gb(@system_memory_gb)} GB memory"}. {fit_text(@system_memory_gb)}
          </p>
          <div class="flex flex-wrap items-center gap-2">
            <Button.button type="button" variant="outline" size="sm" phx-click="capture">
              {if @capture, do: "Delete saved transcripts", else: "Save redacted transcripts"}
            </Button.button>
            <span class="text-xs text-muted-foreground">
              Text only, with all words replaced by [REDACTED]. Deleted when you leave.
            </span>
          </div>
          <Item.item :for={id <- @artifacts} variant="outline" size="xs">
            <Item.item_content>
              <Item.item_title class="font-mono text-xs">{id}</Item.item_title>
            </Item.item_content>
            <Item.item_actions>
              <Button.button variant="ghost" size="sm" phx-click="download" phx-value-id={id}>
                Download
              </Button.button>
              <Button.button variant="ghost" size="sm" phx-click="delete" phx-value-id={id}>
                Delete
              </Button.button>
            </Item.item_actions>
          </Item.item>
        </div>
      </.disclosure>
      <Conversation.conversation id="chat-log" class="rounded-lg border">
        <Empty.empty :if={@messages == []} class="border-0">
          <Empty.empty_header>
            <Empty.empty_media variant="icon">
              <LiveShadcn.Icon.icon name="audio-lines" />
            </Empty.empty_media>
            <Empty.empty_title>No messages yet.</Empty.empty_title>
            <Empty.empty_description>
              {if @duplex,
                do: "Start the conversation and speak.",
                else: "Type a message, or record one with the microphone."}
            </Empty.empty_description>
          </Empty.empty_header>
        </Empty.empty>
        <Message.message :for={message <- @messages} id={message.id} from={message.role}>
          <Message.message_content class={message.live && "opacity-70"}>
            <Shimmer.shimmer :if={message.pending and message.text == ""} id={"#{message.id}-wait"}>
              {cond do
                message.live -> "Listening…"
                message.role == "user" -> "Transcribing…"
                true -> "Thinking…"
              end}
            </Shimmer.shimmer>
            <Message.message_response :if={message.text != ""} content={message.text} />
            <AudioPlayer.audio_player
              :if={message.audio}
              id={"#{message.id}-audio"}
              phx-update="ignore"
            >
              <AudioPlayer.audio_player_element data={message.audio} preload="metadata" />
              <AudioPlayer.audio_player_control_bar>
                <AudioPlayer.audio_player_play_button />
                <AudioPlayer.audio_player_time_display />
                <AudioPlayer.audio_player_time_range />
                <AudioPlayer.audio_player_duration_display />
              </AudioPlayer.audio_player_control_bar>
            </AudioPlayer.audio_player>
            <p :if={message.note} class="text-xs text-muted-foreground">{message.note}</p>
          </Message.message_content>
        </Message.message>
      </Conversation.conversation>

      <.disclosure :if={not @duplex} id="diagnostics" title="Diagnostics">
        <div class="flex flex-wrap items-center gap-2 text-xs text-muted-foreground">
          <Button.button variant="outline" size="sm" phx-click="pause" disabled={@candidate != nil}>
            Pause playback
          </Button.button>
          <Button.button variant="outline" size="sm" phx-click="resume" disabled={not @paused}>
            Resume
          </Button.button>
          <Button.button variant="outline" size="sm" phx-click="stop">Confirm stop</Button.button>
          <span>Playback acknowledged: {@played_ms} ms</span>
        </div>
      </.disclosure>
      <PromptInput.prompt_input :if={not @duplex} id="prompt" on_submit="send">
        <PromptInput.prompt_input_textarea
          id="prompt-text"
          aria-label="Message"
          placeholder="Message AudioFlow"
          disabled={Chat.Setup.speech?(@settings)}
        />
        <PromptInput.prompt_input_footer>
          <PromptInput.prompt_input_tools>
            <div
              id="recorder"
              data-rate={Chat.Setup.rate(@settings)}
              phx-hook="Recorder"
              phx-update="ignore"
            >
              <Button.button
                type="button"
                variant="ghost"
                size="icon-sm"
                aria-label="Record a voice message"
                aria-pressed="false"
                class="group/rec aria-pressed:bg-destructive aria-pressed:text-white"
              >
                <LiveShadcn.Icon.icon name="mic" class="group-aria-pressed/rec:hidden" />
                <LiveShadcn.Icon.icon name="square" class="hidden group-aria-pressed/rec:block" />
              </Button.button>
            </div>
          </PromptInput.prompt_input_tools>
          <PromptInput.prompt_input_submit status={@status} on_stop="stop" />
        </PromptInput.prompt_input_footer>
      </PromptInput.prompt_input>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:for, :string, required: true)
  attr(:status, :any, default: nil)
  slot(:inner_block, required: true)

  defp model_field(assigns) do
    ~H"""
    <Field.field class="gap-1.5">
      <Field.field_label for={@for} class="text-xs">
        {@label}
        <Spinner.spinner :if={@status == :loading} class="size-3" />
      </Field.field_label>
      {render_slot(@inner_block)}
      <Field.field_description :if={status_text(@status)} class="text-xs">
        {status_text(@status)}
      </Field.field_description>
    </Field.field>
    """
  end

  attr(:id, :string, required: true)
  attr(:title, :string, required: true)
  attr(:class, :any, default: nil)
  attr(:rest, :global)
  slot(:inner_block, required: true)

  # A closed section with a chevron trigger, for settings and diagnostics.
  defp disclosure(assigns) do
    ~H"""
    <Collapsible.collapsible
      id={@id}
      class={["text-sm", @class]}
      trigger_class="group/trigger flex cursor-pointer items-center gap-1 text-muted-foreground hover:text-foreground"
      content_class="pt-2"
      {@rest}
    >
      <:trigger>
        <LiveShadcn.Icon.icon
          name="chevron-right"
          class="size-4 transition-transform group-aria-expanded/trigger:rotate-90"
        />
        {@title}
      </:trigger>
      {render_slot(@inner_block)}
    </Collapsible.collapsible>
    """
  end
end
