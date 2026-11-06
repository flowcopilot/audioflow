if System.get_env("AUDIOFLOW_MEDIA") == "1" do
  defmodule AudioFlow.MoshiTest do
    use ExUnit.Case, async: true
    alias AudioFlow.Adapters.Moshi
    alias AudioFlow.Audio
    alias AudioFlow.Test.MoshiServer

    @frame 1_920

    defp run(script, options) do
      owner = self()

      tone =
        for i <- 0..(2 * @frame - 1),
            into: <<>>,
            do: <<round(8000 * :math.sin(i / 10))::little-signed-16>>

      input = %Audio{data: tone, sample_rate: 24_000}
      options = [endpoint: MoshiServer.endpoint(owner, script: script)] ++ options

      Moshi.run(input, options, fn event ->
        send(owner, {:output, event})
        :ok
      end)
    end

    defp outputs do
      receive do
        {:output, event} -> [event | outputs()]
      after
        0 -> []
      end
    end

    test "sends Ogg Opus input then silence, drops input-period output, ends after silent text" do
      script = %{0 => "early", 3 => " Hi", 4 => " there."}
      assert :ok = run(script, end_silence_ms: 160)

      events = outputs()
      assert for({:text, text} <- events, do: text) == [" Hi", " there."]
      # Frames 0-1 answer the input. The reply is frames 2-6: after the last
      # text at frame 4, two silent frames reach the 160 ms end bound.
      assert byte_size(for({:audio, audio} <- events, into: <<>>, do: audio.data)) ==
               5 * @frame * 2

      assert_received {:client_pcm, <<>>}
      assert_received {:client_pcm, first}
      assert byte_size(first) == @frame * 2
      assert first |> :binary.bin_to_list() |> Enum.any?(&(&1 != 0))
    end

    test "fails with no_reply when the model stays silent for max_reply_ms" do
      assert {:error, :no_reply} = run(%{0 => "early"}, max_reply_ms: 160)
      assert outputs() |> Enum.filter(&match?({:text, _}, &1)) == []
    end

    test "rejects audio at another rate" do
      assert_raise ArgumentError, fn ->
        Moshi.run(%Audio{data: <<0, 0>>, sample_rate: 16_000}, [], fn _ -> :ok end)
      end
    end

    @tag :http_model
    test "a local Moshi server answers a spoken question" do
      endpoint = System.get_env("AUDIOFLOW_MOSHI_ENDPOINT", "ws://127.0.0.1:8998/api/chat")
      question = System.fetch_env!("AUDIOFLOW_MOSHI_PCM") |> File.read!()
      owner = self()

      assert :ok =
               Moshi.run(
                 %Audio{data: question, sample_rate: 24_000},
                 [endpoint: endpoint],
                 fn event ->
                   send(owner, {:output, event})
                   :ok
                 end
               )

      events = outputs()
      assert Enum.any?(events, &match?({:text, _}, &1))
      assert events |> Enum.filter(&match?({:audio, _}, &1)) |> length() > 0
    end
  end
end
