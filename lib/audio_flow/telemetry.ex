defmodule AudioFlow.Telemetry do
  @moduledoc """
  `:telemetry` events for sessions, turns, and inference stages.

  Durations are in native time units. Convert them with
  `System.convert_time_unit/3`. Every event has `:session` (the session PID)
  in its metadata.

  ## Session

    * `[:audio_flow, :session, :start]`, measurements `%{system_time,
      monotonic_time}`, metadata `%{session, owner, graph?}`.
    * `[:audio_flow, :session, :stop]`, measurements `%{duration,
      monotonic_time, turns}`, metadata `%{session, owner, graph?, reason}`.
      `turns` counts accepted turns.

  ## Turn

    * `[:audio_flow, :turn, :start]`, measurements `%{system_time,
      monotonic_time}`, metadata `%{session, turn, input}`. `input` is
      `:audio`, `:image`, or `:text`.
    * `[:audio_flow, :turn, :stop]`, measurements `%{duration,
      monotonic_time, events}`, metadata `%{session, turn, input, status,
      error, metrics}`. `status` is `:done`, `:cancelled`, or `:error`.
      `error` is the reason of an `:error` status, otherwise `nil`. `metrics`
      is the map from the terminal event, in microseconds.

  Both turn events are emitted by the session process, with the turn reference
  as `:telemetry_span_context`.

  ## Stage

  `[:audio_flow, :stage, :start | :stop | :exception]` is a `:telemetry.span/3`
  around each adapter call, in the turn task. Metadata is `%{session, turn,
  stage, adapter}`. `stage` is `:stt`, `:vision`, `:llm`, or `:tts`. In a graph
  session it is the node type, such as `"llm.chat_http"`, and `:node` is the
  node id.
  TTS runs once per text chunk, inside the LLM stage. An adapter error, an
  exception, or a downstream failure emits `:exception` with `:kind` and
  `:reason`. Cancellation and timeout kill the turn task, so its open stages
  emit neither `:stop` nor `:exception`; the turn `:stop` event reports them.
  A session that stops during a turn reports it with status `:error` and
  error `{:session_stop, reason}`.
  """

  @doc false
  def session_start(metadata) do
    :telemetry.execute(
      [:audio_flow, :session, :start],
      %{system_time: System.system_time(), monotonic_time: System.monotonic_time()},
      metadata
    )

    System.monotonic_time()
  end

  @doc false
  def session_stop(started, turns, metadata) do
    stop = System.monotonic_time()

    :telemetry.execute(
      [:audio_flow, :session, :stop],
      %{duration: stop - started, monotonic_time: stop, turns: turns},
      metadata
    )
  end

  @doc false
  def turn_start(metadata) do
    :telemetry.execute(
      [:audio_flow, :turn, :start],
      %{system_time: System.system_time(), monotonic_time: System.monotonic_time()},
      Map.put(metadata, :telemetry_span_context, metadata.turn)
    )

    System.monotonic_time()
  end

  @doc false
  def turn_stop(started, events, metadata) do
    stop = System.monotonic_time()

    :telemetry.execute(
      [:audio_flow, :turn, :stop],
      %{duration: stop - started, monotonic_time: stop, events: events},
      Map.put(metadata, :telemetry_span_context, metadata.turn)
    )
  end

  @doc false
  def stage(metadata, fun) do
    :telemetry.span([:audio_flow, :stage], metadata, fn -> {fun.(), metadata} end)
  end
end
