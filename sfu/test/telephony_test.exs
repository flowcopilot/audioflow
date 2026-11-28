defmodule AudioFlowSFU.TelephonyTest do
  use ExUnit.Case, async: false
  alias AudioFlowSFU.Native
  alias AudioFlowSFU.Signaling.Telephony
  alias AudioFlowSFU.TestAgent
  alias AudioFlowSFU.Token
  alias AudioFlowSFU.WebSocketClient, as: WS
  alias Membrane.Opus.Encoder.Native, as: Encoder

  setup do
    Application.put_env(:audio_flow_sfu, :api_keys, %{"key" => "secret"})
    on_exit(fn -> Application.put_env(:audio_flow_sfu, :api_keys, %{}) end)
    server = start_supervised!({Bandit, plug: AudioFlowSFU.Router, port: 0, ip: :loopback})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    %{port: port, room: "phone-#{System.unique_integer([:positive])}"}
  end

  # Twilio puts the token in a custom parameter of the start message.
  defp twilio_call(port, room) do
    socket = WS.connect(port, "/telephony/twilio")
    WS.send_json(socket, %{event: "connected"})
    token = Token.generate("key", "secret", "caller", room)

    WS.send_json(socket, %{
      event: "start",
      streamSid: "MZ1",
      start: %{streamSid: "MZ1", customParameters: %{access_token: token}}
    })

    socket
  end

  defp opus_tone do
    encoder = Encoder.create(48_000, 1, 2048, -1000, 3001)

    pcm =
      for i <- 0..959,
          into: <<>>,
          do: <<round(:math.sin(i / 48 * :math.pi()) * 12_000)::little-signed-16>>

    {:ok, packet} = Encoder.encode_packet(encoder, pcm, 960)
    packet
  end

  defp agent_audio(agent, participant, track, socket) do
    Enum.reduce_while(1..50, nil, fn n, _ ->
      TestAgent.send_rtp(agent, participant, track, n, opus_tone())

      case WS.recv(socket, 100) do
        {:json, %{"event" => "media"}} = media -> {:halt, media}
        _ -> {:cont, nil}
      end
    end)
  end

  test "a phone call and an agent hear each other, and the call survives an agent restart",
       %{port: port, room: room} do
    socket = twilio_call(port, room)
    agent = TestAgent.start(self())

    {:ok, join} = await_join(room, agent)
    assert [%{identity: "caller", kind: :sip, tracks: [%{mime_type: "audio/PCMU"}]}] = join.others
    {:ok, track} = Native.publish_track(join.participant)

    # Caller to agent: μ-law passes through as PCMU.
    mulaw = :binary.copy(<<0x7E>>, 160)

    WS.send_json(socket, %{
      event: "media",
      streamSid: "MZ1",
      media: %{track: "inbound", chunk: "1", payload: Base.encode64(mulaw)}
    })

    assert_receive {:agent, ^agent, {:audio_flow_sfu, 1, _, {:rtp, _, %{payload: ^mulaw}}}}, 3000

    # Agent to caller: Opus is decoded at 8 kHz and sent as 160-byte μ-law.
    assert {:json, %{"streamSid" => "MZ1", "media" => %{"payload" => payload}}} =
             agent_audio(agent, join.participant, track.sid, socket)

    assert byte_size(Base.decode64!(payload)) == 160

    # The agent stops; the phone call stays; a new agent takes the participant back.
    Process.exit(agent, :kill)
    Process.sleep(100)
    agent = TestAgent.start(self())
    {:ok, resumed} = Native.join(room, "agent", agent, resume_token: join.resume_token)
    assert resumed.participant == join.participant
    assert {:json, %{"media" => _}} = agent_audio(agent, join.participant, track.sid, socket)

    WS.send_json(socket, %{event: "stop", streamSid: "MZ1"})

    assert_receive {:agent, ^agent, {:audio_flow_sfu, 1, _, {:participant_left, %{kind: :sip}}}},
                   3000
  end

  test "phone audio that is not a multiple of 20 ms is buffered, not dropped",
       %{port: port, room: room} do
    socket = twilio_call(port, room)
    agent = TestAgent.start(self())
    {:ok, _join} = await_join(room, agent)
    audio = for n <- 0..319, into: <<>>, do: <<n::8>>

    media = fn bytes ->
      WS.send_json(socket, %{
        event: "media",
        streamSid: "MZ1",
        media: %{track: "inbound", payload: Base.encode64(bytes)}
      })
    end

    # 100 bytes make no packet; the next 220 complete two.
    media.(binary_part(audio, 0, 100))
    refute_receive {:agent, ^agent, {:audio_flow_sfu, 1, _, {:rtp, _, _}}}, 200
    media.(binary_part(audio, 100, 220))

    assert_receive {:agent, ^agent, {:audio_flow_sfu, 1, _, {:rtp, _, %{payload: first}}}}, 3000
    assert_receive {:agent, ^agent, {:audio_flow_sfu, 1, _, {:rtp, _, %{payload: second}}}}, 3000
    assert first <> second == audio
    refute_receive {:agent, ^agent, {:audio_flow_sfu, 1, _, {:rtp, _, _}}}, 200
  end

  test "a stream without a valid token is closed", %{port: port, room: room} do
    socket = WS.connect(port, "/telephony/telnyx?access_token=bad")
    WS.send_json(socket, %{event: "start", stream_id: "s", start: %{}})
    assert {:close, <<1008::16, _::binary>>} = WS.recv(socket, 3000)

    socket = WS.connect(port, "/telephony/twilio")
    WS.send_json(socket, %{event: "media", media: %{payload: ""}})
    assert {:close, <<1008::16, _::binary>>} = WS.recv(socket, 3000)
    assert Native.join(room, "x", self()) |> elem(0) == :ok
  end

  test "μ-law encoding matches G.711" do
    assert Telephony.mulaw(<<0::little-signed-16>>) == <<0xFF>>
    assert Telephony.mulaw(<<32_767::little-signed-16>>) == <<0x80>>
    assert Telephony.mulaw(<<-32_768::little-signed-16>>) == <<0x00>>
    assert Telephony.mulaw(<<-1::little-signed-16>>) == <<0x7F>>
  end

  # The phone joins when its start message arrives; join after it.
  defp await_join(room, agent, attempts \\ 50) do
    case AudioFlowSFU.Room.whereis(room) do
      pid when is_pid(pid) and attempts > 0 ->
        if AudioFlowSFU.Room.participants(pid) != [],
          do: Native.join(room, "agent", agent),
          else: retry(room, agent, attempts)

      _ ->
        retry(room, agent, attempts)
    end
  end

  defp retry(_room, _agent, 0), do: flunk("the phone did not join")

  defp retry(room, agent, attempts) do
    Process.sleep(50)
    await_join(room, agent, attempts - 1)
  end
end
