defmodule AudioFlow.PausableOutput do
  @moduledoc """
  Explicit opt-in extension to `AudioFlow.Output`; legacy outputs are unsupported.

  `pause/3` and `resume/3` return when the ordered command is accepted, not when
  audible playback changes. The endpoint MUST call `Output.control_ack/5` with
  the same turn/candidate/action only after real suspension or resumption, using
  cumulative rendered PCM nanoseconds. Scheduling is not a playback ack.

  Callbacks must be nonblocking command acceptance; endpoint acks are separate.
  Return unsupported without changing endpoint state. Other callback errors cancel.

  Preserve queued speech and its order across pause. Push must remain bounded
  and flush must discard/release all queues and pending commands. Session holds
  at most one worker emit during the candidate and keeps its original deadline.
  Drivers without actual pause support must return `{:error, :unsupported}`.
  """
  @callback pause(term(), AudioFlow.Output.key(), reference()) :: :ok | {:error, term()}
  @callback resume(term(), AudioFlow.Output.key(), reference()) :: :ok | {:error, term()}

  def supported?({module, _}) do
    Code.ensure_loaded?(module) and function_exported?(module, :pause, 3) and
      function_exported?(module, :resume, 3)
  end

  def supported?(_), do: false
end
