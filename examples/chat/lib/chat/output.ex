defmodule Chat.Output do
  @moduledoc "Browser Web Audio endpoint; bounded by Session's per-turn event/byte limits."
  @behaviour AudioFlow.Output
  @behaviour AudioFlow.PausableOutput
  def token(ref), do: Base.encode64(:erlang.term_to_binary(ref))
  def start_turn(owner, {_, turn}), do: deliver(owner, {:start, turn, token(turn)})
  def push(owner, {_, turn}, audio), do: deliver(owner, {:pcm, turn, token(turn), audio})
  def finish(_, _), do: :ok
  def flush(owner, {_, turn}), do: deliver(owner, {:flush, turn})
  def pause(owner, {_, turn}, id), do: deliver(owner, {:control, turn, id, :pause})
  def resume(owner, {_, turn}, id), do: deliver(owner, {:control, turn, id, :resume})

  defp deliver(owner, event) do
    send(owner, {__MODULE__, event})
    :ok
  end
end
