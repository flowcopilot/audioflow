defmodule AudioFlow.Adapters.Moshi do
  @moduledoc """
  One committed audio turn with a local Kyutai Moshi server (`moshi_mlx.local_web`
  or the PyTorch `moshi.server`). Requires `AUDIOFLOW_MEDIA=1`: Ogg Opus framing and
  coding come from `membrane_ogg_plugin` and `membrane_opus_plugin`.

  `run/3` emits `{:text, delta}` and `{:audio, Audio}` like `OpenAIRealtime`.
  Moshi does not transcribe the user, so there is no `:transcript` event.
  Use directly or in Session `:speech_to_speech`; see docs/providers.md.

  Moshi is full duplex and has no end-of-turn signal. The adapter sends the
  committed input, then silence, one 80 ms frame for each frame it receives.
  Output that belongs to the input period is dropped. The reply ends after
  `:end_silence_ms` of model output without text, or fails with `:no_reply`
  when `:max_reply_ms` passes without text.

  Options: `:endpoint` (`"ws://127.0.0.1:8998/api/chat"`), `:max_reply_ms`
  (20,000), `:end_silence_ms` (1,600), `:timeout_ms` (60,000) and
  `:max_response_bytes` (16,777,216).
  """
  @behaviour AudioFlow.Adapter
  alias AudioFlow.Adapters.Providers.Socket
  alias AudioFlow.Audio
  alias Membrane.Ogg.Opus, as: OggOpus
  alias Membrane.Ogg.Page
  alias Membrane.Ogg.Parser
  alias Membrane.Opus.Decoder.Native, as: Decoder
  alias Membrane.Opus.Encoder.Native, as: Encoder

  @rate 24_000
  # Moshi steps every 80 ms; Opus packets are 20 ms.
  @frame 1_920
  @packet 480
  @lead @frame * 6
  # libopus OPUS_APPLICATION_AUDIO, OPUS_AUTO bitrate, OPUS_SIGNAL_VOICE.
  @application 2049
  @bitrate -1000
  @signal 3001

  def run(audio, options, emit) do
    Socket.audio!(audio, @rate)
    samples = fn key, default -> Socket.positive!(options, key, default) * div(@rate, 1000) end
    input = pad(audio.data)

    state = %{
      input: input,
      input_samples: div(byte_size(input), 2),
      max_reply: samples.(:max_reply_ms, 20_000),
      end_silence: samples.(:end_silence_ms, 1_600),
      sent: 0,
      received: 0,
      last_text: nil,
      ready: false,
      encoder: Encoder.create(@rate, 1, @application, @bitrate, @signal),
      decoder: Decoder.create(@rate, 1),
      buffer: <<>>,
      continued: nil,
      page: nil,
      emit: emit
    }

    Socket.run(
      Keyword.get(options, :endpoint, "ws://127.0.0.1:8998/api/chat"),
      [],
      [],
      state,
      &event/2,
      Keyword.put_new(options, :timeout_ms, 60_000),
      &decode/1
    )
  end

  defp pad(pcm) do
    case rem(byte_size(pcm), @frame * 2) do
      0 -> pcm
      rest -> pcm <> :binary.copy(<<0>>, @frame * 2 - rest)
    end
  end

  defp decode({:binary, <<0>>}), do: {:ok, :ready}
  defp decode({:binary, <<1, data::binary>>}), do: {:ok, {:audio, data}}

  defp decode({:binary, <<2, text::binary>>}),
    do: if(String.valid?(text), do: {:ok, {:text, text}}, else: :error)

  defp decode(_frame), do: :error

  defp event(:ready, %{ready: false} = state) do
    head = header(Page.create_first(:rand.uniform(0xFFFFFFFF) - 1), OggOpus.create_id_header(1))
    tags = header(Page.create_subsequent(head), OggOpus.create_comment_header())
    headers = {:binary, <<1>> <> Page.serialize(head) <> Page.serialize(tags)}
    {state, frames} = top_up(%{state | ready: true, page: tags}, state.input_samples + @lead)
    {:cont, state, [headers | frames]}
  end

  defp event(_event, %{ready: false}), do: {:error, :invalid_event}
  defp event(:ready, _state), do: {:error, :invalid_event}

  defp event({:text, text}, state) do
    if state.received >= state.input_samples do
      :ok = state.emit.({:text, text})
      {:cont, %{state | last_text: state.received}, []}
    else
      {:cont, state, []}
    end
  end

  defp event({:audio, data}, state) do
    case parse(state.buffer <> data, state.continued) do
      {:ok, packets, continued, rest} ->
        pcm =
          for %Parser.Packet{payload: packet} <- packets, not opus_header?(packet), into: <<>> do
            Decoder.decode_packet(state.decoder, packet)
          end

        state = %{state | buffer: rest, continued: continued}
        :ok = emit_reply(pcm, state)
        received(%{state | received: state.received + div(byte_size(pcm), 2)})

      :error ->
        {:error, :invalid_audio}
    end
  end

  # Parser.parse/2 keeps partial pages in `rest` and raises on a corrupt page.
  defp parse(bytes, continued) do
    {packets, continued, rest} = Parser.parse(bytes, continued)
    {:ok, packets, continued, rest}
  rescue
    RuntimeError -> :error
  end

  defp opus_header?(<<"OpusHead", _::binary>>), do: true
  defp opus_header?(<<"OpusTags", _::binary>>), do: true
  defp opus_header?(_packet), do: false

  defp header(page, packet), do: page |> Page.append_packet!(packet) |> Page.finalize(0)

  defp emit_reply(pcm, state) do
    skip = max(state.input_samples - state.received, 0) * 2

    case pcm do
      <<_::binary-size(^skip), reply::binary>> when reply != <<>> ->
        state.emit.({:audio, %Audio{data: reply, sample_rate: @rate}})

      _ ->
        :ok
    end
  end

  defp received(%{received: received, last_text: last} = state) do
    reply = received - state.input_samples

    cond do
      last != nil and received - last >= state.end_silence ->
        :done

      reply >= state.max_reply and last != nil ->
        :done

      reply >= state.max_reply ->
        {:error, :no_reply}

      true ->
        {state, frames} = top_up(state, received + @lead)
        {:cont, state, frames}
    end
  end

  defp top_up(state, target) do
    target = min(target, state.input_samples + state.max_reply + @lead)
    top_up(state, target, [])
  end

  defp top_up(%{sent: sent} = state, target, frames) when sent >= target,
    do: {state, Enum.reverse(frames)}

  defp top_up(state, target, frames) do
    pcm =
      if state.sent < state.input_samples,
        do: binary_part(state.input, state.sent * 2, @frame * 2),
        else: :binary.copy(<<0>>, @frame * 2)

    packets =
      for <<chunk::binary-size(@packet * 2) <- pcm>> do
        {:ok, packet} = Encoder.encode_packet(state.encoder, chunk, @packet)
        packet
      end

    sent = state.sent + @frame

    # One page per frame, so the server gets each frame at once. Ogg Opus
    # granule positions count 48 kHz samples.
    page =
      packets
      |> Enum.reduce(Page.create_subsequent(state.page), &Page.append_packet!(&2, &1))
      |> Page.finalize(sent * 2)

    state = %{state | sent: sent, page: page}
    top_up(state, target, [{:binary, <<1>> <> Page.serialize(page)} | frames])
  end
end
