{:ok, session} = AudioFlow.start_session(AudioFlow.Adapters.Demo.options())
{:ok, turn} = AudioFlow.submit(session, %AudioFlow.Audio{data: <<0, 0>>, sample_rate: 16_000})

defmodule Demo do
  def receive_turn(session, turn) do
    receive do
      {AudioFlow, ^session, ^turn, {:done, metrics}} ->
        IO.inspect(metrics, label: "Synthetic turn complete")

      {AudioFlow, ^session, ^turn, {:error, reason, _}} ->
        raise inspect(reason)

      {AudioFlow, ^session, ^turn, event} ->
        IO.inspect(event, limit: 5)
        receive_turn(session, turn)
    after
      5_000 -> raise "turn timeout"
    end
  end
end

Demo.receive_turn(session, turn)
AudioFlow.stop_session(session)
