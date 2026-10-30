defmodule AudioFlow do
  @moduledoc """
  Supervised voice, image, and text sessions with interchangeable inference engines.

  Each session sends `{AudioFlow, session_pid, turn_ref, event}` to its owner.
  Events are `{:transcript, text}`, `{:description, text}`, `{:text, text}`, `{:audio, audio}`,
  `{:done, metrics}`, `{:cancelled, metrics}`, or `{:error, reason, metrics}`.
  A session that runs an `AudioFlow.Graph` sends node outputs as
  `{kind, value, node_id}`, where kind can also be `:image` or `:vector`.
  """

  def start_session(options) do
    options = Keyword.put_new(options, :owner, self())
    DynamicSupervisor.start_child(AudioFlow.Sessions, {AudioFlow.Session, options})
  end

  def submit(session, %AudioFlow.Audio{} = audio), do: GenServer.call(session, {:submit, audio})
  def submit(session, %AudioFlow.Image{} = image), do: GenServer.call(session, {:submit, image})
  def submit(session, %AudioFlow.Text{} = text), do: GenServer.call(session, {:submit, text})
  def cancel(session), do: GenServer.call(session, :cancel)
  @doc "Clear saved conversation text while idle. Returns `{:error, :busy}` during a turn."
  def clear_history(session), do: GenServer.call(session, :clear_history)
  def stop_session(session), do: DynamicSupervisor.terminate_child(AudioFlow.Sessions, session)
end
