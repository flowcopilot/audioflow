defmodule AudioFlow.Transport.RtpInput do
  @moduledoc """
  Inbound RTP audio for a transport that owns an `AudioFlow.Session`. It runs
  the packets of one remote track through the same steps for every transport:
  `AudioFlow.RTP.Reorder`, a gap timer, a decoder, VoiceInput, and the speech
  events for the session and the owner.

  The transport process keeps the struct from `new/1` in its state, calls
  `push/2` for each RTP packet and `gap/2` for each `{:gap, token}` message,
  and calls `stop/1` when it ends. It also passes the messages of a semantic
  turn check to `handle_info/2`. All calls run in that process, which also
  receives the gap timer message. Speech start cancels the session output. A
  finished utterance is sent to the session, and the owner gets
  `{tag, self(), {:utterance, reason}}` (and `{:error, {:submit, reason}}`).

  A decoder is a module with the `c:decode/2` callback, so that a transport
  keeps codecs of optional dependencies, such as Opus, in its own profile.
  `AudioFlow.Transport.PCMUDecoder` decodes PCMU. The decoder reports how many
  samples of the RTP clock a packet holds. The next packet should start there.

  Options of `new/1`: `:owner`, `:tag` (the first element of the owner
  messages), `:vad` (a 16 kHz VoiceInput detector tuple), `:voice_input`
  (options of `AudioFlow.VoiceInput.new/2`; `async_turn` is on unless set),
  `:reorder_window` (32, at most 256), `:gap_timeout_ms` (200, at most 5000),
  and `:loss`:

    * `:silence` - a lost packet (after the gap timeout), a burst loss beyond
      the window and the packets that DTX leaves out become silence for the
      VAD, at most one second per gap. The stream goes on.
    * `:fail` - any loss, and any jump of the RTP timestamp, is an error.
  """
  alias AudioFlow.Audio
  alias AudioFlow.RTP.Reorder
  alias AudioFlow.VoiceInput

  @doc """
  Decodes one RTP payload to 16 kHz mono PCM. Returns the PCM, the length of
  the packet in samples of the RTP clock, and the new decoder state.
  """
  @callback decode(payload :: binary(), state :: term()) ::
              {pcm :: binary(), samples :: non_neg_integer(), state :: term()}

  # One gap of lost or untransmitted audio becomes at most one second of silence.
  @max_silence_samples 16_000
  @timestamp_modulus 4_294_967_296

  @enforce_keys [:owner, :tag, :voice, :reorder, :gap_timeout, :loss]
  defstruct [
    :owner,
    :tag,
    :voice,
    :reorder,
    :gap_timeout,
    :loss,
    :session,
    # {decoder module, decoder state}, set by restart/3.
    codec: nil,
    clock: 8000,
    gap: nil,
    # The RTP timestamp where the next packet should start.
    next_timestamp: nil
  ]

  @type t :: %__MODULE__{}

  @doc "Builds the input. Set `:session` when the session exists."
  @spec new(keyword()) :: t()
  def new(options) do
    voice_options = VoiceInput.Options.fetch(options, async_turn: true)
    voice = VoiceInput.new(Keyword.fetch!(options, :vad), voice_options)
    unless voice.rate == 16_000, do: raise(ArgumentError, "VAD requires 16 kHz")
    window = Keyword.get(options, :reorder_window, 32)
    timeout = Keyword.get(options, :gap_timeout_ms, 200)
    loss = Keyword.get(options, :loss, :silence)

    unless is_integer(window) and window in 1..256 and is_integer(timeout) and timeout in 1..5000 and
             loss in [:silence, :fail],
           do: raise(ArgumentError, "invalid RTP reorder limits")

    %__MODULE__{
      owner: Keyword.fetch!(options, :owner),
      tag: Keyword.fetch!(options, :tag),
      voice: voice,
      reorder: Reorder.new(window),
      gap_timeout: timeout,
      loss: loss
    }
  end

  @doc """
  Starts a new stream with `{decoder, state}` (or `nil` for none) and the RTP
  clock rate. The reorder buffer and the gap timer start again; the voice
  detector keeps its state.
  """
  @spec restart(t(), nil | {module(), term()}, pos_integer()) :: t()
  def restart(%__MODULE__{} = input, codec, clock) do
    cancel(input)

    %{
      input
      | reorder: Reorder.new(input.reorder.window),
        gap: nil,
        codec: codec,
        clock: clock,
        next_timestamp: nil
    }
  end

  @doc "Takes one RTP packet (`:sequence_number`, `:timestamp`, `:payload`)."
  @spec push(t(), map()) :: {:ok, t()} | {:error, term()}
  def push(%__MODULE__{} = input, packet) do
    case Reorder.push(input.reorder, packet) do
      {:ok, packets, reorder} -> play(packets, %{input | reorder: reorder})
      {:resync, _lost, packets, reorder} -> resync(packets, %{input | reorder: reorder})
    end
  end

  @doc "Handles a `{:gap, token}` message: gives up on the missing packets."
  @spec gap(t(), reference()) :: {:ok, t()} | {:error, term()}
  def gap(%__MODULE__{gap: {_, token}} = input, token) do
    case Reorder.skip(input.reorder) do
      {lost, _, _} when lost > 0 and input.loss == :fail ->
        {:error, :rtp_gap_timeout}

      {_lost, packets, reorder} ->
        play(packets, %{input | gap: nil, reorder: reorder})
    end
  end

  def gap(%__MODULE__{} = input, _token), do: {:ok, input}

  @doc """
  Handles a message of a pending semantic turn check (see `AudioFlow.VoiceInput`).
  Returns `{:ok, input}`, or `:unknown` for any other message. The utterance of
  a resolved check goes the same way as one from `push/2`. Call it before a
  generic `:DOWN` clause, because the check runs in a monitored process.
  """
  @spec handle_info(t(), term()) :: {:ok, t()} | :unknown
  def handle_info(%__MODULE__{} = input, message) do
    case VoiceInput.handle_info(input.voice, message) do
      {:ok, events, voice} ->
        Enum.each(events, &voice_event(input, &1))
        {:ok, %{input | voice: voice}}

      :unknown ->
        :unknown
    end
  end

  @doc "Cancels the gap timer."
  @spec stop(t()) :: :ok
  def stop(%__MODULE__{} = input), do: cancel(input)

  @doc "Sends an event to the owner."
  @spec notify(t(), term()) :: :ok
  def notify(%__MODULE__{} = input, event) do
    send(input.owner, {input.tag, self(), event})
    :ok
  end

  defp resync(_packets, %{loss: :fail}), do: {:error, :rtp_reorder_limit}
  defp resync(packets, input), do: play(packets, input)

  defp play(packets, input) do
    with {:ok, input} <- play_all(packets, input), do: {:ok, schedule_gap(input)}
  rescue
    error -> {:error, {:decode, Exception.message(error)}}
  end

  defp play_all([], input), do: {:ok, input}

  defp play_all([packet | rest], input) do
    with {:ok, input} <- idle(input, packet.timestamp) do
      {module, state} = input.codec
      {pcm, samples, state} = module.decode(packet.payload, state)

      input = %{
        input
        | codec: {module, state},
          next_timestamp: rem(packet.timestamp + samples, @timestamp_modulus)
      }

      play_all(rest, listen(input, pcm))
    end
  end

  # Audio that the RTP timestamps place before this packet but that never
  # arrived: lost packets, or packets that DTX did not send.
  defp idle(%{next_timestamp: nil} = input, _timestamp), do: {:ok, input}

  defp idle(input, timestamp) do
    gap = rem(timestamp - input.next_timestamp + @timestamp_modulus, @timestamp_modulus)
    samples = min(div(gap * 16_000, input.clock), @max_silence_samples)

    cond do
      gap == 0 -> {:ok, input}
      input.loss == :fail -> {:error, :rtp_timestamp_gap}
      gap < 2_147_483_648 and samples > 0 -> {:ok, listen(input, <<0::size(samples * 16)>>)}
      true -> {:ok, input}
    end
  end

  defp listen(input, <<>>), do: input

  defp listen(input, pcm) do
    {events, voice} = VoiceInput.push(input.voice, %Audio{data: pcm, sample_rate: 16_000})
    Enum.each(events, &voice_event(input, &1))
    %{input | voice: voice}
  end

  defp voice_event(input, :speech_started), do: AudioFlow.cancel(input.session)

  defp voice_event(input, {:utterance, audio, reason}) do
    notify(input, {:utterance, reason})

    case AudioFlow.submit(input.session, audio) do
      {:ok, _} -> :ok
      {:error, reason} -> notify(input, {:error, {:submit, reason}})
    end
  end

  defp voice_event(_input, _event), do: :ok

  # Waits for a missing packet while later packets are buffered.
  defp schedule_gap(input) do
    cond do
      not Reorder.waiting?(input.reorder) ->
        cancel(input)
        %{input | gap: nil}

      input.gap == nil ->
        token = make_ref()
        %{input | gap: {Process.send_after(self(), {:gap, token}, input.gap_timeout), token}}

      true ->
        input
    end
  end

  defp cancel(%{gap: {timer, _}}) do
    Process.cancel_timer(timer)
    :ok
  end

  defp cancel(_input), do: :ok
end
