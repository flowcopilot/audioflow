defmodule ChatWeb.ChatLive do
  @moduledoc """
  One AudioFlow session per connected LiveView.

  The LiveView process owns the session and receives its turn events. Typed
  messages use `AudioFlow.Text`. While recording, the browser sends 16 kHz PCM
  chunks; the current STT model transcribes the recording so far and the user
  message shows that partial text. When recording stops, the complete audio is
  one session turn. Reply audio is pushed to the browser as it arrives, and the
  complete reply is kept as a WAV file for replay.
  """
  use Phoenix.LiveView

  alias AudioFlow.Audio
  alias AudioFlow.Recording.Store
  alias AudioFlow.Text
  alias Chat.Catalog
  alias Chat.Setup
  alias Chat.Wav
  alias ChatWeb.Components.UI.Badge
  alias ChatWeb.Components.UI.Button
  alias ChatWeb.Components.UI.NativeSelect
  alias ChatWeb.Components.UI.Spinner
  alias LiveAiElements.Components.AudioPlayer
  alias LiveAiElements.Components.Conversation
  alias LiveAiElements.Components.Message
  alias LiveAiElements.Components.PromptInput
  alias LiveAiElements.Components.Shimmer

  # Start a partial transcription after this much new audio (0.5 s).
  @partial_bytes 16_000

  @impl true
  def mount(_params, _session, socket) do
    session =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Chat.PubSub, Chat.Engine.topic())
        Process.send_after(self(), :retention, 60_000)

        {:ok, session} =
          AudioFlow.start_session(
            elem(Setup.options(Setup.defaults()), 1) ++ [output: {Chat.Output, self()}]
          )

        session
      end

    {:ok,
     assign(socket,
       session: session,
       settings: Setup.defaults(),
       setup_error: nil,
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
    case if(Setup.speech?(socket.assigns.settings), do: "", else: String.trim(text)) do
      "" ->
        {:reply, %{ok: false}, socket}

      text ->
        socket = cancel(socket) |> add_message("user", text)
        submit(socket, %Text{data: text})
    end
  end

  # A new recording interrupts the current reply.
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
    {:noreply, assign(socket, messages: [])}
  end

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

      {:ok, options} ->
        if socket.assigns.recording || socket.assigns.turn do
          {:noreply,
           assign(socket,
             setup_error: "Stop the current turn/recording before changing settings."
           )}
        else
          socket = cancel(socket)
          AudioFlow.stop_session(socket.assigns.session)
          Chat.Capture.close(socket.assigns.capture)
          {:ok, session} = AudioFlow.start_session(options ++ [output: {Chat.Output, self()}])

          {:noreply,
           assign(socket,
             session: session,
             settings: settings,
             messages: [],
             capture: nil,
             artifacts: [],
             setup_error: nil
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

  @impl true
  def terminate(_, socket) do
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
  def handle_info({:models, models}, socket), do: {:noreply, assign(socket, models: models)}

  # A partial transcription finished.
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

  # Results of partial transcriptions for a recording that already ended.
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
          base64: Base.encode64(Wav.encode(socket.assigns.pcm, socket.assigns.rate))
        }

    note =
      if metrics.first_text_us,
        do: "First text #{ms(metrics.first_text_us)}, first audio #{ms(metrics.first_audio_us)}",
        else: "No speech was recognized."

    finish(socket,
      audio: audio,
      note:
        note <>
          " · Transcript #{ms(metrics[:first_transcript_us])} · Total #{ms(metrics[:duration_us])} · #{metrics[:events]} events · played #{socket.assigns.played_ms} ms"
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

  # One partial transcription runs at a time, over the complete recording so far.
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
        do:
          finish(socket, note: "Stopped; history keeps only acknowledged complete speech chunks."),
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

  # The newest user message that is not the live recording.
  defp update_last(socket, role, fun) do
    live = socket.assigns.recording && socket.assigns.recording.id

    case Enum.reverse(socket.assigns.messages)
         |> Enum.find(&(&1.role == role and &1.id != live)) do
      nil -> socket
      message -> update_message(socket, message.id, fun)
    end
  end

  defp ms(nil), do: "none"
  defp ms(us), do: "#{div(us, 1000)} ms"

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

  defp gb(value), do: :erlang.float_to_binary(value * 1.0, decimals: 1)

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        stt_models: Catalog.stt(),
        llm_models: Catalog.llm(),
        voices: Catalog.voices()
      )

    ~H"""
    <div id="chat" phx-hook="Player" class="mx-auto flex h-svh max-w-3xl flex-col gap-4 p-4">
      <header class="flex items-center justify-between gap-4">
        <div>
          <h1 class="text-lg font-semibold">AudioFlow chat</h1>
          <p class="text-sm text-muted-foreground">
            Type a message, or record one with the microphone.
          </p>
        </div>
        <Button.button variant="outline" size="sm" phx-click="new_chat">New chat</Button.button>
      </header>

      <section class="rounded border p-3 text-sm">
        <form id="configuration" phx-submit="configure" class="flex flex-wrap gap-2">
          <label>Pipeline
          <select name="mode"><option
            :for={
              {id, label} <- [
                {"demo", "Synthetic demo"},
                {"local", "Local Apple MLX"},
                {"remote", "Deepgram → Chat HTTP → TTS"},
                {"openai", "OpenAI speech-to-speech"},
                {"gemini", "Gemini speech-to-speech"}
              ]
            }
            value={id}
            selected={@settings["mode"] == id}
          >
            {label}
          </option></select></label>
          <label>Remote chain language
          <select name="language"><option
            :for={lang <- ~w(en es fr de ro)}
            value={lang}
            selected={@settings["language"] == lang}
          >
            {lang}
          </option></select></label>
          <label>Remote TTS
          <select name="tts"><option
            :for={tts <- ~w(elevenlabs cartesia)}
            value={tts}
            selected={@settings["tts"] == tts}
          >
            {tts}
          </option></select></label>
          <label>OpenAI voice
          <select name="voice"><option
            :for={voice <- ~w(marin cedar)}
            value={voice}
            selected={@settings["voice"] == voice}
          >
            {voice}
          </option></select></label>
          <button type="submit">Apply (starts new chat)</button>
        </form>
        <p :if={@setup_error} role="alert">{@setup_error}</p>
        <p>
          Active: {@settings["mode"]} · Input PCM {Chat.Setup.rate(@settings)} Hz mono · Playback acknowledged: {@played_ms} ms
        </p>
        <p :if={@settings["mode"] == "demo"}>
          Synthetic demo: fixed transcript, echoed text, silent PCM. No inference.
        </p>
        <p :if={Chat.Setup.speech?(@settings)}>
          Microphone only; fresh provider connection each turn, no history replay. No text/audio alignment or native history truncation is claimed. Language and Gemini voice use provider defaults.
        </p>
        <p>
          Remote chain requires DEEPGRAM_API_KEY, CHAT_HTTP_ENDPOINT, CHAT_HTTP_MODEL and ELEVENLABS_API_KEY / ELEVENLABS_VOICE_ID or CARTESIA_API_KEY / CARTESIA_VOICE_ID. Optional CHAT_HTTP_API_KEY. Speech-to-speech requires OPENAI_API_KEY / OPENAI_REALTIME_MODEL or GEMINI_API_KEY / GEMINI_LIVE_MODEL. Configure these on the server.
        </p>
        <button type="button" phx-click="capture">{if @capture,
          do: "Disable and delete recordings",
          else: "Enable redacted recordings"}</button>
        <p>
          Opt-in text-only JSON: all content replaced with [REDACTED], no PCM. Limit 20 turns, 1 hour, 128 KB buffered per turn. Deleted on disconnect; retention checked every minute and on access.
        </p>
        <div :for={id <- @artifacts}>
          {id} <button phx-click="download" phx-value-id={id}>Download</button>
          <button phx-click="delete" phx-value-id={id}>Delete</button>
        </div>
      </section>
      <nav aria-label="Standalone transports" class="text-sm underline">
        <a href="https://github.com/flowcopilot/audioflow/tree/feat/parallel-issue-integration/examples/rtvi-client">Official Pipecat SDK / RTVI client setup</a>
        ·
        <a href="https://github.com/flowcopilot/audioflow/blob/feat/parallel-issue-integration/examples/telephony-loopback.exs">Paced telephony loopback setup</a>
        ·
        <a href="https://github.com/flowcopilot/audioflow/blob/feat/parallel-issue-integration/examples/network/README.md">Encoded WebRTC / LiveAvatar setup</a>
        <p>
          Standalone encoded WebRTC needs AUDIOFLOW_WEBRTC=1 and OpenSSL; it negotiates local peers, not a Session PCM bridge. LiveAvatar LITE requires LIVEAVATAR_API_KEY, LIVEAVATAR_AVATAR_ID and finite 24 kHz PCM; no provider verification is claimed.
        </p>
      </nav>
      <form
        :if={@settings["mode"] == "local"}
        id="models"
        phx-change="select_model"
        class="grid gap-3 sm:grid-cols-3"
      >
        <.model_field label="Speech recognition" status={@models.status[:stt]}>
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
        <.model_field label="Reply model" status={@models.status[:llm]}>
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
        <.model_field label="Voice (Kokoro)" status={@models.status[:tts]}>
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
      <p :if={@settings["mode"] == "local"} class="-mt-2 text-xs text-muted-foreground">
        <Badge.badge variant="secondary">
          ≈ {gb(@models.memory_gb)} GB of model weights{if @system_memory_gb,
            do: " · #{gb(@system_memory_gb)} GB memory"}
        </Badge.badge>
        {fit_text(@system_memory_gb)}
      </p>

      <Conversation.conversation id="chat-log" class="rounded-lg border">
        <p :if={@messages == []} class="py-16 text-center text-sm text-muted-foreground">
          No messages yet.
        </p>
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

      <div>
        <button phx-click="pause" disabled={@candidate != nil}>Pause / test interruption (10 s)</button>
        <button phx-click="resume" disabled={not @paused}>Resume false interruption</button>
        <button phx-click="stop">Confirm / Stop</button>
        <span>{if @paused, do: "Web Audio suspended", else: "Playback running or awaiting endpoint"}</span>
      </div>
      <PromptInput.prompt_input id="prompt" on_submit="send">
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
  attr(:status, :any, default: nil)
  slot(:inner_block, required: true)

  defp model_field(assigns) do
    ~H"""
    <label class="grid gap-1.5 text-xs font-medium">
      <span class="flex items-center gap-1.5">
        {@label}
        <Spinner.spinner :if={@status == :loading} class="size-3" />
      </span>
      {render_slot(@inner_block)}
      <span :if={status_text(@status)} class="font-normal text-muted-foreground">
        {status_text(@status)}
      </span>
    </label>
    """
  end
end
