defmodule AudioFlow.Session.Pipeline do
  @moduledoc false
  # Runs one turn inside its task: stage adapters, speech-to-speech or a graph.
  # Every call to the session waits without a timeout, because the session's
  # turn timer kills the task.
  require Logger
  alias AudioFlow.Adapter
  alias AudioFlow.Graph.Runner
  alias AudioFlow.Image
  alias AudioFlow.Telemetry
  alias AudioFlow.Transcript.Segment

  # The task is not linked to the session, so a killed session would leave it
  # streaming. A linked watcher monitors the session and kills the task.
  defp exit_with(session) do
    task = self()

    spawn_link(fn ->
      Process.flag(:trap_exit, true)
      ref = Process.monitor(session)

      receive do
        {:DOWN, ^ref, :process, _, _} -> Process.exit(task, :kill)
        {:EXIT, ^task, _} -> :ok
      end
    end)

    :ok
  end

  def run(session, turn, input, stage, kind, adapters, graph, output) do
    exit_with(session)

    cond do
      graph ->
        graph_pipeline(session, turn, input, graph, output)

      adapters[:speech_to_speech] ->
        speech_pipeline(session, turn, input, adapters.speech_to_speech, output)

      true ->
        pipeline(session, turn, input, stage, kind, adapters, output)
    end
  end

  defp speech_pipeline(session, turn, input, adapter, output) do
    {module, _} = adapter

    Telemetry.stage(
      %{session: session, turn: turn, stage: :speech_to_speech, adapter: module},
      fn -> Adapter.run(adapter, input, &speech_event(&1, session, turn, output)) end
    )
  rescue
    error -> exception_result(error, __STACKTRACE__)
  catch
    reason -> {:error, reason}
  end

  defp speech_event({kind, value}, session, turn, output)
       when kind in [:transcript, :text, :audio] do
    call!(session, {:emit, turn, kind, value})
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

    emit = fn kind, value -> call!(session, {:emit, turn, kind, value}) end

    key = make_ref()
    Process.put(key, [])

    try do
      transcript = input_transcript(run, emit, key, input, stage, kind)

      if transcript != "" and Map.has_key?(adapters, :llm),
        do: respond(run, emit, {session, turn, output}, transcript)

      :ok
    rescue
      error -> exception_result(error, __STACKTRACE__)
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

  # Turn-task calls wait without a timeout. The session's turn timer kills the
  # task, so a slow output callback cannot make a call exit after 5 seconds.
  defp call!(session, request) do
    case GenServer.call(session, request, :infinity) do
      :ok -> :ok
      {:error, reason} -> throw(reason)
    end
  end

  defp fetch!(session, request) do
    case GenServer.call(session, request, :infinity) do
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
    error -> exception_result(error, __STACKTRACE__)
  catch
    reason -> {:error, reason}
  end

  # The event keeps only the message (transports sanitize wire text); the log
  # keeps the stacktrace.
  defp exception_result(error, stacktrace) do
    Logger.error("AudioFlow turn failed: " <> Exception.format(:error, error, stacktrace))
    {:error, {:exception, Exception.message(error)}}
  end

  defp input_context(_, ""), do: ""

  defp input_context(%Image{pts: pts}, text) when is_integer(pts),
    do: "At video time #{div(pts, 1_000_000)} ms: #{text}"

  defp input_context(_, text), do: text
end
