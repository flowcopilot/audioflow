defmodule AudioFlow.Moshi.Codec do
  @moduledoc false
  # Moshi wire framing: binary WebSocket messages with a one-byte kind, `0`
  # handshake, `1` Ogg Opus audio (24 kHz mono), `2` UTF-8 text. Client audio
  # is one Ogg page per 80 ms frame, four 20 ms Opus packets per page, so the
  # server gets each frame at once.
  alias Membrane.Ogg.Opus, as: OggOpus
  alias Membrane.Ogg.Page
  alias Membrane.Ogg.Parser
  alias Membrane.Opus.Decoder.Native, as: Decoder
  alias Membrane.Opus.Encoder.Native, as: Encoder

  @rate 24_000
  @frame 1_920
  @packet 480
  # libopus OPUS_APPLICATION_AUDIO, OPUS_AUTO bitrate, OPUS_SIGNAL_VOICE.
  @application 2049
  @bitrate -1000
  @signal 3001
  @max_pending_bytes 262_144

  def rate, do: @rate
  def frame_samples, do: @frame

  def new do
    %{
      encoder: Encoder.create(@rate, 1, @application, @bitrate, @signal),
      decoder: Decoder.create(@rate, 1),
      buffer: <<>>,
      continued: nil,
      page: nil,
      granule: 0
    }
  end

  def wire({:binary, <<0>>}), do: {:ok, :ready}
  def wire({:binary, <<1, data::binary>>}), do: {:ok, {:audio, data}}

  def wire({:binary, <<2, text::binary>>}),
    do: if(String.valid?(text), do: {:ok, {:text, text}}, else: :error)

  def wire(_frame), do: :error

  def headers(codec) do
    head = header(Page.create_first(:rand.uniform(0xFFFFFFFF) - 1), OggOpus.create_id_header(1))
    tags = header(Page.create_subsequent(head), OggOpus.create_comment_header())
    {%{codec | page: tags}, {:binary, <<1>> <> Page.serialize(head) <> Page.serialize(tags)}}
  end

  defp header(page, packet), do: page |> Page.append_packet!(packet) |> Page.finalize(0)

  # `pcm` is exactly one 80 ms frame. Ogg Opus granule positions count 48 kHz
  # samples.
  def encode(codec, <<pcm::binary-size(@frame * 2)>>) do
    granule = codec.granule + @frame * 2

    page =
      for <<chunk::binary-size(@packet * 2) <- pcm>>,
        reduce: Page.create_subsequent(codec.page) do
        page ->
          {:ok, packet} = Encoder.encode_packet(codec.encoder, chunk, @packet)
          Page.append_packet!(page, packet)
      end
      |> Page.finalize(granule)

    {%{codec | page: page, granule: granule}, {:binary, <<1>> <> Page.serialize(page)}}
  end

  # Returns the PCM of all complete Opus packets. Partial pages stay buffered.
  def decode(codec, data) do
    {packets, continued, rest} = Parser.parse(codec.buffer <> data, codec.continued)

    pcm =
      for %Parser.Packet{payload: packet} <- packets, not opus_header?(packet), into: <<>> do
        Decoder.decode_packet(codec.decoder, packet)
      end

    if byte_size(rest) + byte_size(continued || <<>>) > @max_pending_bytes do
      :error
    else
      {:ok, %{codec | buffer: rest, continued: continued}, pcm}
    end
  rescue
    # Parser.parse/2 raises on a corrupt page.
    _error in [RuntimeError, ErlangError] -> :error
  end

  defp opus_header?(<<"OpusHead", _::binary>>), do: true
  defp opus_header?(<<"OpusTags", _::binary>>), do: true
  defp opus_header?(_packet), do: false
end
