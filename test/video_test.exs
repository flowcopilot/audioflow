if System.get_env("AUDIOFLOW_MEDIA") == "1" do
  defmodule AudioFlow.VideoTest do
    use ExUnit.Case, async: false
    @moduletag :tmp_dir
    @moduletag capture_log: true
    alias AudioFlow.{Image, Video}

    test "RGB sources obey read demand and selection uses presentation time" do
      {:ok, supervisor, reader} =
        Video.start_link(source: %AudioFlow.Test.VideoSource{owner: self()})

      on_exit(fn -> Video.close(reader) end)
      assert {:ok, %Image{pts: 0, width: 64, height: 48}} = Video.next_frame(reader)
      assert_receive {:video_produced, source, 0}
      refute_receive {:video_produced, ^source, 3}, 30
      assert {:ok, %Image{pts: 1_000_000_000, data: data}} = Video.next_frame(reader)
      assert data == :binary.copy(<<2, 0, 0>>, 64 * 48)
      monitor = Process.monitor(supervisor)
      assert :ok = Video.close(reader)
      assert_receive {:DOWN, ^monitor, :process, ^supervisor, _}
    end

    test "MP4 decoding preserves RGB frames and PTS while discarding the audio track", %{
      tmp_dir: dir
    } do
      path = Path.join(dir, "sample.mp4")

      {_, 0} =
        System.cmd("ffmpeg", [
          "-v",
          "error",
          "-f",
          "lavfi",
          "-i",
          "testsrc2=size=64x48:rate=2:duration=3",
          "-f",
          "lavfi",
          "-i",
          "sine=frequency=440:sample_rate=8000:duration=3",
          "-map",
          "0:v",
          "-map",
          "1:a",
          "-c:v",
          "libx264",
          "-pix_fmt",
          "yuv420p",
          "-c:a",
          "aac",
          path
        ])

      images = Video.frames(path) |> Enum.to_list()
      assert Enum.map(images, & &1.pts) == [0, 1_000_000_000, 2_000_000_000]
      assert Enum.all?(images, &Image.valid?/1)

      {reference, 0} =
        System.cmd("ffmpeg", [
          "-v",
          "error",
          "-i",
          path,
          "-vf",
          "select='not(mod(n,2))'",
          "-fps_mode",
          "passthrough",
          "-f",
          "rawvideo",
          "-pix_fmt",
          "rgb24",
          "pipe:1"
        ])

      actual = Enum.map_join(images, & &1.data)
      assert byte_size(actual) == byte_size(reference)
      differences = Enum.zip(:binary.bin_to_list(actual), :binary.bin_to_list(reference))
      assert Enum.all?(differences, fn {actual, expected} -> abs(actual - expected) <= 3 end)

      assert [%Image{width: 32, height: 32, data: scaled}] =
               Video.frames(path, width: 32, height: 32, max_frame_bytes: 3072) |> Enum.take(1)

      assert byte_size(scaled) == 3072
    end

    test "stream cleanup stops sources after early halt or a consumer exception" do
      for mode <- [:halt, :throw] do
        stream = Video.frames(%AudioFlow.Test.VideoSource{owner: self()})

        case mode do
          :halt ->
            assert [%Image{}] = Enum.take(stream, 1)

          :throw ->
            assert catch_throw(Enum.each(stream, fn _ -> throw(:consumer_stopped) end)) ==
                     :consumer_stopped
        end

        assert_receive {:video_produced, source, 0}
        ref = Process.monitor(source)
        assert_receive {:DOWN, ^ref, :process, ^source, _}
      end
    end

    test "owner exit stops a reader even when no read is pending" do
      parent = self()

      owner =
        spawn(fn ->
          {:ok, supervisor, reader} =
            Video.start_link(source: %AudioFlow.Test.VideoSource{owner: parent})

          send(parent, {:reader, supervisor, reader})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:reader, supervisor, reader}
      ref = Process.monitor(reader)
      sup_ref = Process.monitor(supervisor)
      send(owner, :stop)
      assert_receive {:DOWN, ^ref, :process, ^reader, _}
      assert_receive {:DOWN, ^sup_ref, :process, ^supervisor, _}
    end

    test "frame byte limits return an error and the reader can be closed" do
      {:ok, _supervisor, reader} =
        Video.start_link(source: %AudioFlow.Test.VideoSource{owner: self()}, max_frame_bytes: 2)

      assert {:error, :frame_too_large} = Video.next_frame(reader)
      assert :ok = Video.close(reader)
    end

    test "raw timestamp mode retains a source time offset" do
      frames =
        Video.frames(
          %AudioFlow.Test.VideoSource{owner: self(), frames: 3, start_pts: 4_000_000_000},
          normalize_timestamps?: false
        )
        |> Enum.to_list()

      assert Enum.map(frames, & &1.pts) == [4_000_000_000, 5_000_000_000]
    end

    test "unsupported tracks and decoder failures return errors without stopping the owner", %{
      tmp_dir: dir
    } do
      audio = Path.join(dir, "audio.mp4")

      {_, 0} =
        System.cmd("ffmpeg", [
          "-v",
          "error",
          "-f",
          "lavfi",
          "-i",
          "sine=frequency=440:sample_rate=8000:duration=1",
          "-c:a",
          "aac",
          "-movflags",
          "+faststart",
          audio
        ])

      {:ok, _, reader} = Video.start_link(location: audio)
      assert {:error, :no_h264_track} = Video.next_frame(reader)
      assert :ok = Video.close(reader)

      {:ok, _, reader} = Video.start_link(location: Path.join(dir, "missing.mp4"))
      assert {:error, {:decode_failed, _}} = Video.next_frame(reader)
      assert :ok = Video.close(reader)
    end
  end
end
