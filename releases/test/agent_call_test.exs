defmodule AudioFlowReleases.AgentCallTest do
  use ExUnit.Case, async: false
  import AudioFlowSFU.MediaAssertions
  alias AudioFlow.Audio
  alias AudioFlow.SFU.Participant, as: Agent
  alias AudioFlowReleases.AmplitudeDetector
  alias AudioFlowReleases.Opus
  alias AudioFlowSFU.TestClient

  defp function(fun), do: {AudioFlow.Adapters.Function, run: fun}

  defp session do
    [
      stt: function(fn _audio, emit -> emit.("hello") end),
      llm: function(fn "hello", emit -> emit.("hi there") end),
      tts:
        function(fn "hi there", emit ->
          emit.(%Audio{data: :binary.copy(<<0x10, 0x27>>, 9600), sample_rate: 16_000})
        end)
    ]
  end

  test "a WebRTC user talks to an AudioFlow agent through the SFU" do
    room = "call-#{System.unique_integer([:positive])}"
    {:ok, user} = TestClient.start(room, "user")
    connected(user)
    assert_receive {:client, ^user, {:track_published, _}}, 5000

    {:ok, agent} =
      Agent.start_link(
        room: room,
        identity: "agent",
        session: session(),
        vad: {AmplitudeDetector, []},
        voice_input: [min_speech_ms: 20, min_silence_ms: 100, pre_roll_ms: 0]
      )

    assert_receive {:client, ^user, {:participant_joined, %{identity: "agent", kind: :agent}}}, 5000
    %{info: %{tracks: [%{sid: agent_track}]}} = Agent.join_info(agent)
    await_offer(user, &(agent_track in Map.values(&1)))

    for payload <- Opus.frames(15, 15), do: TestClient.send_audio(user, payload)
    assert_receive {Agent, ^agent, {:utterance, _}}, 5000

    # The spoken reply comes back to the user as Opus on the agent's track.
    assert_receive {:client, ^user, {:rtp, packet}}, 5000
    assert byte_size(Opus.decode(packet.payload)) == 1920
    assert_receive {Agent, ^agent, {:session, _, {:done, _}}}, 5000
  end
end
