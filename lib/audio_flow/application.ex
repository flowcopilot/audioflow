defmodule AudioFlow.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # ReqLLM has no Deepgram provider; AudioFlow.STT.ReqLLM uses this one.
    {:ok, :deepgram} = ReqLLM.Providers.register(AudioFlow.STT.DeepgramProvider)

    # Children stop in reverse order: durable calls, then sessions, then the
    # inference engines and the HTTP client that the sessions use.
    children =
      [
        {Finch,
         name: AudioFlow.HTTPClient,
         pools: %{default: [protocols: [:http1], conn_opts: [transport_opts: [timeout: 5_000]]]}},
        {Task.Supervisor, name: AudioFlow.Tasks}
      ] ++
        Application.get_env(:audio_flow, :inference_children, []) ++
        [{DynamicSupervisor, name: AudioFlow.Sessions, strategy: :one_for_one}] ++ calls()

    Supervisor.start_link(children, strategy: :one_for_one, name: AudioFlow.Supervisor)
  end

  # Durable calls run when `:calls` is configured and lib_sfu is compiled
  # (AUDIOFLOW_SFU=1). Without the SFU code, a configuration is an error.
  defp calls do
    case Application.get_env(:audio_flow, :calls) do
      nil ->
        []

      options ->
        calls = Module.concat(AudioFlow, Calls)

        unless Code.ensure_loaded?(calls),
          do: raise(ArgumentError, ":calls needs AudioFlow built with AUDIOFLOW_SFU=1")

        [{calls, options}]
    end
  end

  # Before the supervision tree stops (a deploy or SIGTERM), durable calls
  # finish their turn, save, and release their leases, so that another node
  # takes them over at once.
  @impl true
  def prep_stop(state) do
    calls = Module.concat(AudioFlow, Calls)
    if Process.whereis(calls), do: calls.drain()
    state
  end
end
