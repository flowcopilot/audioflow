# AUDIOFLOW_WEBRTC=1 mix run examples/network/publish.exs [video.ivf]
# mix run examples/network/publish.exs --avatar speech-24k-mono-s16le.pcm

defmodule AudioFlow.NetworkPublishExample do
  alias AudioFlow.{WebRTC, Audio}
  alias AudioFlow.Avatars.LiveAvatar

  def main(["--avatar", path]) do
    {:ok, pcm} = File.read(path)

    {:ok, publisher} =
      LiveAvatar.start_link(
        owner: self(),
        api_key: fn -> System.fetch_env!("LIVEAVATAR_API_KEY") end,
        avatar_id: System.fetch_env!("LIVEAVATAR_AVATAR_ID"),
        audio: %Audio{data: pcm, sample_rate: 24_000}
      )

    avatar(publisher)
  end

  def main(args) do
    unless Code.ensure_loaded?(WebRTC),
      do: raise("Set AUDIOFLOW_WEBRTC=1 and run mix deps.get first")

    path = List.first(args) || Path.join(__DIR__, "assets/test-pattern.ivf")
    {:ok, %{frames: frames}} = AudioFlow.VideoOutput.IVF.read(path)

    if frames == [] or List.last(frames).pts_us > 30_000_000,
      do: raise("Example needs nonempty video no longer than 30 seconds")

    {:ok, sender} = WebRTC.start_link(owner: self())
    {:ok, receiver} = WebRTC.start_link(owner: self())

    try do
      {:ok, offer} = WebRTC.offer(sender)
      :ok = WebRTC.signal(receiver, offer)
      negotiate(sender, receiver, MapSet.new())
      key = make_ref()
      :ok = WebRTC.start_turn(sender, key)
      owner = self()

      producer =
        Task.async(fn ->
          # Merge one 20ms PCMU silence packet per tick with the video timeline.
          # Replace this source with a real encoder; no model inference is implied.
          audio =
            for pts <- 0..List.last(frames).pts_us//20_000,
                do: {:audio, :binary.copy(<<255>>, 160), pts}

          video = Enum.map(frames, &{:video, &1.data, &1.pts_us})
          epoch = System.monotonic_time(:microsecond)

          (audio ++ video)
          |> Enum.sort_by(&elem(&1, 2))
          |> Enum.each(fn {kind, data, pts} ->
            delay = div(epoch + pts - System.monotonic_time(:microsecond), 1000)
            if delay > 0, do: Process.sleep(delay)
            :ok = WebRTC.publish(sender, key, kind, data, pts)
          end)

          send(owner, :sent)
        end)

      expected_audio = div(List.last(frames).pts_us, 20_000) + 1
      receive_media(receiver, expected_audio, length(frames), %{audio: 0, video: 0, bytes: 0})
      Task.await(producer)
      :ok = WebRTC.flush(sender, key)

      IO.puts(
        "Loopback passed: #{expected_audio} PCMU packets, #{length(frames)} VP8 frames over negotiated ICE/DTLS/SRTP."
      )
    after
      for peer <- [sender, receiver], Process.alive?(peer), do: WebRTC.stop(peer)
    end
  end

  defp negotiate(a, b, connected) do
    if MapSet.size(connected) < 2 do
      receive do
        {WebRTC, source, {:signal, message}} ->
          :ok = WebRTC.signal(if(source == a, do: b, else: a), message)
          negotiate(a, b, connected)

        {WebRTC, source, :connected} ->
          negotiate(a, b, MapSet.put(connected, source))

        {WebRTC, _, {:media, _}} ->
          negotiate(a, b, connected)
      after
        10_000 -> raise("negotiation timed out")
      end
    end
  end

  defp receive_media(_, a, v, %{audio: a, video: v}), do: :ok

  defp receive_media(receiver, audio, video, counts) do
    receive do
      {WebRTC, ^receiver, {:media, {:rtp, _, nil, packet}}} ->
        counts =
          case packet.payload_type do
            0 -> Map.update!(counts, :audio, &(&1 + 1))
            96 -> Map.update!(counts, :video, &(&1 + if(packet.marker, do: 1, else: 0)))
          end

        receive_media(
          receiver,
          audio,
          video,
          Map.update!(counts, :bytes, &(&1 + byte_size(packet.payload)))
        )

      {WebRTC, _, _} ->
        receive_media(receiver, audio, video, counts)

      :sent ->
        receive_media(receiver, audio, video, counts)
    after
      5000 -> raise("media timeout: #{inspect(counts)}")
    end
  end

  defp avatar(publisher) do
    receive do
      {LiveAvatar, ^publisher, {:published, _publication}} ->
        IO.puts(
          "Provider publication ready. Forward the private room credentials to your authorized LiveKit client; this example does not print them."
        )

        avatar(publisher)

      {LiveAvatar, ^publisher, {:done, result}} ->
        IO.inspect(result, label: "Provider utterance result")
        avatar(publisher)

      {LiveAvatar, ^publisher, {:cleanup, result}} ->
        IO.inspect(result, label: "Provider cleanup")
    after
      75_000 ->
        LiveAvatar.cancel(publisher)
        raise("avatar timed out")
    end
  end
end

AudioFlow.NetworkPublishExample.main(System.argv())
