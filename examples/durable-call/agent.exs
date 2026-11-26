# A durable-call agent node. Run from the repository root:
#
#   AUDIOFLOW_SFU=1 AUDIOFLOW_POSTGRES_URL=postgres://user:pass@host:port/db \
#     elixir --name agent_a@127.0.0.1 --cookie audioflow \
#     -S mix run --no-start examples/durable-call/agent.exs [--create ROOM]
#
# The agent answers each utterance with a short tone and keeps the history.
# Every agent node claims calls whose leases expired, so a call survives the
# loss of the node that runs it.
defmodule DurableCall.Energy do
  @moduledoc false
  def init(_), do: {320, 16_000, nil}

  def predict(%AudioFlow.Audio{data: data}, state) do
    peak = for(<<x::little-signed-16 <- data>>, do: abs(x)) |> Enum.max()
    {if(peak > 2_000, do: 1.0, else: 0.0), state}
  end
end

defmodule DurableCall.Agent do
  @moduledoc false
  @behaviour AudioFlow.Agent
  alias AudioFlow.Adapters.Function
  alias AudioFlow.Audio

  @impl true
  def session_options(_call) do
    tone =
      for i <- 0..6_399,
          into: <<>>,
          do: <<round(:math.sin(i * 2 * :math.pi() * 660 / 16_000) * 8_000)::little-signed-16>>

    [
      history: true,
      stt: {Function, run: fn _audio, emit -> emit.("beep") end},
      llm:
        {Function,
         run: fn messages, emit ->
           IO.puts("#{node()}: turn with #{length(messages)} messages")
           emit.("Answer #{div(length(messages) + 1, 2)}.")
         end},
      tts: {Function, run: fn _text, emit -> emit.(%Audio{data: tone, sample_rate: 16_000}) end}
    ]
  end

  @impl true
  def participant_options(_call) do
    [
      vad: {DurableCall.Energy, []},
      voice_input: [min_speech_ms: 60, min_silence_ms: 300, pre_roll_ms: 0]
    ]
  end
end

url = System.fetch_env!("AUDIOFLOW_POSTGRES_URL") |> URI.parse()
[user | password] = String.split(url.userinfo || "postgres", ":", parts: 2)

database = [
  name: DurableCall.DB,
  hostname: url.host,
  port: url.port || 5432,
  database: String.trim_leading(url.path, "/"),
  username: user,
  password: List.first(password)
]

sfu = String.to_atom(System.get_env("SFU_NODE", "sfu@127.0.0.1"))
true = Node.connect(sfu)

Application.put_env(:audio_flow, :calls,
  store: {AudioFlow.CallStore.Postgres, connection: DurableCall.DB},
  sfu: sfu,
  lease_ms: String.to_integer(System.get_env("LEASE_MS", "5000"))
)

{:ok, _} = Application.ensure_all_started(:postgrex)
{:ok, _} = Postgrex.start_link(database)

for sql <- String.split(AudioFlow.CallStore.Postgres.schema_sql(), ";"),
    String.trim(sql) != "",
    do: Postgrex.query!(DurableCall.DB, sql, [])

{:ok, _} = Application.ensure_all_started(:audio_flow)
IO.puts("#{node()}: ready")

case System.argv() do
  ["--create", room] ->
    {:ok, call} = AudioFlow.Calls.start_call(room, DurableCall.Agent)
    IO.puts("#{node()}: call #{call.id} in room #{room}")

  _ ->
    :ok
end

# SIGTERM stops the VM gracefully: AudioFlow drains its calls first.
Process.sleep(:infinity)
