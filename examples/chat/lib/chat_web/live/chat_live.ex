defmodule ChatWeb.ChatLive do
  @moduledoc """
  One AudioFlow session per connected LiveView.

  The LiveView process owns the session and receives its turn events. Typed
  messages use `AudioFlow.Text`; recorded messages arrive from the browser as
  mono 16 kHz s16le PCM. Reply audio is pushed to the browser as it arrives,
  and the complete reply is kept as a WAV file for replay.
  """
  use Phoenix.LiveView

  alias AudioFlow.{Audio, Text}
  alias Chat.Wav
  alias ChatWeb.Components.UI.{Badge, Button}
  alias LiveAiElements.Components.{AudioPlayer, Conversation, Message, PromptInput, Shimmer}

  @impl true
  def mount(_params, _session, socket) do
    {options, engine} = Chat.Engine.session()

    session =
      if connected?(socket) do
        {:ok, session} = AudioFlow.start_session(options)
        session
      end

    {:ok,
     assign(socket,
       session: session,
       engine: engine,
       turn: nil,
       status: "ready",
       messages: [],
       reply_id: nil,
       pcm: [],
       rate: nil
     )}
  end

  @impl true
  def handle_event("send", %{"text" => text}, socket) do
    case String.trim(text) do
      "" -> {:reply, %{ok: false}, socket}
      text -> submit(socket, %Text{data: text}, text)
    end
  end

  def handle_event("voice", %{"pcm" => pcm}, socket) do
    case Base.decode64(pcm) do
      {:ok, ""} -> {:noreply, socket}
      {:ok, data} -> submit(socket, %Audio{data: data, sample_rate: 16_000}, "")
      :error -> {:noreply, socket}
    end
  end

  # Barge-in: a new recording interrupts the current reply.
  def handle_event("recording", _params, socket), do: {:noreply, cancel(socket)}
  def handle_event("stop", _params, socket), do: {:noreply, cancel(socket)}

  def handle_event("recording_failed", %{"message" => message}, socket),
    do: {:noreply, add_message(socket, "assistant", "", note: "Microphone error: #{message}")}

  def handle_event("new_chat", _params, socket) do
    socket = cancel(socket)
    if socket.assigns.session, do: :ok = AudioFlow.clear_history(socket.assigns.session)
    {:noreply, assign(socket, messages: [])}
  end

  @impl true
  def handle_info(
        {AudioFlow, session, turn, event},
        %{assigns: %{session: session, turn: turn}} = socket
      ),
      do: {:noreply, turn_event(socket, event)}

  def handle_info({AudioFlow, _, _, _}, socket), do: {:noreply, socket}

  defp turn_event(socket, {:transcript, text}),
    do: update_last(socket, "user", &%{&1 | text: &1.text <> text})

  defp turn_event(socket, {:text, text}) do
    socket
    |> assign(status: "streaming")
    |> update_last("user", &%{&1 | pending: false})
    |> update_reply(&%{&1 | text: &1.text <> text})
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
        do:
          "First text #{div(metrics.first_text_us, 1000)} ms, first audio #{ms(metrics.first_audio_us)}",
        else: "No speech was recognized."

    finish(socket, audio: audio, note: note)
  end

  defp turn_event(socket, {:cancelled, _metrics}), do: finish(socket, note: "Stopped.")

  defp turn_event(socket, {:error, reason, _metrics}),
    do: finish(socket, note: "Error: #{inspect(reason)}")

  defp turn_event(socket, _event), do: socket

  defp submit(%{assigns: %{session: nil}} = socket, _input, _text),
    do: {:reply, %{ok: false}, socket}

  defp submit(socket, input, text) do
    case AudioFlow.submit(socket.assigns.session, input) do
      {:ok, turn} ->
        socket =
          socket
          |> add_message("user", text, pending: text == "")
          |> add_message("assistant", "", pending: true)

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
         add_message(socket, "assistant", "", note: "Not sent: #{inspect(reason)}")}
    end
  end

  defp cancel(%{assigns: %{turn: nil}} = socket), do: socket

  defp cancel(socket) do
    # The cancelled event arrives after this call and closes the reply.
    AudioFlow.cancel(socket.assigns.session)
    push_event(socket, "flush", %{})
  end

  defp finish(socket, fields) do
    socket
    |> update_last("user", &%{&1 | pending: false})
    |> update_reply(&Map.merge(&1, Map.new([pending: false] ++ fields)))
    |> assign(turn: nil, status: "ready", reply_id: nil, pcm: [], rate: nil)
  end

  defp add_message(socket, role, text, fields) do
    message =
      Map.merge(
        %{
          id: "m#{System.unique_integer([:positive])}",
          role: role,
          text: text,
          pending: false,
          note: nil,
          audio: nil
        },
        Map.new(fields)
      )

    assign(socket, messages: socket.assigns.messages ++ [message])
  end

  defp update_reply(socket, fun) do
    id = socket.assigns.reply_id
    messages = Enum.map(socket.assigns.messages, &if(&1.id == id, do: fun.(&1), else: &1))
    assign(socket, messages: messages)
  end

  defp update_last(socket, role, fun) do
    {before, rest} =
      socket.assigns.messages
      |> Enum.reverse()
      |> Enum.split_while(&(&1.role != role))

    messages =
      case rest do
        [message | older] -> Enum.reverse(older) ++ [fun.(message) | Enum.reverse(before)]
        [] -> socket.assigns.messages
      end

    assign(socket, messages: messages)
  end

  defp ms(nil), do: "none"
  defp ms(us), do: "#{div(us, 1000)} ms"

  @impl true
  def render(assigns) do
    ~H"""
    <div id="chat" phx-hook="Player" class="mx-auto flex h-svh max-w-3xl flex-col gap-4 p-4">
      <header class="flex items-center justify-between gap-4">
        <div>
          <h1 class="text-lg font-semibold">AudioFlow chat</h1>
          <p class="text-sm text-muted-foreground">
            Type a message, or record one with the microphone.
          </p>
        </div>
        <div class="flex items-center gap-2">
          <Badge.badge variant="secondary">{@engine}</Badge.badge>
          <Button.button variant="outline" size="sm" phx-click="new_chat">New chat</Button.button>
        </div>
      </header>

      <Conversation.conversation id="chat-log" class="rounded-lg border">
        <p :if={@messages == []} class="py-16 text-center text-sm text-muted-foreground">
          No messages yet.
        </p>
        <Message.message :for={message <- @messages} id={message.id} from={message.role}>
          <Message.message_content>
            <Shimmer.shimmer :if={message.pending and message.text == ""} id={"#{message.id}-wait"}>
              {if message.role == "user", do: "Transcribing…", else: "Thinking…"}
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
end
