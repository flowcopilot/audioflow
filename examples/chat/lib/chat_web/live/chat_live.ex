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

  alias AudioFlow.{Audio, Text}
  alias Chat.{Catalog, Wav}
  alias ChatWeb.Components.UI.{Badge, Button, NativeSelect, Spinner}
  alias LiveAiElements.Components.{AudioPlayer, Conversation, Message, PromptInput, Shimmer}

  # Start a partial transcription after this much new audio (0.5 s).
  @partial_bytes 16_000

  @impl true
  def mount(_params, _session, socket) do
    session =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Chat.PubSub, Chat.Engine.topic())
        {:ok, session} = AudioFlow.start_session(Chat.Stage.session_options())
        session
      end

    {:ok,
     assign(socket,
       session: session,
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
    case String.trim(text) do
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
    {:noreply, assign(socket, recording: %{id: id, pcm: [], bytes: 0, task: nil, since: 0})}
  end

  def handle_event("voice_chunk", %{"pcm" => pcm}, %{assigns: %{recording: %{}}} = socket),
    do: {:noreply, socket |> append_audio(pcm) |> maybe_transcribe()}

  def handle_event("voice_end", %{"pcm" => pcm}, %{assigns: %{recording: %{}}} = socket) do
    socket = append_audio(socket, pcm)
    %{pcm: pcm, bytes: bytes, id: id} = socket.assigns.recording
    socket = assign(socket, recording: nil)

    if bytes == 0 do
      {:noreply, remove_message(socket, id)}
    else
      socket = update_message(socket, id, &%{&1 | text: "", pending: true})
      submit(socket, %Audio{data: IO.iodata_to_binary(pcm), sample_rate: 16_000})
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

  def handle_event("stop", _params, socket), do: {:noreply, cancel(socket)}

  def handle_event("new_chat", _params, socket) do
    socket = cancel(socket)
    if socket.assigns.session, do: :ok = AudioFlow.clear_history(socket.assigns.session)
    {:noreply, assign(socket, messages: [])}
  end

  def handle_event("select_model", %{"_target" => [field]} = params, socket)
      when field in ["stt", "llm", "voice"] do
    :ok = Chat.Engine.select(String.to_existing_atom(field), params[field])
    {:noreply, socket}
  end

  @impl true
  def handle_info(
        {AudioFlow, session, turn, event},
        %{assigns: %{session: session, turn: turn}} = socket
      ),
      do: {:noreply, turn_event(socket, event)}

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
    |> push_event("play", %{pcm: Base.encode64(data), rate: rate})
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

    finish(socket, audio: audio, note: note)
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
        assign(socket, recording: %{r | pcm: [r.pcm, data], bytes: r.bytes + byte_size(data)})

      :error ->
        socket
    end
  end

  # One partial transcription runs at a time, over the complete recording so far.
  defp maybe_transcribe(%{assigns: %{recording: %{task: nil} = r}} = socket)
       when r.bytes - r.since >= @partial_bytes do
    audio = %Audio{data: IO.iodata_to_binary(r.pcm), sample_rate: 16_000}
    task = Task.Supervisor.async_nolink(Chat.Tasks, fn -> Chat.Engine.transcribe(audio) end)
    assign(socket, recording: %{r | task: task.ref, since: r.bytes})
  end

  defp maybe_transcribe(socket), do: socket

  defp cancel(%{assigns: %{turn: nil}} = socket), do: socket

  defp cancel(socket) do
    # The cancelled event arrives after this call and closes the reply.
    AudioFlow.cancel(socket.assigns.session)
    push_event(socket, "flush", %{})
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

      <form id="models" phx-change="select_model" class="grid gap-3 sm:grid-cols-3">
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
      <p class="-mt-2 text-xs text-muted-foreground">
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

      <PromptInput.prompt_input id="prompt" on_submit="send">
        <PromptInput.prompt_input_textarea
          id="prompt-text"
          aria-label="Message"
          placeholder="Message AudioFlow"
        />
        <PromptInput.prompt_input_footer>
          <PromptInput.prompt_input_tools>
            <div id="recorder" phx-hook="Recorder" phx-update="ignore">
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

  attr :label, :string, required: true
  attr :status, :any, default: nil
  slot :inner_block, required: true

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
