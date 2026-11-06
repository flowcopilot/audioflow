if Code.ensure_loaded?(Membrane.Ogg.Parser) do
  defmodule AudioFlow.Test.MoshiServer do
    @moduledoc """
    Local Moshi WebSocket fixture with the `moshi_mlx.local_web` framing.

    It sends `{:moshi_server, pid}` to the owner, then the handshake and the
    Ogg Opus head page. For each client message it sends `{:client_pcm, pcm}`
    with the decoded PCM, then answers each 80 ms frame with one 80 ms silent
    output page and the `:script` text for that frame index. On exit it sends
    `:moshi_server_closed`.

    Options: `:script` (map of frame index to text), `handshake: :manual`
    (send `:handshake` to the pid), `reply: :manual` (send `:reply` to answer
    the frames received so far). Send `:close` to close the connection.
    """
    @behaviour WebSock
    alias Membrane.Ogg.Opus, as: OggOpus
    alias Membrane.Ogg.Page
    alias Membrane.Ogg.Parser
    alias Membrane.Opus.Decoder.Native, as: Decoder
    alias Membrane.Opus.Encoder.Native, as: Encoder

    @frame 1_920

    def endpoint(owner, options \\ []) do
      server =
        ExUnit.Callbacks.start_supervised!(
          {Bandit,
           plug: {__MODULE__.Endpoint, {owner, options}},
           port: 0,
           ip: {127, 0, 0, 1},
           startup_log: false}
        )

      {:ok, {_, port}} = ThousandIsland.listener_info(server)
      "ws://127.0.0.1:#{port}/api/chat"
    end

    defmodule Endpoint do
      @moduledoc false
      def init(options), do: options

      def call(conn, options) do
        conn
        |> WebSockAdapter.upgrade(AudioFlow.Test.MoshiServer, options, [])
        |> Plug.Conn.halt()
      end
    end

    @impl true
    def init({owner, options}) do
      send(owner, {:moshi_server, self()})

      state = %{
        owner: owner,
        script: Keyword.get(options, :script, %{}),
        reply: Keyword.get(options, :reply, :auto),
        buffer: <<>>,
        continued: nil,
        decoder: Decoder.create(24_000, 1),
        encoder: Encoder.create(24_000, 1, 2049, -1000, 3001),
        received: 0,
        answered: 0
      }

      case Keyword.get(options, :handshake, :auto) do
        :auto -> {:push, handshake(), state}
        :manual -> {:ok, state}
      end
    end

    @impl true
    def handle_in({<<1, data::binary>>, opcode: :binary}, state) do
      {packets, continued, rest} = Parser.parse(state.buffer <> data, state.continued)

      pcm =
        for %Parser.Packet{payload: packet} <- packets,
            not String.starts_with?(packet, ["OpusHead", "OpusTags"]),
            into: <<>>,
            do: Decoder.decode_packet(state.decoder, packet)

      send(state.owner, {:client_pcm, pcm})

      state = %{
        state
        | buffer: rest,
          continued: continued,
          received: state.received + div(byte_size(pcm), 2 * @frame)
      }

      if state.reply == :auto, do: answer(state), else: {:ok, state}
    end

    @impl true
    def handle_info(:handshake, state), do: {:push, handshake(), state}
    def handle_info(:reply, state), do: answer(state)
    def handle_info(:close, state), do: {:stop, :normal, state}
    def handle_info({:push, frames}, state), do: {:push, frames, state}

    @impl true
    def terminate(_reason, state) do
      send(state.owner, :moshi_server_closed)
      :ok
    end

    defp handshake do
      head =
        Page.create_first(1)
        |> Page.append_packet!(OggOpus.create_id_header(1))
        |> Page.finalize(0)

      [{:binary, <<0>>}, {:binary, <<1>> <> Page.serialize(head)}]
    end

    defp answer(state) do
      replies =
        Enum.flat_map(state.answered..(state.received - 1)//1, fn index ->
          [{:binary, <<1>> <> output(state, index)}] ++
            for text <- List.wrap(state.script[index]), do: {:binary, <<2>> <> text}
        end)

      {:push, replies, %{state | answered: state.received}}
    end

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
end
