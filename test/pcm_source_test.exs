if System.get_env("AUDIOFLOW_MEDIA") == "1" do
  defmodule AudioFlow.PCMSourceTest do
    use ExUnit.Case, async: true
    @moduletag capture_log: true
    import Membrane.ChildrenSpec
    import Membrane.Testing.Assertions

    test "a final partial device block is padded at the exact sample boundary" do
      audio = %AudioFlow.Audio{data: <<123::little-signed-16>>, sample_rate: 24000}

      broker =
        spawn(fn ->
          for result <- [audio, :end_of_stream] do
            receive do
              {:take_pcm, _key, source, request} -> send(source, {:pcm, request, result})
            end
          end
        end)

      on_exit(fn -> if Process.alive?(broker), do: Process.exit(broker, :kill) end)

      spec =
        child(:source, %AudioFlow.PCMSource{
          playback: broker,
          key: {self(), make_ref()},
          sample_rate: 24000,
          alignment_samples: 256
        })
        |> child(:sink, Membrane.Testing.Sink)

      pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)

      assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{
        payload: <<123::little-signed-16>>,
        pts: 0
      })

      assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: padding, pts: 41666})
      assert padding == :binary.copy(<<0, 0>>, 255)
      assert_end_of_stream(pipeline, :sink)
    end
  end
end
