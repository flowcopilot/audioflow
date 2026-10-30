defmodule AudioFlow.Session do
  @moduledoc """
  One active turn per session. Busy sessions reject input instead of queueing it.

  Options: `:stt`, `:llm`, `:tts` adapter tuples; `:owner`; `:timeout_ms`
  (30,000); `:max_input_bytes` (960,000); `:max_events` (1,024); optional
  `:output` transport tuple `{module, target}` implementing `AudioFlow.Output`.
  An optional `:vision` adapter converts RGB images to description strings.
  `:max_image_bytes` defaults to 6,291,456. Image-only sessions can omit `:stt`.
  Descriptions form one LLM prompt, then follow the same speech output path.
  Set `:history` to `true` or `[max_turns: 8, max_bytes: 16_384]` to retain
  successful user/assistant pairs. The LLM then receives a list of role/content
  message maps. History is disabled by default. Context limits count UTF-8 text
  bytes, not tokens. Cancelled and failed turns do not change saved history.
  The session stops when its owner exits. Interrupted turns cannot deliver
  further output. Cancellation stops the caller task, but an inference engine
  may still finish a batch already submitted to shared hardware.
  """
  use GenServer, restart: :temporary
  alias AudioFlow.{Adapter, Audio, History, Image}

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(options, :owner)
    adapters = Map.new([:llm, :tts], &{&1, Keyword.fetch!(options, &1)})
    adapters = Map.merge(adapters, Map.new(Keyword.take(options, [:stt, :vision])))

    if not (Map.has_key?(adapters, :stt) or Map.has_key?(adapters, :vision)),
      do: raise(ArgumentError, "a session requires an :stt or :vision adapter")

    limits =
      Map.new(
        [
          timeout_ms: 30_000,
          max_input_bytes: 960_000,
          max_image_bytes: 6_291_456,
          max_events: 1_024
        ],
        fn {key, default} ->
          value = Keyword.get(options, key, default)

          if not (is_integer(value) and value > 0),
            do: raise(ArgumentError, "#{key} must be positive")

          {key, value}
        end
      )

    {:ok,
     %{
       owner: owner,
       owner_ref: Process.monitor(owner),
       adapters: adapters,
       limits: limits,
       history: History.new(Keyword.get(options, :history, false)),
       output: Keyword.get(options, :output),
       output_turn: nil,
       active: nil
     }}
  end

  @impl true
  def handle_call({:submit, input}, _from, state) do
    {valid?, stage, kind, limit} = input_spec(input, state.limits)

    cond do
      not valid? ->
        {:reply, {:error, invalid_input(input)}, state}

      not Map.has_key?(state.adapters, stage) ->
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
            adapters = state.adapters
            output = state.output

            task =
              Task.Supervisor.async_nolink(AudioFlow.Tasks, fn ->
                pipeline(session, turn, input, stage, kind, adapters, output)
              end)

            timer = Process.send_after(self(), {:timeout, turn}, state.limits.timeout_ms)

            active = %{
              turn: turn,
              task: task,
              timer: timer,
              started: started,
              first: %{},
              events: 0,
              input_bytes: 0,
              context: nil
            }

            {:reply, {:ok, turn}, %{state | active: active, output_turn: turn}}

          {:error, reason} ->
            {:reply, {:error, {:output, reason}}, state}
        end
    end
  end

  def handle_call(:clear_history, _from, %{active: nil} = state),
    do: {:reply, :ok, %{state | history: History.clear(state.history)}}

  def handle_call(:clear_history, _from, state), do: {:reply, {:error, :busy}, state}

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

  def handle_call(:cancel, _from, %{active: nil} = state),
    do: {:reply, flush_output(state), state}

  def handle_call(:cancel, _from, state) do
    kill(state.active)
    result = flush_output(state)

    event =
      case result do
        :ok -> {:cancelled, metrics(state.active)}
        {:error, reason} -> {:error, {:output_flush, reason}, metrics(state.active)}
      end

    notify(state, event)
    {:reply, result, %{state | active: nil}}
  end

  def handle_call({:emit, turn, kind, value}, _from, %{active: %{turn: turn} = active} = state) do
    cond do
      not valid_output?(kind, value) ->
        {:reply, {:error, :invalid_output}, state}

      active.events >= state.limits.max_events ->
        {:reply, {:error, :output_limit}, state}

      true ->
        case record_context(state, kind, value) do
          {:ok, active} ->
            first = Map.put_new(active.first, kind, now() - active.started)
            notify(state, {kind, value})
            {:reply, :ok, %{state | active: %{active | first: first, events: active.events + 1}}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:emit, _, _, _}, _from, state), do: {:reply, {:error, :stale_turn}, state}

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

    notify(state, event)

    history =
      if result == :ok and state.active.context != nil,
        do: History.commit(state.active.context),
        else: state.history

    {:noreply, %{state | active: nil, history: history}}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _, reason}, %{active: %{task: %{ref: ref}}} = state) do
    Process.cancel_timer(state.active.timer)
    flush_output(state)
    notify(state, {:error, {:task_exit, reason}, metrics(state.active)})
    {:noreply, %{state | active: nil}}
  end

  def handle_info({:timeout, turn}, %{active: %{turn: turn}} = state) do
    kill(state.active)
    flush_output(state)
    notify(state, {:error, :timeout, metrics(state.active)})
    {:noreply, %{state | active: nil}}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    if state.active, do: kill(state.active)
    flush_output(state)
  end

  defp pipeline(session, turn, input, stage, kind, adapters, output) do
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
      Adapter.run(Map.fetch!(adapters, stage), input, fn text ->
        emit.(kind, text)
        Process.put(key, [text | Process.get(key)])
        :ok
      end)

      transcript = Process.get(key) |> Enum.reverse() |> Enum.join("") |> String.trim()
      transcript = input_context(input, transcript)

      if transcript != "" do
        prompt =
          case GenServer.call(session, {:context, turn, transcript}) do
            {:ok, prompt} -> prompt
            {:error, reason} -> throw(reason)
          end

        Adapter.run(adapters.llm, prompt, fn text ->
          emit.(:text, text)

          if String.trim(text) != "" do
            Adapter.run(adapters.tts, text, fn audio ->
              emit.(:audio, audio)

              case AudioFlow.Output.call(output, :push, [{session, turn}, audio]) do
                :ok -> :ok
                {:error, reason} -> throw({:output, reason})
              end
            end)
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

  defp flush_output(%{output_turn: nil}), do: :ok

  defp flush_output(state),
    do: AudioFlow.Output.call(state.output, :flush, [{self(), state.output_turn}])

  defp valid_output?(:audio, audio), do: Audio.valid?(audio)

  defp valid_output?(kind, text) when kind in [:text, :transcript, :description],
    do: is_binary(text)

  defp input_spec(%Audio{} = audio, limits),
    do: {Audio.valid?(audio), :stt, :transcript, limits.max_input_bytes}

  defp input_spec(%Image{} = image, limits),
    do: {Image.valid?(image), :vision, :description, limits.max_image_bytes}

  defp input_spec(_, _), do: {false, nil, nil, 0}
  defp invalid_input(%Image{}), do: :invalid_image
  defp invalid_input(_), do: :invalid_audio
  defp now, do: System.monotonic_time(:microsecond)
  defp notify(state, event), do: send(state.owner, {AudioFlow, self(), state.active.turn, event})

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
