defmodule AudioFlow.Calls do
  @moduledoc """
  Durable calls on this node. Configure `config :audio_flow, :calls, options`
  and AudioFlow starts it (with `AUDIOFLOW_SFU=1`).

  Every node with this configuration renews the leases of its calls and
  claims calls whose leases expired: calls of a node that crashed, or of a
  node that drained. A claimed call starts again from its saved state and
  takes back its SFU participant, so the room keeps the same agent. See
  `start_link/1` for the options.
  """
  use Supervisor
  alias AudioFlow.Calls.Call
  alias AudioFlow.Calls.Claimer
  alias AudioFlow.CallStore

  @schema [
    store: [type: {:tuple, [:atom, :any]}, required: true, doc: "An `AudioFlow.CallStore`."],
    sfu: [type: :atom, doc: "The SFU node. Defaults to this node."],
    owner: [type: :string, doc: "The lease owner name. Defaults to the node name."],
    lease_ms: [type: :pos_integer, default: 10_000, doc: "Lease length; renewed every third."],
    claim_limit: [type: :pos_integer, default: 50, doc: "Calls claimed at most per renewal."],
    drain_timeout_ms: [
      type: :pos_integer,
      default: 10_000,
      doc: "How long a drain waits for running turns."
    ],
    interrupted_turn: [
      type: {:in, [:drop, :retry_input]},
      default: :drop,
      doc:
        "`:retry_input` submits the user input of a turn that a crash interrupted again, as text. Use it only with idempotent tools."
    ],
    retry_window_ms: [
      type: :pos_integer,
      default: 10_000,
      doc: "Interrupted input older than this is dropped."
    ],
    leave_grace_ms: [
      type: :non_neg_integer,
      default: 5_000,
      doc:
        "A call whose last user left ends after this time, unless a user joins again. A page reload leaves and joins again."
    ],
    empty_timeout_ms: [
      type: :pos_integer,
      default: 60_000,
      doc: "A call whose room has had no member other than agents for this long ends."
    ],
    resume_input: [
      type: {:or, [:string, nil]},
      default: nil,
      doc:
        "Text submitted as user input after a call moves to this node, for example an instruction to say that the agent is back."
    ]
  ]

  @doc "Options:\n\n" <> NimbleOptions.docs(@schema)
  def start_link(options) do
    options = NimbleOptions.validate!(options, @schema)

    options =
      options
      |> Keyword.put_new(:sfu, node())
      |> Keyword.put_new(:owner, Atom.to_string(node()))

    Supervisor.start_link(__MODULE__, options, name: __MODULE__)
  end

  @impl true
  def init(options) do
    children = [
      {Registry, keys: :unique, name: AudioFlow.Calls.Registry},
      {DynamicSupervisor, name: AudioFlow.Calls.Supervisor, strategy: :one_for_one},
      {Claimer, options}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc """
  Creates a call for `agent` (an `AudioFlow.Agent` module) in `room` and
  starts it on a node with calls, usually this one at once.
  """
  def start_call(room, agent, metadata \\ %{}) when is_binary(room) and is_atom(agent) do
    store = Claimer.store()

    with {:ok, call} <-
           CallStore.create(store, %{room: room, agent: Atom.to_string(agent), metadata: metadata}) do
      Claimer.claim_now()
      {:ok, call}
    end
  end

  @doc "The calls that run on this node, as `{id, pid}` pairs."
  def local do
    Registry.select(AudioFlow.Calls.Registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
  end

  @doc "The process of a call on this node."
  def whereis(id) do
    case Registry.lookup(AudioFlow.Calls.Registry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Stops claiming, lets running turns finish (up to `:drain_timeout_ms`),
  and hands each call over: its SFU participant waits as away, and its lease
  ends now, so another node claims it at once.
  """
  def drain, do: Claimer.drain()

  @doc false
  def start_child(call, options),
    do: DynamicSupervisor.start_child(AudioFlow.Calls.Supervisor, {Call, [call: call] ++ options})
end
