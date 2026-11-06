defmodule AudioFlow.Duplex.Moshi do
  @moduledoc """
  `AudioFlow.Duplex` adapter for a local Kyutai Moshi server
  (`moshi_mlx.local_web` or the PyTorch `moshi.server`). Requires
  `AUDIOFLOW_MEDIA=1` for Ogg Opus.

  Input is mono s16le PCM at 24 kHz. The adapter sends each complete 80 ms
  frame (1,920 samples, 3,840 bytes) as one Ogg page of four 20 ms Opus
  packets. A shorter remainder waits for the next push. Push 3,840-byte chunks
  to send each frame at once.

  The session emits all decoded model audio and every text token as it
  arrives, also while input continues. Moshi does not transcribe the user.

  Option: `:endpoint` (`"ws://127.0.0.1:8998/api/chat"`).
  """
  @behaviour AudioFlow.Duplex.Adapter
  alias AudioFlow.Audio
  alias AudioFlow.Moshi.Codec

  @endpoint "ws://127.0.0.1:8998/api/chat"

  @impl true
  def config(options) do
    options = Keyword.validate!(options, endpoint: @endpoint)
    endpoint = options[:endpoint]

    unless is_binary(endpoint), do: raise(ArgumentError, "endpoint must be a string")

    %{url: endpoint, headers: [], sample_rate: Codec.rate(), options: []}
  end

  @impl true
  def init([]), do: %{codec: Codec.new(), ready: false, pending: <<>>}

  @impl true
  def handle_frame(frame, state) do
    case {Codec.wire(frame), state.ready} do
      {{:ok, :ready}, false} ->
        {codec, headers} = Codec.headers(state.codec)
        {:ok, [:ready], [headers], %{state | codec: codec, ready: true}}

      {{:ok, {:text, text}}, true} ->
        {:ok, [{:text, text}], [], state}

      {{:ok, {:audio, data}}, true} ->
        case Codec.decode(state.codec, data) do
          {:ok, codec, <<>>} -> {:ok, [], [], %{state | codec: codec}}
          {:ok, codec, pcm} -> {:ok, [audio(pcm)], [], %{state | codec: codec}}
          :error -> {:error, :invalid_audio}
        end

      _ ->
        {:error, :invalid_event}
    end
  end

  @impl true
  def handle_audio(%Audio{data: data}, state) do
    size = Codec.frame_samples() * 2
    {frames, pending} = split(state.pending <> data, size, [])

    {codec, pages} =
      Enum.reduce(frames, {state.codec, []}, fn pcm, {codec, pages} ->
        {codec, page} = Codec.encode(codec, pcm)
        {codec, [page | pages]}
      end)

    {:ok, Enum.reverse(pages), %{state | codec: codec, pending: pending}}
  end

  defp split(pcm, size, frames) when byte_size(pcm) < size, do: {Enum.reverse(frames), pcm}

  defp split(pcm, size, frames) do
    <<frame::binary-size(^size), rest::binary>> = pcm
    split(rest, size, [frame | frames])
  end

  defp audio(pcm), do: {:audio, %Audio{data: pcm, sample_rate: Codec.rate()}}
end
