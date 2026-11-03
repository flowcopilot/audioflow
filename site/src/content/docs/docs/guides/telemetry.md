---
title: Telemetry
description: Session, turn, and stage spans as :telemetry events, with an OpenTelemetry bridge.
sidebar:
  order: 11
---

AudioFlow emits `:telemetry` events for each session, turn, and inference
stage. `AudioFlow.Telemetry` lists every event with its measurements and
metadata. Durations are in native time units.

| Event | Emitted by | Metadata |
| --- | --- | --- |
| `[:audio_flow, :session, :start \| :stop]` | session process | `session`, `owner`, `graph?`; `reason` on stop |
| `[:audio_flow, :turn, :start \| :stop]` | session process | `session`, `turn`, `input`; `status`, `error`, `metrics` on stop |
| `[:audio_flow, :stage, :start \| :stop \| :exception]` | turn task | `session`, `turn`, `stage`, `adapter`; `node` in graphs |

A turn stops with status `:done`, `:cancelled`, or `:error`. The `metrics` map
is the same as in the terminal event, so time to first text and first audio are
available to handlers. Each stage span wraps one adapter call: `:stt`,
`:vision`, `:llm`, or `:tts`, or the node type in a graph session. TTS runs once
per text chunk, inside the LLM span.

Cancellation and timeout kill the turn task, so open stage spans in that task
emit no stop event. The turn stop event reports the outcome.

## Log turn latency

```elixir
:telemetry.attach(
  "log-turns",
  [:audio_flow, :turn, :stop],
  fn _event, %{duration: duration}, meta, _ ->
    ms = System.convert_time_unit(duration, :native, :millisecond)
    Logger.info("turn #{meta.status} in #{ms} ms, first audio #{meta.metrics.first_audio_us} us")
  end,
  nil
)
```

## OpenTelemetry

Turn and stage events carry `:telemetry_span_context`, so
[`opentelemetry_telemetry`](https://hex.pm/packages/opentelemetry_telemetry)
can turn them into spans. Stage spans run in the turn task, a different process
from the turn span.
[`opentelemetry_process_propagator`](https://hex.pm/packages/opentelemetry_process_propagator)
finds the turn span through the task `$callers`, so stages nest under their
turn in one trace. Add `opentelemetry`, `opentelemetry_api`, an exporter,
`opentelemetry_telemetry`, and `opentelemetry_process_propagator` to your
application, then call `MyApp.AudioFlowTracing.setup/0` at startup:

```elixir
defmodule MyApp.AudioFlowTracing do
  @tracer_id __MODULE__
  @events for kind <- [:turn, :stage], phase <- [:start, :stop, :exception],
              not (kind == :turn and phase == :exception),
              do: [:audio_flow, kind, phase]

  def setup, do: :telemetry.attach_many(__MODULE__, @events, &__MODULE__.handle/4, nil)

  def handle([:audio_flow, :turn, :start], _measurements, meta, _) do
    OpentelemetryTelemetry.start_telemetry_span(@tracer_id, "audio_flow.turn", meta, %{
      attributes: %{"audio_flow.input" => to_string(meta.input)}
    })
  end

  def handle([:audio_flow, :stage, :start], _measurements, meta, _) do
    # Stages run in the turn task. Make the session's turn span their parent.
    if OpenTelemetry.Tracer.current_span_ctx() == :undefined do
      case OpentelemetryProcessPropagator.fetch_parent_ctx(1, :"$callers") do
        :undefined -> :ok
        parent -> OpenTelemetry.Ctx.attach(parent)
      end
    end

    OpentelemetryTelemetry.start_telemetry_span(@tracer_id, "audio_flow.#{meta.stage}", meta, %{
      attributes: %{"audio_flow.adapter" => inspect(meta.adapter)}
    })
  end

  def handle([:audio_flow, _kind, phase], _measurements, meta, _) do
    OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, meta)

    cond do
      phase == :exception -> OpenTelemetry.Tracer.set_status(:error, inspect(meta.reason))
      meta[:status] == :error -> OpenTelemetry.Tracer.set_status(:error, inspect(meta.error))
      true -> :ok
    end

    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, meta)
  end
end
```

A turn produces a `audio_flow.turn` span with `audio_flow.stt` and
`audio_flow.llm` children. Each `audio_flow.tts` span is a child of
`audio_flow.llm`. Stage spans left open by a cancelled turn are not exported.
