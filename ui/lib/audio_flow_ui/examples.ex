defmodule AudioFlowUI.Examples do
  @moduledoc "Runnable synthetic checks and editable starter graphs; no inference claims."
  alias AudioFlow.Graph
  alias AudioFlow.Graph.Conversation
  alias AudioFlow.Graph.Handoff
  alias AudioFlow.Recording
  alias AudioFlow.Recording.Store

  def starter("tts") do
    %{
      "name" => "Remote TTS (requires ElevenLabs account)",
      "nodes" => [
        %{"id" => "in", "type" => "input.text"},
        %{
          "id" => "voice",
          "type" => "elevenlabs.tts",
          "options" => %{
            "model" => "eleven_multilingual_v2",
            "voice_id" => "",
            "language" => "en"
          }
        }
      ],
      "edges" => [%{"from" => "in", "to" => "voice"}]
    }
  end

  def starter("stt") do
    %{
      "name" => "Remote STT (PCM upload required)",
      "nodes" => [
        %{"id" => "in", "type" => "input.audio"},
        %{
          "id" => "transcript",
          "type" => "deepgram.stt",
          "options" => %{"model" => "nova-3", "language" => "en"}
        }
      ],
      "edges" => [%{"from" => "in", "to" => "transcript"}]
    }
  end

  def starter("rag") do
    %{
      "name" => "RAG (native embeddings + configured retrieval required)",
      "nodes" => [
        %{"id" => "in", "type" => "input.text"},
        %{
          "id" => "embed",
          "type" => "text.embedding",
          "options" => %{"model" => "sentence-transformers/all-MiniLM-L6-v2"}
        },
        %{"id" => "docs", "type" => "rag.retrieve", "options" => %{"profile" => "starter"}},
        %{"id" => "reply", "type" => "demo.llm"}
      ],
      "edges" => [
        %{"from" => "in", "to" => "embed"},
        %{"from" => "embed", "to" => "docs"},
        %{"from" => "docs", "to" => "reply"}
      ]
    }
  end

  def graph, do: graph("demo.llm")

  defp graph(reply_type) do
    %{
      "nodes" => [
        %{"id" => "in", "type" => "input.text"},
        %{"id" => "reply", "type" => reply_type}
      ],
      "edges" => [%{"from" => "in", "to" => "reply"}],
      "settings" => %{"history" => true}
    }
  end

  def evaluate(graph, script, record? \\ false) do
    with [] <- AudioFlowUI.errors(graph) ++ AudioFlowUI.Prerequisites.errors(graph),
         {:ok, steps} <- parse(script),
         {:ok, options} <- Graph.session_options(graph, AudioFlowUI.catalog()),
         {:ok, store} <- recording_store(record?),
         {:ok, session} <- AudioFlow.start_session(options) do
      try do
        results =
          AudioFlow.Evaluation.Conversation.run!(
            session,
            Enum.map(steps, fn {input, _} -> %{input: input} end),
            node: reply_node(graph),
            timeout_ms: 120_000
          )

        recorder = if store, do: Recording.new(session, store, redactor: redactor())

        {rows, _} =
          Enum.map_reduce(Enum.zip(steps, results), recorder, fn {{input, expected}, result},
                                                                 recorder ->
            {recording, recorder} = persist(recorder, session, result)

            {%{
               input: input,
               reply: result.reply,
               expected: expected,
               passed: result.reply == expected,
               recording: recording
             }, recorder}
          end)

        {:ok, rows}
      after
        AudioFlow.stop_session(session)
      end
    else
      errors when is_list(errors) -> {:error, Enum.join(errors, "; ")}
      error -> error
    end
  rescue
    _ -> {:error, "Evaluation failed; check graph configuration and turn deadlines."}
  end

  defp reply_node(graph) do
    graph["nodes"]
    |> Enum.reverse()
    |> Enum.find_value(fn node ->
      if Enum.any?(
           AudioFlowUI.node_types(),
           &(&1["type"] == node["type"] and &1["event"] == "text")
         ),
         do: node["id"]
    end)
  end

  defp parse(script) when byte_size(script) <= 16_384 do
    lines = String.split(script, "\n", trim: true)
    steps = Enum.map(lines, &String.split(&1, " => ", parts: 2))

    if Enum.count_until(steps, 11) in 1..10 and Enum.all?(steps, &match?([_, _], &1)),
      do: {:ok, Enum.map(steps, fn [input, expected] -> {input, expected} end)},
      else: {:error, "Use 1–10 lines: input => exact expected reply"}
  end

  defp parse(_), do: {:error, "Script exceeds 16 KiB"}

  defp recording_store(false), do: {:ok, nil}

  defp recording_store(true) do
    case Application.get_env(:audio_flow_ui, :recordings_dir) do
      nil ->
        {:error, "Set AUDIOFLOW_UI_RECORDINGS in the server environment to enable recordings"}

      dir ->
        Store.new(dir, max_records: 100, max_age_ms: 86_400_000)
    end
  end

  defp redactor,
    do: AudioFlow.Privacy.rules([{~r/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i, "[email]"}])

  defp persist(nil, _, _), do: {nil, nil}

  defp persist(recorder, session, result) do
    messages = result.events ++ [{:done, result.metrics}]

    Enum.reduce(messages, {nil, recorder}, fn event, {id, state} ->
      case Recording.consume(state, {AudioFlow, session, result.turn, event}) do
        {:ok, state, next} -> {next || id, state}
        {:error, _, state} -> {"recording failed", state}
      end
    end)
  end

  defmodule WorkflowNode do
    @moduledoc false
    @behaviour AudioFlow.Graph.Node

    @impl true
    def nodes do
      [
        %{
          type: "example.handoff",
          title: "Scripted handoff",
          description: "Blocks until the example owner selects a turn outcome.",
          input: :text,
          output: :text,
          history: true,
          options: []
        }
      ]
    end

    @impl true
    def adapter("example.handoff", _options) do
      owner = self()

      {AudioFlow.Adapters.Function,
       run: fn _, emit ->
         send(owner, {:workflow_ready, self()})

         receive do
           :finish -> emit.("Transferred")
           :fail -> {:error, :scripted_failure}
         after
           5_000 -> {:error, :timeout}
         end
       end}
    end
  end

  def workflow do
    triage = graph("example.handoff")
    catalog = Map.merge(AudioFlowUI.catalog(), Graph.catalog([WorkflowNode]))

    flow =
      Conversation.new(
        %{"triage" => triage, "billing" => graph()},
        "triage",
        %{{"triage", {:intent, "billing"}} => "billing"},
        catalog
      )

    {:ok, session} = Conversation.start_session(flow)

    try do
      cancelled = workflow_turn(session, :fail)
      {:ok, "triage"} = Conversation.state(session)
      completed = workflow_turn(session, :finish)
      {:ok, "billing"} = Conversation.state(session)

      %{
        failed_turn: cancelled,
        state_after_failure: "triage",
        successful_turn: completed,
        state_after_success: "billing"
      }
    after
      AudioFlow.stop_session(session)
    end
  end

  defp workflow_turn(session, outcome) do
    {:ok, turn} = AudioFlow.submit(session, %AudioFlow.Text{data: "billing"})

    receive do
      {:workflow_ready, task} ->
        {:ok, _} =
          Handoff.run(%{intent: "billing"}, %{session: session, turn: turn})

        send(task, outcome)
    after
      5_000 -> raise "workflow did not start"
    end

    await(session, turn)
  end

  defp await(session, turn) do
    receive do
      {AudioFlow, ^session, ^turn, {:done, _}} -> "done"
      {AudioFlow, ^session, ^turn, {:error, _, _}} -> "error"
      {AudioFlow, ^session, ^turn, _} -> await(session, turn)
    after
      5_000 -> raise "workflow timed out"
    end
  end
end
