defmodule AudioFlow.Application do
  @moduledoc false
  use Application

  @http_pool_schema [
    size: [
      type: :pos_integer,
      default: 50,
      doc: "Connections per pool. Each streaming LLM or TTS turn holds one."
    ],
    count: [
      type: :pos_integer,
      default: 1,
      doc: "Pools per host. The capacity per host is `size * count`."
    ],
    connect_timeout_ms: [
      type: :pos_integer,
      default: 5_000,
      doc: "Time to open a connection."
    ]
  ]

  @doc false
  def http_pool do
    options =
      AudioFlow.RuntimeOptions.validate!(
        Application.get_env(:audio_flow, :http_pool, []),
        @http_pool_schema
      )

    [
      protocols: [:http1],
      size: options[:size],
      count: options[:count],
      conn_opts: [transport_opts: [timeout: options[:connect_timeout_ms]]]
    ]
  end

  @impl true
  def start(_type, _args) do
    # ReqLLM has no Deepgram provider; AudioFlow.STT.ReqLLM uses this one.
    {:ok, :deepgram} = ReqLLM.Providers.register(AudioFlow.STT.DeepgramProvider)

    # Children stop in reverse order: durable calls, then sessions, then the
    # inference engines and the HTTP client that the sessions use.
    children =
      [
        {Finch, name: AudioFlow.HTTPClient, pools: %{default: http_pool()}},
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
