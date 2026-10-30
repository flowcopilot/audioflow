defmodule AudioFlow do
  @moduledoc """
  Supervised voice sessions with interchangeable inference engines.

  Each session sends `{AudioFlow, session_pid, turn_ref, event}` to its owner.
  Events are `{:transcript, text}`, `{:text, text}`, `{:audio, audio}`,
  `{:done, metrics}`, `{:cancelled, metrics}`, or `{:error, reason, metrics}`.
  """

  def start_session(options) do
    options = Keyword.put_new(options, :owner, self())
    DynamicSupervisor.start_child(AudioFlow.Sessions, {AudioFlow.Session, options})
  end

  def submit(session, %AudioFlow.Audio{} = audio), do: GenServer.call(session, {:submit, audio})
  def cancel(session), do: GenServer.call(session, :cancel)
  def stop_session(session), do: DynamicSupervisor.terminate_child(AudioFlow.Sessions, session)
end
