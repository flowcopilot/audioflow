# AUDIOFLOW_WEBRTC=1 mix run examples/network/voice_agent.exs
# Local two-peer synthetic voice-agent exercise. No microphone, model or credentials.
Logger.configure(level: :warning)

defmodule AudioFlow.NetworkVoiceAgent do
  alias AudioFlow.{Audio, WebRTC}
  alias AudioFlow.WebRTC.Session
  alias AudioFlow.Telephony.MuLaw

  defmodule Energy do
    @behaviour AudioFlow.VoiceDetector
    def init(_), do: {320, 16_000, nil}

    def predict(%Audio{data: data}, state) do
      peak = for(<<x::little-signed-16 <- data>>, do: abs(x)) |> Enum.max()
      {if(peak > 1000, do: 1.0, else: 0.0), state}
    end
  end

  def main do
    IO.puts(
      "SYNTHETIC DEMO: fixed transcript/reply and silent PCM from Adapters.Demo; no speech inference."
    )

    {:ok, agent} =
      Session.start_link(
        owner: self(),
        session: AudioFlow.Adapters.Demo.options(),
        vad: {Energy, []},
        voice_input: [min_speech_ms: 20, min_silence_ms: 40, pre_roll_ms: 0]
      )

    {:ok, client} = WebRTC.start_link(owner: self())

    try do
      {:ok, offer} = WebRTC.offer(client)
      :ok = Session.signal(agent, offer)
      negotiate(client, agent, MapSet.new())
      key = make_ref()
      :ok = WebRTC.start_turn(client, key)
      speech = MuLaw.encode(:binary.copy(<<10_000::little-signed-16>>, 160))

      for {payload, i} <-
            Enum.with_index([speech | List.duplicate(:binary.copy(<<255>>, 160), 4)]) do
        :ok = WebRTC.publish(client, key, :audio, payload, i * 20_000)
        Process.sleep(20)
      end

      receive_reply(client, agent, 0, false)
    after
      if Process.alive?(agent), do: Session.stop(agent)
      if Process.alive?(client), do: WebRTC.stop(client)
    end
  end

  defp negotiate(client, agent, ready) do
    if MapSet.size(ready) < 2 do
      receive do
        {WebRTC, ^client, {:signal, m}} ->
          :ok = Session.signal(agent, m)
          negotiate(client, agent, ready)

        {Session, ^agent, {:signal, m}} ->
          :ok = WebRTC.signal(client, m)
          negotiate(client, agent, ready)

        {WebRTC, ^client, :connected} ->
          negotiate(client, agent, MapSet.put(ready, client))

        {Session, ^agent, :connected} ->
          negotiate(client, agent, MapSet.put(ready, agent))
      after
        10_000 -> raise "local negotiation timed out"
      end
    end
  end

  defp receive_reply(_, _, count, true) when count >= 6 do
    IO.puts(
      "Received #{count} PCMU response packets over local ICE/DTLS/SRTP. No playout/acoustic claim."
    )
  end

  defp receive_reply(client, agent, count, done) do
    receive do
      {Session, ^agent, {:session, _, {:done, _}}} ->
        receive_reply(client, agent, count, true)

      {Session, ^agent, {:session, _, {kind, text}}} when kind in [:text, :transcript] ->
        IO.puts("SYNTHETIC DEMO #{kind}: #{text}")
        receive_reply(client, agent, count, done)

      {Session, ^agent, {:error, reason}} ->
        raise inspect(reason)

      {WebRTC, ^client, {:media, {:rtp, _, nil, %{payload_type: 0}}}} ->
        receive_reply(client, agent, count + 1, done)

      _ ->
        receive_reply(client, agent, count, done)
    after
      5000 -> raise "response timeout"
    end
  end
end

AudioFlow.NetworkVoiceAgent.main()
