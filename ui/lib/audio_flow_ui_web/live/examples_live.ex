defmodule AudioFlowUIWeb.ExamplesLive do
  use Phoenix.LiveView
  alias AudioFlowUI.Examples

  def mount(_, _, socket) do
    {:ok,
     assign(socket,
       result: nil,
       task: nil,
       graphs: AudioFlowUI.Graphs.list(),
       recording_enabled: Application.get_env(:audio_flow_ui, :recordings_dir) != nil
     )}
  end

  def handle_event("starter", %{"kind" => kind}, socket) when kind in ["tts", "stt", "rag"] do
    id = AudioFlowUI.GraphEdits.unique(kind, Enum.map(AudioFlowUI.Graphs.list(), & &1["id"]))
    {:ok, _} = Examples.starter(kind) |> Map.put("id", id) |> AudioFlowUI.Graphs.put()
    {:noreply, push_navigate(socket, to: "/graphs/#{id}")}
  end

  def handle_event("workflow", _, %{assigns: %{task: nil}} = socket),
    do: start(socket, fn -> Examples.workflow() end)

  def handle_event("evaluate", params, %{assigns: %{task: nil}} = socket) do
    graph =
      if params["graph"] == "synthetic",
        do: {:ok, Examples.graph()},
        else: AudioFlowUI.Graphs.get(params["graph"])

    case graph do
      {:ok, graph} ->
        start(socket, fn ->
          Examples.evaluate(graph, params["script"], params["record"] == "true")
        end)

      _ ->
        {:noreply, assign(socket, result: {:error, "Graph not found"})}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  defp start(socket, fun) do
    task = Task.Supervisor.async_nolink(AudioFlowUI.Tasks, fun)
    {:noreply, assign(socket, task: task.ref, result: nil)}
  end

  def handle_info({ref, result}, %{assigns: %{task: ref}} = socket) do
    Process.demonitor(ref, [:flush])
    {:noreply, assign(socket, task: nil, result: result)}
  end

  def handle_info({:DOWN, ref, _, _, _}, %{assigns: %{task: ref}} = socket),
    do: {:noreply, assign(socket, task: nil, result: {:error, "Example failed"})}

  def handle_info(_, socket), do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <main class="mx-auto flex max-w-3xl flex-col gap-6 p-8">
      <.link navigate="/">Graphs</.link>
      <h1 class="flex items-center gap-2.5 text-xl font-bold">
        <AudioFlowUIWeb.Layouts.logo /> Runnable examples
      </h1>
      <p>
        Synthetic checks use real sessions with deterministic adapters. They do not verify native models, providers or devices.
      </p>
      <section class="flex flex-col gap-3">
        <h2>Starter graphs</h2>
        <p>
          Edit model, voice and language options before running. Keys come only from the server environment.
          Configuration checks do not prove account access or database connectivity.
        </p>
        <button phx-click="starter" phx-value-kind="tts">Create remote TTS graph</button>
        <button phx-click="starter" phx-value-kind="stt">Create remote STT graph (mono s16le PCM)</button>
        <button phx-click="starter" phx-value-kind="rag">Create RAG graph (AUDIOFLOW_ML=1 + starter retrieval profile)</button>
        <p>
          RAG retrieves documents; the starter reply is a synthetic echo. Replace demo.llm with llm.chat_http for generated answers.
        </p>
      </section>
      <section class="flex flex-col gap-3">
        <h2>Handoff / workflow</h2>
        <p>
          Scripted Jido handoff during a real turn: failure rolls back to triage; success commits billing. No model intent classification.
        </p>
        <button id="workflow" phx-click="workflow" disabled={@task != nil}>Run synthetic rollback and handoff</button>
      </section>
      <section class="flex flex-col gap-3">
        <h2>Scripted conversation evaluation</h2>
        <p>
          One session per script; exact reply comparison. Use “input =&gt; expected reply”, one turn per line.
          For saved graphs, the last text node is selected. No audio quality grading.
        </p>
        <form id="evaluation" phx-submit="evaluate" class="flex flex-col gap-3">
          <select name="graph" aria-label="Graph to evaluate" class="border p-2">
            <option value="synthetic">Synthetic echo (no credentials)</option>
            <option :for={graph <- @graphs} value={graph["id"]}>{graph["name"]}</option>
          </select>
          <textarea name="script" aria-label="Conversation script" class="border p-2" rows="4">Hello => You said: Hello.</textarea>
          <label>
            <input type="checkbox" name="record" value="true" disabled={!@recording_enabled} />
            Record output text with email redaction; no PCM or input recording
          </label>
          <p>
            Recording requires server AUDIOFLOW_UI_RECORDINGS. Streams are bounded, stored privately for 24 hours,
            at most 100 artifacts. Email regex redaction does not cover other PII. Live results remain unredacted.
          </p>
          <button disabled={@task != nil}>Evaluate conversation</button>
        </form>
      </section>
      <section class="flex flex-col gap-2">
        <h2>Speech-to-speech and standalone transports</h2>
        <p>OpenAI Realtime and Gemini Live emit transcript, text and audio together.
          Use the dedicated Session example or chat app; these are not single-output graph nodes.</p>
        <a href="https://github.com/flowcopilot/audioflow/blob/feat/parallel-issue-integration/docs/providers.md">Speech-to-speech Session setup</a>
        <a href="https://github.com/flowcopilot/audioflow/tree/feat/parallel-issue-integration/examples/chat">Chat app</a>
        <a href="https://github.com/flowcopilot/audioflow/tree/feat/parallel-issue-integration/examples/rtvi-client">Official Pipecat SDK RTVI client (typed input/audio output)</a>
        <a href="https://github.com/flowcopilot/audioflow/blob/feat/parallel-issue-integration/examples/telephony-loopback.exs">Telephony loopback</a>
        <a href="https://github.com/flowcopilot/audioflow/tree/feat/parallel-issue-integration/examples/network">Encoded WebRTC loopback and finite LiveAvatar LITE publishing</a>
        <a href="https://github.com/flowcopilot/audioflow/tree/feat/parallel-issue-integration/examples/avatar">Standalone LiveAvatar browser viewer (local server; live credentials optional)</a>
        <p>Network examples require their documented encoder, peer and provider setup.
          Encoded WebRTC is a standalone peer path; it does not yet bridge PCM Sessions.
          Local protocol fixtures do not establish actual peer negotiation or provider inference.</p>
      </section>
      <p :if={@task}>Running…</p>
      <pre :if={@result} id="example-result" class="whitespace-pre-wrap border p-3">{inspect(@result, pretty: true, limit: :infinity)}</pre>
    </main>
    """
  end
end
