if System.get_env("AUDIOFLOW_SFU") == "1" do
  defmodule AudioFlowSFU.Native do
    @moduledoc false
    # A stand-in for the SFU side of AudioFlowSFU.Native in AudioFlow tests.
    # The fake participant relays agent messages to the test process, and the
    # test sends SFU messages to the agent itself. `join: [test: pid]` names the
    # test process; `others:` sets the room members; `delay:` (ms) makes the
    # join slow.

    def join(room, identity, agent, options) do
      if Keyword.get(options, :resume_token) == "expired",
        do: {:error, :unknown_session},
        else: start(room, identity, agent, options)
    end

    defp start(_room, identity, agent, options) do
      if delay = Keyword.get(options, :delay), do: Process.sleep(delay)
      test = Keyword.fetch!(options, :test)
      tracks = Keyword.get(options, :tracks, [])
      participant = spawn(fn -> relay(test) end)
      send(test, {:sfu_join, participant, agent, options})

      {:ok,
       %{
         participant: participant,
         info: %{sid: "PA_agent", identity: identity, kind: :agent, tracks: tracks},
         others: Keyword.get(options, :others, []),
         resume_token: "token"
       }}
    end

    def publish_track(_participant, mime_type, name),
      do: {:ok, %{sid: "TR_agent", mime_type: mime_type, name: name}}

    defp relay(test) do
      receive do
        message ->
          send(test, {:sfu_participant, self(), message})
          relay(test)
      end
    end
  end
end
