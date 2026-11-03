defmodule AudioFlow.Session do
  @moduledoc """
  One active turn per session. Busy sessions reject input instead of queueing it.

  Set `:speech_to_speech` to a mixed-event adapter tuple for committed PCM
  turns without STT/LLM/TTS stages. Only audio input is supported; history replay,
  graphs and conversation flows are rejected in this mode. Provider instructions
  remain adapter options. Each turn starts a fresh provider connection.
  `:max_output_bytes` (16,777,216) bounds cumulative event payload bytes per turn
  in every mode, in addition to the event count and deadline.

  Options: `:stt`, `:llm`, `:tts` adapter tuples; `:owner`; `:timeout_ms`
  (30,000); `:max_input_bytes` (960,000); `:max_events` (1,024); optional
  `:output` transport tuple `{module, target}` implementing `AudioFlow.Output`.
  An optional `:vision` adapter converts RGB images to description strings.
  `AudioFlow.Text` input goes directly to the LLM without an input stage.
  `:max_image_bytes` defaults to 6,291,456. Image-only sessions can omit `:stt`.
  Descriptions form one LLM prompt, then follow the same speech output path.
  Set `:history` to `true` or `[max_turns: 8, max_bytes: 16_384]` to retain
  successful user/assistant pairs. The LLM then receives a list of role/content
  message maps. History is disabled by default.

  In place of the adapters, `:graph` takes an `AudioFlow.Graph.Plan` from
  `AudioFlow.Graph.session_options/2`. The input goes to the graph input nodes
  of its kind, and each node output becomes a `{kind, value, node_id}` event.
  Audio from nodes without targets goes to the `:output` transport. Context limits count UTF-8 text
  bytes, not tokens. Failed turns do not change saved history. Cancelled turns
  retain only complete reply chunks covered by explicit playback acknowledgements.
  The session stops when its owner exits. Interrupted turns cannot deliver
  further output. Cancellation stops the caller task, but an inference engine
  may still finish a batch already submitted to shared hardware.
  """
  use GenServer, restart: :temporary
  alias AudioFlow.{Adapter, Audio, History, Image, Telemetry, Text}
  alias AudioFlow.Graph.Plan

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(options, :owner)
    graph = Keyword.get(options, :graph)

    speech = Keyword.get(options, :speech_to_speech)

    if speech != nil do
      unless match?({module, opts} when is_atom(module) and is_list(opts), speech),
        do: raise(ArgumentError, "speech_to_speech must be an adapter tuple")

      if graph != nil or
           Enum.any?([:stt, :llm, :tts, :vision, :conversation], &Keyword.has_key?(options, &1)),
         do: raise(ArgumentError, "speech_to_speech is exclusive with graph and stage adapters")

      if Keyword.get(options, :history, false) not in [false, nil],
        do: raise(ArgumentError, "speech_to_speech does not support history replay")
    end

    adapters =
      case {graph, speech} do
        {nil, {_, _}} ->
          %{speech_to_speech: speech}

        {%AudioFlow.Graph.Plan{}, nil} ->
          %{}

        {nil, nil} ->
          adapters = Map.new([:llm, :tts], &{&1, Keyword.fetch!(options, &1)})
          adapters = Map.merge(adapters, Map.new(Keyword.take(options, [:stt, :vision])))

          if not (Map.has_key?(adapters, :stt) or Map.has_key?(adapters, :vision)),
            do: raise(ArgumentError, "a session requires an :stt or :vision adapter")

          adapters

        _ ->
          raise ArgumentError, "graph must be an AudioFlow.Graph.Plan"
      end

    limits =
      Map.new(
        [
          timeout_ms: 30_000,
          max_input_bytes: 960_000,
          max_image_bytes: 6_291_456,
          max_events: 1_024,
          max_output_bytes: 16_777_216
        ],
        fn {key, default} ->
          value = Keyword.get(options, key, default)

          if not (is_integer(value) and value > 0),
            do: raise(ArgumentError, "#{key} must be positive")

          {key, value}
        end
      )

    telemetry = %{session: self(), owner: owner, graph?: graph != nil}

    {:ok,
     %{
       telemetry: telemetry,
       telemetry_started: Telemetry.session_start(telemetry),
       turns: 0,
       owner: owner,
       owner_ref: Process.monitor(owner),
       adapters: adapters,
       graph: graph,
       conversation: Keyword.get(options, :conversation),
       limits: limits,
       history: History.new(Keyword.get(options, :history, false)),
       output: Keyword.get(options, :output),
       output_turn: nil,
       playback_history: nil,
       active: nil
     }}
  end

  @impl true
  def handle_call({:submit, input}, _from, state) do
    {valid?, stage, kind, limit} = input_spec(input, state.limits)

    cond do
      not valid? ->
        {:reply, {:error, invalid_input(input)}, state}

      state.graph != nil and not Map.has_key?(state.graph.inputs, Plan.input_kind(input)) ->
        {:reply, {:error, {:unsupported_input, Plan.input_kind(input)}}, state}

      Map.has_key?(state.adapters, :speech_to_speech) and not is_struct(input, Audio) ->
        {:reply, {:error, {:unsupported_input, Plan.input_kind(input)}}, state}

      state.graph == nil and not Map.has_key?(state.adapters, :speech_to_speech) and
        stage != nil and not Map.has_key?(state.adapters, stage) ->
        {:reply, {:error, {:unsupported_input, stage}}, state}

      byte_size(input.data) > limit ->
        {:reply, {:error, :input_too_large}, state}

      state.active != nil ->
        {:reply, {:error, :busy}, state}

      true ->
        session = self()
        turn = make_ref()
        started = now()

        case AudioFlow.Output.call(state.output, :start_turn, [{session, turn}]) do
          :ok ->
            telemetry = %{session: session, turn: turn, input: Plan.input_kind(input)}
            telemetry_started = Telemetry.turn_start(telemetry)
            adapters = state.adapters
            graph = state.graph
            output = state.output

            task =
              Task.Supervisor.async_nolink(AudioFlow.Tasks, fn ->
                cond do
                  graph ->
                    graph_pipeline(session, turn, input, graph, output)

                  adapters[:speech_to_speech] ->
                    speech_pipeline(session, turn, input, adapters.speech_to_speech, output)

                  true ->
                    pipeline(session, turn, input, stage, kind, adapters, output)
                end
              end)

            timer = Process.send_after(self(), {:timeout, turn}, state.limits.timeout_ms)

            active = %{
              turn: turn,
              telemetry: telemetry,
              telemetry_started: telemetry_started,
              task: task,
              timer: timer,
              started: started,
              first: %{},
              events: 0,
              output_bytes: 0,
              input_bytes: 0,
              context: nil,
              playout: AudioFlow.Playout.new(),
              conversation: state.conversation
            }

            {:reply, {:ok, turn},
             %{
               state
               | active: active,
                 playback_history: nil,
                 output_turn: turn,
                 turns: state.turns + 1
             }}

          {:error, reason} ->
            {:reply, {:error, {:output, reason}}, state}
        end
    end
  end

  def handle_call(:clear_history, _from, %{active: nil} = state),
    do: {:reply, :ok, %{state | history: History.clear(state.history), playback_history: nil}}

  def handle_call(:clear_history, _from, state), do: {:reply, {:error, :busy}, state}

  def handle_call(:conversation_state, _from, state) do
    {:reply,
     if(state.conversation,
       do: {:ok, state.conversation.current},
       else: {:error, :no_conversation}
     ), state}
  end

  def handle_call({:conversation_event, event}, _from, state) do
    flow = if state.active, do: state.active.conversation, else: state.conversation

    case flow && AudioFlow.Graph.Conversation.transition(flow, event) do
      {:ok, next} ->
        state =
          if state.active,
            do: put_in(state.active.conversation, next),
            else: %{state | conversation: next, graph: AudioFlow.Graph.Conversation.plan(next)}

        {:reply, :ok, state}

      nil ->
        {:reply, {:error, :no_conversation}, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:conversation_event, turn, event}, from, %{active: %{turn: turn}} = state),
    do: handle_call({:conversation_event, event}, from, state)

  def handle_call({:conversation_event, _, _}, _from, state),
    do: {:reply, {:error, :stale_turn}, state}

  def handle_call({:context, turn, input}, _from, %{active: %{turn: turn} = active} = state) do
    if state.history == nil do
      {:reply, {:ok, input}, state}
    else
      case History.prompt(state.history, input) do
        {:ok, messages, context} ->
          {:reply, {:ok, messages}, %{state | active: %{active | context: context}}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call({:context, _, _}, _from, state), do: {:reply, {:error, :stale_turn}, state}

  def handle_call({:played, turn, ns}, _from, state) do
    active = state.active || state.playback_history

    if active && active.turn == turn do
      case AudioFlow.Playout.acknowledge(active.playout, ns) do
        {:ok, playout} ->
          field = if state.active, do: :active, else: :playback_history
          {:reply, :ok, Map.put(state, field, %{active | playout: playout})}

        error ->
          {:reply, error, state}
      end
    else
      {:reply, {:error, :stale_turn}, state}
    end
  end

  def handle_call({:speech_checkpoint, turn}, _from, %{active: %{turn: turn} = active} = state) do
    bytes = if active.context, do: active.context.reply_bytes, else: 0
    playout = AudioFlow.Playout.checkpoint(active.playout, bytes)
    {:reply, :ok, %{state | active: %{active | playout: playout}}}
  end

  def handle_call({:speech_checkpoint, _}, _from, state),
    do: {:reply, {:error, :stale_turn}, state}

  def handle_call(:cancel, _from, %{active: nil} = state) do
    state = retain_heard(state, state.playback_history)
    {:reply, flush_output(state), %{state | playback_history: nil}}
  end

  def handle_call(:cancel, _from, state) do
    kill(state.active)
    state = retain_heard(state, state.active)
    result = flush_output(state)

    event =
      case result do
        :ok -> {:cancelled, metrics(state.active)}
        {:error, reason} -> {:error, {:output_flush, reason}, metrics(state.active)}
      end

    finish_turn(state, event)
    {:reply, result, %{state | active: nil}}
  end

  def handle_call({:emit, turn, kind, value}, from, state),
    do: handle_call({:emit, turn, kind, value, nil, kind}, from, state)

  # `record` is the kind for history and context accounting; `:none` skips it.
  def handle_call(
        {:emit, turn, kind, value, node, record},
        _from,
        %{active: %{turn: turn} = active} = state
      ) do
    cond do
      not valid_output?(kind, value) ->
        {:reply, {:error, :invalid_output}, state}

      active.output_bytes + output_bytes(value) > state.limits.max_output_bytes ->
        {:reply, {:error, :output_limit}, state}

      active.events >= state.limits.max_events ->
        {:reply, {:error, :output_limit}, state}

      true ->
        case record_context(state, record, value) do
          {:ok, active} ->
            active =
              if kind == :audio,
                do: %{active | playout: AudioFlow.Playout.audio(active.playout, value)},
                else: active

            first = Map.put_new(active.first, kind, now() - active.started)
            notify(state, if(node, do: {kind, value, node}, else: {kind, value}))

            {:reply, :ok,
             %{
               state
               | active: %{
                   active
                   | first: first,
                     events: active.events + 1,
                     output_bytes: active.output_bytes + output_bytes(value)
                 }
             }}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:emit, _, _, _, _, _}, _from, state),
    do: {:reply, {:error, :stale_turn}, state}

  @impl true
  def handle_info({ref, result}, %{active: %{task: %{ref: ref}}} = state) do
    Process.demonitor(ref, [:flush])
    Process.cancel_timer(state.active.timer)

    result =
      case result do
        :ok ->
          case AudioFlow.Output.call(state.output, :finish, [{self(), state.active.turn}]) do
            :ok -> :ok
            {:error, reason} -> {:error, {:output, reason}}
          end

        error ->
          error
      end

    event =
      case result do
        :ok ->
          {:done, metrics(state.active)}

        {:error, reason} ->
          flush_output(state)
          {:error, reason, metrics(state.active)}
      end

    finish_turn(state, event)

    history =
      if result == :ok and state.active.context != nil,
        do: History.commit(state.active.context),
        else: state.history

    flow = if result == :ok, do: state.active.conversation, else: state.conversation
    graph = if flow, do: AudioFlow.Graph.Conversation.plan(flow), else: state.graph

    {:noreply,
     %{
       state
       | active: nil,
         history: history,
         playback_history: if(result == :ok, do: state.active),
         conversation: flow,
         graph: graph
     }}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _, reason}, %{active: %{task: %{ref: ref}}} = state) do
    Process.cancel_timer(state.active.timer)
    flush_output(state)
    finish_turn(state, {:error, {:task_exit, reason}, metrics(state.active)})
    {:noreply, %{state | active: nil}}
  end

  def handle_info({:timeout, turn}, %{active: %{turn: turn}} = state) do
    kill(state.active)
    flush_output(state)
    finish_turn(state, {:error, :timeout, metrics(state.active)})
    {:noreply, %{state | active: nil}}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    if state.active do
      kill(state.active)
      turn_stop(state.active, {:error, {:session_stop, reason}, metrics(state.active)})
    end

    flush_output(state)
    metadata = Map.put(state.telemetry, :reason, reason)
    Telemetry.session_stop(state.telemetry_started, state.turns, metadata)
  end

  defp speech_pipeline(session, turn, input, adapter, output) do
    {module, _} = adapter

    Telemetry.stage(
      %{session: session, turn: turn, stage: :speech_to_speech, adapter: module},
      fn ->
        Adapter.run(adapter, input, fn
          {kind, value} when kind in [:transcript, :text, :audio] ->
            case GenServer.call(session, {:emit, turn, kind, value}) do
              :ok -> :ok
              {:error, reason} -> throw(reason)
            end

            if kind == :audio do
              case AudioFlow.Output.call(output, :push, [{session, turn}, value]) do
                :ok -> :ok
                {:error, reason} -> throw({:output, reason})
              end
            end

            :ok

          _ ->
            throw(:invalid_output)
        end)
      end
    )
  rescue
    error -> {:error, {:exception, Exception.message(error)}}
  catch
    reason -> {:error, reason}
  end

  defp pipeline(session, turn, input, stage, kind, adapters, output) do
    run = fn stage, input, emit ->
      {module, _} = adapter = Map.fetch!(adapters, stage)
      metadata = %{session: session, turn: turn, stage: stage, adapter: module}
      Telemetry.stage(metadata, fn -> Adapter.run(adapter, input, emit) end)
    end

    emit = fn kind, value ->
      case GenServer.call(session, {:emit, turn, kind, value}) do
        :ok -> :ok
        {:error, reason} -> throw(reason)
      end
    end

    # Input chunks describe one utterance or image. Generate only once.
    key = make_ref()
    Process.put(key, [])

    try do
      if stage != nil do
        run.(stage, input, fn text ->
          emit.(kind, text)
          Process.put(key, [text | Process.get(key)])
          :ok
        end)
      else
        Process.put(key, [input.data])
      end

      transcript = Process.get(key) |> Enum.reverse() |> Enum.join("") |> String.trim()
      transcript = input_context(input, transcript)

      if transcript != "" do
        prompt =
          case GenServer.call(session, {:context, turn, transcript}) do
            {:ok, prompt} -> prompt
            {:error, reason} -> throw(reason)
          end

        run.(:llm, prompt, fn text ->
          emit.(:text, text)

          if String.trim(text) != "" do
            run.(:tts, text, fn audio ->
              emit.(:audio, audio)

              case AudioFlow.Output.call(output, :push, [{session, turn}, audio]) do
                :ok -> :ok
                {:error, reason} -> throw({:output, reason})
              end
            end)

            case GenServer.call(session, {:speech_checkpoint, turn}) do
              :ok -> :ok
              {:error, reason} -> throw(reason)
            end
          end

          :ok
        end)
      end

      :ok
    rescue
      error -> {:error, {:exception, Exception.message(error)}}
    catch
      reason -> {:error, reason}
    after
      Process.delete(key)
    end
  end

  defp graph_pipeline(session, turn, input, plan, output) do
    call = fn message ->
      case GenServer.call(session, message) do
        :ok -> :ok
        {:ok, value} -> value
        {:error, reason} -> throw(reason)
      end
    end

    callbacks = %{
      emit: fn step, value ->
        call.({:emit, turn, step.event, value, step.id, if(step.history, do: :text, else: :none)})

        if step.event == :audio and step.targets == [] do
          case AudioFlow.Output.call(output, :push, [{session, turn}, value]) do
            :ok -> :ok
            {:error, reason} -> throw({:output, reason})
          end
        end

        :ok
      end,
      context: fn text -> call.({:context, turn, text}) end,
      checkpoint: fn -> call.({:speech_checkpoint, turn}) end,
      telemetry: %{session: session, turn: turn}
    }

    AudioFlow.Graph.Runner.run(plan, input, callbacks)
  rescue
    error -> {:error, {:exception, Exception.message(error)}}
  catch
    reason -> {:error, reason}
  end

  defp input_context(_, ""), do: ""

  defp input_context(%Image{pts: pts}, text) when is_integer(pts),
    do: "At video time #{div(pts, 1_000_000)} ms: #{text}"

  defp input_context(_, text), do: text

  defp record_context(%{history: nil, active: active}, _, _), do: {:ok, active}

  defp record_context(state, kind, text) when kind in [:transcript, :description] do
    bytes = state.active.input_bytes + byte_size(text)

    if bytes > state.history.max_bytes,
      do: {:error, :context_limit},
      else: {:ok, %{state.active | input_bytes: bytes}}
  end

  defp record_context(state, :text, text) do
    case History.append(state.active.context, text) do
      {:ok, context} -> {:ok, %{state.active | context: context}}
      error -> error
    end
  end

  defp record_context(%{active: active}, _, _), do: {:ok, active}

  defp retain_heard(state, nil), do: state
  defp retain_heard(state, %{context: nil}), do: state

  defp retain_heard(state, active) do
    bytes = AudioFlow.Playout.heard_bytes(active.playout)
    %{state | history: History.commit_heard(active.context, bytes)}
  end

  defp flush_output(%{output_turn: nil}), do: :ok

  defp flush_output(state),
    do: AudioFlow.Output.call(state.output, :flush, [{self(), state.output_turn}])

  defp output_bytes(%{data: data}) when is_binary(data), do: byte_size(data)
  defp output_bytes(text) when is_binary(text), do: byte_size(text)
  defp output_bytes(vector) when is_list(vector), do: length(vector) * 8

  defp valid_output?(:audio, audio), do: Audio.valid?(audio)

  defp valid_output?(kind, text) when kind in [:text, :transcript, :description],
    do: is_binary(text)

  defp valid_output?(:image, image), do: Image.valid?(image)
  defp valid_output?(:vector, vector), do: is_list(vector) and Enum.all?(vector, &is_number/1)

  defp input_spec(%Audio{} = audio, limits),
    do: {Audio.valid?(audio), :stt, :transcript, limits.max_input_bytes}

  defp input_spec(%Image{} = image, limits),
    do: {Image.valid?(image), :vision, :description, limits.max_image_bytes}

  defp input_spec(%Text{} = text, limits),
    do: {Text.valid?(text), nil, nil, limits.max_input_bytes}

  defp input_spec(_, _), do: {false, nil, nil, 0}
  defp invalid_input(%Image{}), do: :invalid_image
  defp invalid_input(%Text{}), do: :invalid_text
  defp invalid_input(_), do: :invalid_audio
  defp now, do: System.monotonic_time(:microsecond)
  defp notify(state, event), do: send(state.owner, {AudioFlow, self(), state.active.turn, event})

  defp finish_turn(state, event) do
    notify(state, event)
    turn_stop(state.active, event)
  end

  defp turn_stop(active, event) do
    {status, error, metrics} =
      case event do
        {:error, reason, metrics} -> {:error, reason, metrics}
        {status, metrics} -> {status, nil, metrics}
      end

    metadata = Map.merge(active.telemetry, %{status: status, error: error, metrics: metrics})
    Telemetry.turn_stop(active.telemetry_started, active.events, metadata)
  end

  defp kill(active) do
    Process.cancel_timer(active.timer)
    Process.exit(active.task.pid, :kill)
    Process.demonitor(active.task.ref, [:flush])
    :ok
  end

  defp metrics(active) do
    %{
      duration_us: now() - active.started,
      first_transcript_us: active.first[:transcript],
      first_description_us: active.first[:description],
      first_text_us: active.first[:text],
      first_audio_us: active.first[:audio],
      events: active.events
    }
  end
end
