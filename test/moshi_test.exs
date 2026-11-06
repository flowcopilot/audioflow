if System.get_env("AUDIOFLOW_MEDIA") == "1" do
  defmodule AudioFlow.MoshiTest do
    use ExUnit.Case, async: true
    alias AudioFlow.Adapters.Moshi
    alias AudioFlow.Audio
    alias Membrane.Ogg.Opus, as: OggOpus
    alias Membrane.Ogg.Page
    alias Membrane.Ogg.Parser
    alias Membrane.Opus.Decoder.Native, as: Decoder
    alias Membrane.Opus.Encoder.Native, as: Encoder

    @frame 1_920

    # Answers each client frame with one 80 ms output page, then the text
    # scripted for that frame, like moshi_mlx.local_web.
    defmodule Server do
      @behaviour WebSock

      def init({owner, script}) do
        state = %{
          owner: owner,
          script: script,
          buffer: <<>>,
          continued: nil,
          decoder: Decoder.create(24_000, 1),
          encoder: Encoder.create(24_000, 1, 2049, -1000, 3001),
          frames: 0
        }

        head =
          Page.create_first(1)
          |> Page.append_packet!(OggOpus.create_id_header(1))
          |> Page.finalize(0)

        {:push, [{:binary, <<0>>}, {:binary, <<1>> <> Page.serialize(head)}], state}
      end

      def handle_in({<<1, data::binary>>, opcode: :binary}, state) do
        {packets, continued, rest} = Parser.parse(state.buffer <> data, state.continued)

        pcm =
          for %Parser.Packet{payload: packet} <- packets,
              not String.starts_with?(packet, ["OpusHead", "OpusTags"]),
              into: <<>>,
              do: Decoder.decode_packet(state.decoder, packet)

        send(state.owner, {:client_pcm, pcm})
        frames = div(byte_size(pcm), 2 * 1_920)

        replies =
          Enum.flat_map(state.frames..(state.frames + frames - 1)//1, fn index ->
            [{:binary, <<1>> <> output(state, index)}] ++
              for text <- List.wrap(state.script[index]), do: {:binary, <<2>> <> text}
          end)

        {:push, replies,
         %{state | buffer: rest, continued: continued, frames: state.frames + frames}}
      end

      def handle_info(_message, state), do: {:ok, state}

      defp output(state, index) do
        packets =
          for _ <- 1..4 do
            {:ok, packet} = Encoder.encode_packet(state.encoder, :binary.copy(<<0, 0>>, 480), 480)
            packet
          end

        page = %Page{bos: false, bitstream_serial_number: 1, page_sequence_number: index + 1}

        packets
        |> Enum.reduce(page, &Page.append_packet!(&2, &1))
        |> Page.finalize((index + 1) * 3_840)
        |> Page.serialize()
      end
    end

    defmodule Endpoint do
      def init(options), do: options

      def call(conn, options),
        do: conn |> WebSockAdapter.upgrade(Server, options, []) |> Plug.Conn.halt()
    end

    defp endpoint(script) do
      server =
        start_supervised!(
          {Bandit,
           plug: {Endpoint, {self(), script}}, port: 0, ip: {127, 0, 0, 1}, startup_log: false}
        )

      {:ok, {_, port}} = ThousandIsland.listener_info(server)
      "ws://127.0.0.1:#{port}/api/chat"
    end

    defp run(script, options) do
      owner = self()

      tone =
        for i <- 0..(2 * @frame - 1),
            into: <<>>,
            do: <<round(8000 * :math.sin(i / 10))::little-signed-16>>

      input = %Audio{data: tone, sample_rate: 24_000}
      options = [endpoint: endpoint(script)] ++ options

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
