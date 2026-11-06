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
  Omit both `:llm` and `:tts` for a transcription session. Its turns end after
  the input stage, and text input returns `{:error, {:unsupported_input, :llm}}`.
  An STT adapter can emit strings, `AudioFlow.Transcript.Segment` values, or
  `{:partial, text}`. These become `{:transcript, text}`, `{:segment, segment}`
  and `{:partial_transcript, text}` events. Partial text is an unstable hypothesis
  that follows the final text emitted so far. It is not part of the prompt or the
  history.
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
  alias AudioFlow.Adapter
  alias AudioFlow.Audio
  alias AudioFlow.Graph.Conversation
  alias AudioFlow.Graph.Plan
  alias AudioFlow.Graph.Runner
  alias AudioFlow.History
  alias AudioFlow.Image
  alias AudioFlow.Telemetry
  alias AudioFlow.Text
  alias AudioFlow.Transcript.Segment

  @limits_schema [
    timeout_ms: [type: :pos_integer, default: 30_000],
    max_input_bytes: [type: :pos_integer, default: 960_000],
    max_image_bytes: [type: :pos_integer, default: 6_291_456],
    max_events: [type: :pos_integer, default: 1024],
    max_output_bytes: [type: :pos_integer, default: 16_777_216]
  ]

  @doc "Session resource limits:\n\n" <> NimbleOptions.docs(@limits_schema)
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(options, :owner)
    graph = Keyword.get(options, :graph)

    speech = Keyword.get(options, :speech_to_speech)
    if speech != nil, do: validate_speech!(speech, graph, options)
    adapters = init_adapters(graph, speech, options)
    limits = init_limits(options)

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
       candidate: nil,
       held: nil,
       pending_result: nil,
       active: nil
     }}
  end

  defp validate_speech!(speech, graph, options) do
    unless match?({module, opts} when is_atom(module) and is_list(opts), speech),
      do: raise(ArgumentError, "speech_to_speech must be an adapter tuple")

    if graph != nil or
         Enum.any?([:stt, :llm, :tts, :vision, :conversation], &Keyword.has_key?(options, &1)),
       do: raise(ArgumentError, "speech_to_speech is exclusive with graph and stage adapters")

    if Keyword.get(options, :history, false) not in [false, nil],
      do: raise(ArgumentError, "speech_to_speech does not support history replay")
  end

  defp init_adapters(nil, {_, _} = speech, _options), do: %{speech_to_speech: speech}
  defp init_adapters(%AudioFlow.Graph.Plan{}, nil, _options), do: %{}

  defp init_adapters(nil, nil, options) do
    adapters = Map.new(Keyword.take(options, [:stt, :vision, :llm, :tts]))

    if not (Map.has_key?(adapters, :stt) or Map.has_key?(adapters, :vision)),
      do: raise(ArgumentError, "a session requires an :stt or :vision adapter")

    if Map.has_key?(adapters, :llm) != Map.has_key?(adapters, :tts),
      do: raise(ArgumentError, "a session requires both :llm and :tts, or neither")

    if not Map.has_key?(adapters, :llm) and
         Keyword.get(options, :history, false) not in [false, nil],
       do: raise(ArgumentError, "a transcription session does not support history")

    adapters
  end

  defp init_adapters(_graph, _speech, _options),
    do: raise(ArgumentError, "graph must be an AudioFlow.Graph.Plan")

  defp init_limits(options) do
    options
    |> AudioFlow.RuntimeOptions.known!(
      @limits_schema,
      Enum.map(@limits_schema, fn {key, _} -> {key, "#{key} must be positive"} end)
    )
    |> Map.new()
  end

  @impl true
  def handle_call({:submit, input}, _from, state) do
    {valid?, stage, kind, limit} = input_spec(input, state.limits)
    reason = if valid?, do: submit_error(input, stage, limit, state), else: invalid_input(input)

    if reason == nil,
      do: start_turn(input, stage, kind, state),
      else: {:reply, {:error, reason}, state}
  end

  def handle_call({:provisional, ms}, _from, state) do
    case provisional_error(ms, state) do
      nil -> pause_for_candidate(ms, state)
      reason -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:resolve, id, :confirm}, from, %{candidate: %{id: id}} = state),
    do: handle_call(:cancel, from, state)

  def handle_call(
        {:resolve, id, :resume},
        _from,
        %{candidate: %{id: id, phase: :paused} = candidate} = state
      ) do
    if now() >= candidate.deadline do
      {:reply, _, state} = handle_call(:cancel, nil, state)
      {:reply, {:error, :candidate_timeout}, state}
    else
      case AudioFlow.Output.call(state.output, :resume, [
             {self(), (state.active || state.playback_history).turn},
             id
           ]) do
        :ok ->
          {:reply, :ok, %{state | candidate: %{candidate | phase: :resuming}}}

        error ->
          {_, _, state} = handle_call(:cancel, nil, state)
          {:reply, error, state}
      end
    end
  end

  def handle_call({:resolve, _, _}, _from, state),
    do: {:reply, {:error, :stale_candidate}, state}

  def handle_call(
        {:control_ack, turn, id, action, ns},
        _from,
        %{candidate: %{id: id} = candidate} = state
      ) do
    active = state.active || state.playback_history

    cond do
      now() >= candidate.deadline ->
        {:reply, _, state} = handle_call(:cancel, nil, state)
        {:reply, {:error, :candidate_timeout}, state}

      expected_control?(active, turn, action, candidate) ->
        acknowledge_control(state, active, candidate, action, ns)

      true ->
        {:reply, {:error, :stale_control}, state}
    end
  end

  def handle_call({:control_ack, _, _, _, _}, _from, state),
    do: {:reply, {:error, :stale_control}, state}

  def handle_call(:clear_history, _from, %{active: nil, candidate: nil} = state),
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

    case flow && Conversation.transition(flow, event) do
      {:ok, next} ->
        state =
          if state.active,
            do: put_in(state.active.conversation, next),
            else: %{state | conversation: next, graph: Conversation.plan(next)}

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
      case acknowledge_playout(state, active, ns) do
        {:ok, state} -> {:reply, :ok, state}
        error -> {:reply, error, state}
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
    state = clear_candidate(state)
    state = retain_heard(state, state.playback_history)
    {:reply, flush_output(state), %{state | playback_history: nil}}
  end

  def handle_call(:cancel, _from, state) do
    state = clear_candidate(state)
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

  def handle_call(
        {:emit, turn, kind, value, _, _} = message,
        from,
        %{active: %{turn: turn}, candidate: candidate} = state
      )
      when candidate != nil do
    cond do
      not valid_output?(kind, value) ->
        {:reply, {:error, :invalid_output}, state}

      state.held != nil or state.active.events >= state.limits.max_events or
          state.active.output_bytes + output_bytes(value) > state.limits.max_output_bytes ->
        {:reply, {:error, :output_limit}, state}

      true ->
        {:noreply, %{state | held: {message, from}}}
    end
  end

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
          {:ok, active} -> {:reply, :ok, accept_output(state, active, kind, value, node)}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:emit, _, _, _, _, _}, _from, state),
    do: {:reply, {:error, :stale_turn}, state}

  @impl true
  def handle_info({:release_emit, {message, from}}, state) do
    case handle_call(message, from, state) do
      {:reply, reply, next} ->
        GenServer.reply(from, reply)
        {:noreply, next}

      {:noreply, next} ->
        {:noreply, next}
    end
  end

  def handle_info({:candidate_timeout, id}, %{candidate: %{id: id}} = state) do
    {:reply, _, state} = handle_call(:cancel, nil, state)
    {:noreply, state}
  end

  def handle_info(
        {ref, :ok} = result,
        %{active: %{task: %{ref: ref}}, candidate: candidate} = state
      )
      when candidate != nil do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | pending_result: result}}
  end

  def handle_info({ref, result}, %{active: %{task: %{ref: ref}}} = state) do
    state = clear_candidate(state)
    Process.demonitor(ref, [:flush])
    Process.cancel_timer(state.active.timer)

    result = finish_output(state, result)
    finish_turn(state, turn_event(state, result))
    {:noreply, after_turn(state, result)}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _, reason}, %{active: %{task: %{ref: ref}}} = state) do
    state = clear_candidate(state)
    Process.cancel_timer(state.active.timer)
    flush_output(state)
    finish_turn(state, {:error, {:task_exit, reason}, metrics(state.active)})
    {:noreply, %{state | active: nil}}
  end

  def handle_info({:timeout, turn}, %{active: %{turn: turn}} = state) do
    state = clear_candidate(state)
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

  defp submit_error(input, stage, limit, state) do
    cond do
      unsupported_kind?(input, state) -> {:unsupported_input, Plan.input_kind(input)}
      missing_stage?(stage || :llm, state) -> {:unsupported_input, stage || :llm}
      byte_size(input.data) > limit -> :input_too_large
      state.active != nil or state.candidate != nil -> :busy
      true -> nil
    end
  end

  defp unsupported_kind?(input, %{graph: nil} = state),
    do: Map.has_key?(state.adapters, :speech_to_speech) and not is_struct(input, Audio)

  defp unsupported_kind?(input, state),
    do: not Map.has_key?(state.graph.inputs, Plan.input_kind(input))

  defp missing_stage?(_stage, %{graph: graph}) when graph != nil, do: false

  defp missing_stage?(stage, state),
    do:
      not Map.has_key?(state.adapters, :speech_to_speech) and
        not Map.has_key?(state.adapters, stage)

  defp start_turn(input, stage, kind, state) do
    session = self()
    turn = make_ref()
    started = now()

    case AudioFlow.Output.call(state.output, :start_turn, [{session, turn}]) do
      :ok ->
        telemetry = %{session: session, turn: turn, input: Plan.input_kind(input)}
        telemetry_started = Telemetry.turn_start(telemetry)
        %{adapters: adapters, graph: graph, output: output} = state

        task =
          Task.Supervisor.async_nolink(AudioFlow.Tasks, fn ->
            run_turn(session, turn, input, stage, kind, adapters, graph, output)
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

  defp run_turn(session, turn, input, stage, kind, adapters, graph, output) do
    cond do
      graph ->
        graph_pipeline(session, turn, input, graph, output)

      adapters[:speech_to_speech] ->
        speech_pipeline(session, turn, input, adapters.speech_to_speech, output)

      true ->
        pipeline(session, turn, input, stage, kind, adapters, output)
    end
  end

  defp provisional_error(ms, state) do
    cond do
      not (is_integer(ms) and ms > 0 and ms <= 30_000) -> :invalid_deadline
      state.candidate != nil -> :busy
      state.active == nil and state.playback_history == nil -> :no_active_turn
      not AudioFlow.PausableOutput.supported?(state.output) -> :unsupported
      true -> nil
    end
  end

  defp pause_for_candidate(ms, state) do
    id = make_ref()

    case AudioFlow.Output.call(state.output, :pause, [
           {self(), (state.active || state.playback_history).turn},
           id
         ]) do
      :ok ->
        timer = Process.send_after(self(), {:candidate_timeout, id}, ms)

        {:reply, {:ok, id},
         %{
           state
           | candidate: %{id: id, phase: :pausing, timer: timer, deadline: now() + ms * 1_000}
         }}

      {:error, :unsupported} = error ->
        {:reply, error, state}

      error ->
        {:reply, _, state} = handle_call(:cancel, nil, state)
        {:reply, error, state}
    end
  end

  defp expected_control?(nil, _turn, _action, _candidate), do: false

  defp expected_control?(active, turn, action, candidate) do
    expected = if candidate.phase == :pausing, do: :pause, else: :resume
    active.turn == turn and action == expected and candidate.phase in [:pausing, :resuming]
  end

  defp acknowledge_control(state, active, candidate, action, ns) do
    case acknowledge_playout(state, active, ns) do
      {:ok, state} -> {:reply, :ok, apply_control(state, candidate, action)}
      error -> {:reply, error, state}
    end
  end

  # Updates the playout of the active turn, or of the last finished one.
  defp acknowledge_playout(state, active, ns) do
    with {:ok, playout} <- AudioFlow.Playout.acknowledge(active.playout, ns) do
      field = if state.active, do: :active, else: :playback_history
      {:ok, Map.put(state, field, %{active | playout: playout})}
    end
  end

  defp apply_control(state, candidate, :pause),
    do: %{state | candidate: %{candidate | phase: :paused}}

  defp apply_control(state, candidate, _resume) do
    Process.cancel_timer(candidate.timer)
    if state.held, do: send(self(), {:release_emit, state.held})
    if state.pending_result, do: send(self(), state.pending_result)
    %{state | candidate: nil, held: nil, pending_result: nil}
  end

  defp accept_output(state, active, kind, value, node) do
    active =
      if kind == :audio,
        do: %{active | playout: AudioFlow.Playout.audio(active.playout, value)},
        else: active

    first = Map.put_new(active.first, first_kind(kind), now() - active.started)
    notify(state, if(node, do: {kind, value, node}, else: {kind, value}))

    %{
      state
      | active: %{
          active
          | first: first,
            events: active.events + 1,
            output_bytes: active.output_bytes + output_bytes(value)
        }
    }
  end

  defp first_kind(:segment), do: :transcript
  defp first_kind(kind), do: kind

  defp finish_output(state, :ok) do
    case AudioFlow.Output.call(state.output, :finish, [{self(), state.active.turn}]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:output, reason}}
    end
  end

  defp finish_output(_state, error), do: error

  defp turn_event(state, :ok), do: {:done, metrics(state.active)}

  defp turn_event(state, {:error, reason}) do
    flush_output(state)
    {:error, reason, metrics(state.active)}
  end

  defp after_turn(state, result) do
    history =
      if result == :ok and state.active.context != nil,
        do: History.commit(state.active.context),
        else: state.history

    flow = if result == :ok, do: state.active.conversation, else: state.conversation
    graph = if flow, do: Conversation.plan(flow), else: state.graph

    %{
      state
      | active: nil,
        history: history,
        playback_history: if(result == :ok, do: state.active),
        conversation: flow,
        graph: graph
    }
  end

  defp speech_pipeline(session, turn, input, adapter, output) do
    {module, _} = adapter

    Telemetry.stage(
      %{session: session, turn: turn, stage: :speech_to_speech, adapter: module},
      fn -> Adapter.run(adapter, input, &speech_event(&1, session, turn, output)) end
    )
  rescue
    error -> {:error, {:exception, Exception.message(error)}}
  catch
    reason -> {:error, reason}
  end

  defp speech_event({kind, value}, session, turn, output)
       when kind in [:transcript, :text, :audio] do
    call!(session, {:emit, turn, kind, value}, :infinity)
    if kind == :audio, do: push!(output, session, turn, value)
    :ok
  end

  defp speech_event(_event, _session, _turn, _output), do: throw(:invalid_output)

  defp pipeline(session, turn, input, stage, kind, adapters, output) do
    run = fn stage, input, emit ->
      {module, _} = adapter = Map.fetch!(adapters, stage)
      metadata = %{session: session, turn: turn, stage: stage, adapter: module}
      Telemetry.stage(metadata, fn -> Adapter.run(adapter, input, emit) end)
    end

    emit = fn kind, value -> call!(session, {:emit, turn, kind, value}, :infinity) end

    # Input chunks describe one utterance or image. Generate only once.
    key = make_ref()
    Process.put(key, [])

    try do
      transcript = input_transcript(run, emit, key, input, stage, kind)

      if transcript != "" and Map.has_key?(adapters, :llm),
        do: respond(run, emit, {session, turn, output}, transcript)

      :ok
    rescue
      error -> {:error, {:exception, Exception.message(error)}}
    catch
      reason -> {:error, reason}
    after
      Process.delete(key)
    end
  end

  defp input_transcript(run, emit, key, input, stage, kind) do
    if stage != nil do
      run.(stage, input, &input_output(&1, emit, key, stage, kind))
    else
      Process.put(key, [input.data])
    end

    transcript = Process.get(key) |> Enum.reverse() |> join_input() |> String.trim()
    input_context(input, transcript)
  end

  defp input_output(text, emit, key, _stage, kind) when is_binary(text) do
    emit.(kind, text)
    Process.put(key, [text | Process.get(key)])
    :ok
  end

  defp input_output(%Segment{} = segment, emit, key, :stt, _kind) do
    emit.(:segment, segment)
    Process.put(key, [segment | Process.get(key)])
    :ok
  end

  defp input_output({:partial, text}, emit, _key, :stt, _kind) when is_binary(text),
    do: emit.(:partial_transcript, text)

  defp input_output(_, _emit, _key, _stage, _kind), do: throw(:invalid_output)

  # Strings keep their own spacing. Segment text is joined with one space.
  defp join_input(parts) do
    parts
    |> Enum.reduce({[], nil}, fn
      %Segment{text: text}, {acc, previous} ->
        text = String.trim(text)

        cond do
          text == "" -> {acc, previous}
          previous in [nil, :space] -> {[text | acc], :segment}
          true -> {[text, " " | acc], :segment}
        end

      text, {acc, _} ->
        {[text | acc], if(String.ends_with?(text, [" ", "\n", "\t"]), do: :space, else: :text)}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp respond(run, emit, {session, turn, _output} = target, transcript) do
    prompt = fetch!(session, {:context, turn, transcript})

    run.(:llm, prompt, fn text ->
      emit.(:text, text)
      if String.trim(text) != "", do: speak(run, emit, target, text)
      :ok
    end)
  end

  defp speak(run, emit, {session, turn, output}, text) do
    run.(:tts, text, fn audio ->
      emit.(:audio, audio)
      push!(output, session, turn, audio)
    end)

    call!(session, {:speech_checkpoint, turn})
  end

  # Turn tasks stop on the first refused call; the pipeline catches the reason.
  defp call!(session, request, timeout \\ 5000) do
    case GenServer.call(session, request, timeout) do
      :ok -> :ok
      {:error, reason} -> throw(reason)
    end
  end

  defp fetch!(session, request) do
    case GenServer.call(session, request) do
      {:ok, value} -> value
      {:error, reason} -> throw(reason)
    end
  end

  defp push!(output, session, turn, value) do
    case AudioFlow.Output.call(output, :push, [{session, turn}, value]) do
      :ok -> :ok
      {:error, reason} -> throw({:output, reason})
    end
  end

  defp graph_pipeline(session, turn, input, plan, output) do
    call = fn message ->
      case GenServer.call(session, message, :infinity) do
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

    Runner.run(plan, input, callbacks)
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

  defp record_context(state, :segment, %Segment{text: text}),
    do: record_context(state, :transcript, text)

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

  defp clear_candidate(state) do
    if state.candidate, do: Process.cancel_timer(state.candidate.timer)
    if state.held, do: GenServer.reply(elem(state.held, 1), {:error, :stale_turn})
    %{state | candidate: nil, held: nil, pending_result: nil}
  end

  defp retain_heard(state, nil), do: state
  defp retain_heard(state, %{context: nil}), do: state

  defp retain_heard(state, active) do
    bytes = AudioFlow.Playout.heard_bytes(active.playout)
    %{state | history: History.commit_heard(active.context, bytes)}
  end

  defp flush_output(%{output_turn: nil}), do: :ok

  defp flush_output(state),
    do: AudioFlow.Output.call(state.output, :flush, [{self(), state.output_turn}])

  defp output_bytes(%Segment{} = segment), do: Segment.bytes(segment)
  defp output_bytes(%{data: data}) when is_binary(data), do: byte_size(data)
  defp output_bytes(text) when is_binary(text), do: byte_size(text)
  defp output_bytes(vector) when is_list(vector), do: length(vector) * 8

  defp valid_output?(:audio, audio), do: Audio.valid?(audio)

  defp valid_output?(:segment, segment), do: Segment.valid?(segment)

  defp valid_output?(kind, text)
       when kind in [:text, :transcript, :partial_transcript, :description],
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
      first_partial_transcript_us: active.first[:partial_transcript],
      first_transcript_us: active.first[:transcript],
      first_description_us: active.first[:description],
      first_text_us: active.first[:text],
      first_audio_us: active.first[:audio],
      events: active.events
    }
  end
end
