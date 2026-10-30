# Run with mix run examples/routing.exs. Uses synthetic text and silent PCM.
# Real workers can use NxAdapter with existing shared model services.
alias AudioFlow.{Audio, Router, Worker}

children = [
  {Worker,
   name: AudioFlow.ExampleLLM, adapter: {AudioFlow.Adapters.Demo, stage: :llm}, max_concurrency: 2},
  {Router, name: AudioFlow.ExampleRoutes, routes: %{voice: [AudioFlow.ExampleLLM]}}
]

{:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one)

options =
  Keyword.put(
    AudioFlow.Adapters.Demo.options(),
    :llm,
    {Router, router: AudioFlow.ExampleRoutes, route: :voice}
  )

{:ok, session} = AudioFlow.start_session(options)
{:ok, turn} = AudioFlow.submit(session, %Audio{data: <<0, 0>>, sample_rate: 16_000})

receive_events = fn receive_events ->
  receive do
    {AudioFlow, ^session, ^turn, event} ->
      case event do
        {:done, metrics} ->
          IO.inspect(metrics, label: "Complete")

        {:error, reason, _} ->
          raise "Turn failed: #{inspect(reason)}"

        {:cancelled, _} ->
          raise "Turn cancelled"

        {:audio, audio} ->
          IO.puts("PCM bytes: #{byte_size(audio.data)}")
          receive_events.(receive_events)

        other ->
          IO.inspect(other)
          receive_events.(receive_events)
      end
  after
    5_000 -> raise "Turn deadline exceeded"
  end
end

try do
  receive_events.(receive_events)
after
  AudioFlow.stop_session(session)
  Supervisor.stop(supervisor)
end
