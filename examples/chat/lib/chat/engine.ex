defmodule Chat.Engine do
  @moduledoc """
  Loads, swaps, and reports the shared models. One model per stage is loaded.

  Whisper and Kokoro run through Bumblebee and Transmuter on the EMLX GPU
  backend. Qwen3 replies run through the native EMLXAxon generator. Qwen3-ASR
  runs in the `Chat.Qwen3ASR` sidecar. Sessions call `Chat.Stage`, which reads
  the current adapter for each turn, so a switch applies to the next turn and
  keeps conversation history.

  The startup selection comes from `CHAT_STT`, `CHAT_LLM`, and `CHAT_VOICE`,
  with IDs from `Chat.Catalog`. Status changes are broadcast on the `"models"`
  topic as `{:models, status}`.
  """
  use GenServer
  require Logger

  alias AudioFlow.Adapters.Function
  alias AudioFlow.Audio
  alias Chat.{Catalog, Qwen3ASR}

  @gpu {EMLX.Backend, device: :gpu}
  @defn [compiler: Chat.EMLXCompiler]
  @kokoro_revision "1939ad2a8e416c0acfeecc08a694d14ef25f2231"
  @topic "models"

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def topic, do: @topic

  @doc "Selection, per-stage load state, and the memory estimate."
  def status, do: GenServer.call(__MODULE__, :status)

  @doc "Switch a stage (`:stt`, `:llm`, or `:voice`) to a catalog ID."
  def select(stage, id), do: GenServer.call(__MODULE__, {:select, stage, id})

  @doc "The adapter that a session stage uses now, or nil while it loads."
  def adapter(stage), do: :persistent_term.get({__MODULE__, stage}, nil)

  @doc "Transcribe PCM with the current STT model, outside a session turn."
  def transcribe(%Audio{} = audio) do
    case adapter(:stt) do
      nil ->
        {:error, :model_loading}

      adapter ->
        key = make_ref()

        try do
          AudioFlow.Adapter.run(adapter, audio, fn text ->
            Process.put(key, [text | Process.get(key, [])])
            :ok
          end)

          {:ok, Process.get(key, []) |> Enum.reverse() |> Enum.join() |> String.trim()}
        catch
          reason -> {:error, reason}
        after
          Process.delete(key)
        end
    end
  end

  @impl true
  def init(nil) do
    selection = %{
      stt: System.get_env("CHAT_STT", "whisper-small"),
      llm: System.get_env("CHAT_LLM", "qwen3-1.7b"),
      voice: System.get_env("CHAT_VOICE", "af_heart")
    }

    Enum.each(selection, fn {stage, id} -> Catalog.fetch!(stage, id) end)
    state = %{selection: selection, loads: %{}, loaded: %{}, status: %{}}
    state = Enum.reduce([:tts, :stt, :llm], state, &start_load(&2, &1))
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, public(state), state}

  def handle_call({:select, :voice, id}, _from, state) do
    Catalog.fetch!(:voice, id)
    state = put_in(state.selection.voice, id)
    if state.loaded[:tts], do: publish_tts(state)
    {:reply, :ok, broadcast(state)}
  end

  def handle_call({:select, stage, id}, _from, state) when stage in [:stt, :llm] do
    Catalog.fetch!(stage, id)

    if state.selection[stage] == id and state.status[stage] in [:ready, :loading] do
      {:reply, :ok, state}
    else
      state = put_in(state.selection[stage], id)
      {:reply, :ok, start_load(state, stage)}
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_map_key(state.loads, ref) do
    Process.demonitor(ref, [:flush])
    {{stage, id}, loads} = Map.pop(state.loads, ref)
    state = %{state | loads: loads}

    cond do
      # A newer selection replaced this load. Release what it loaded.
      stage != :tts and state.selection[stage] != id ->
        with {:ok, loaded} <- result, do: release(state, loaded)
        {:noreply, state}

      true ->
        {:noreply, finish_load(state, stage, result)}
    end
  end

  def handle_info({:DOWN, ref, :process, _, reason}, state) when is_map_key(state.loads, ref) do
    {{stage, _id}, loads} = Map.pop(state.loads, ref)
    state = %{state | loads: loads}
    {:noreply, finish_load(state, stage, {:error, Exception.format_exit(reason)})}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp start_load(state, stage) do
    id = if stage == :tts, do: :kokoro, else: state.selection[stage]
    task = Task.Supervisor.async_nolink(Chat.Tasks, fn -> load(stage, id) end)

    put_in(state.loads[task.ref], {stage, id})
    |> put_in([:status, stage], :loading)
    |> broadcast()
  end

  defp finish_load(state, stage, {:ok, loaded}) do
    old = state.loaded[stage]
    state = put_in(state.loaded[stage], loaded) |> put_in([:status, stage], :ready)
    if old, do: release(state, old)

    if stage == :tts,
      do: publish_tts(state),
      else: :persistent_term.put({__MODULE__, stage}, loaded.adapter)

    broadcast(state)
  end

  defp finish_load(state, stage, {:error, reason}) do
    Logger.error("Loading the #{stage} model failed: #{inspect(reason)}")
    broadcast(put_in(state.status[stage], {:error, error_text(reason)}))
  end

  # The voice is part of each Kokoro request, so a voice switch needs no reload.
  defp publish_tts(state) do
    serving = state.loaded.tts.serving
    voice = state.selection.voice

    adapter =
      {AudioFlow.NxAdapter,
       serving: serving, input: &%{text: &1, voice: voice}, output: &AudioFlow.Kokoro.audio/1}

    :persistent_term.put({__MODULE__, :tts}, adapter)
  end

  defp load(:tts, :kokoro) do
    serving =
      AudioFlow.Kokoro.serving(
        voices: Enum.map(Catalog.voices(), & &1.id),
        load_options: [revision: @kokoro_revision, backend: @gpu],
        defn_options: @defn
      )

    {name, pid} = start_serving(Chat.TTS, serving)
    # The first request compiles the Metal kernels.
    Nx.Serving.batched_run(name, %{text: "Ready."}) |> AudioFlow.Kokoro.audio() |> Stream.run()
    {:ok, %{serving: name, pid: pid}}
  end

  defp load(:stt, id) do
    model = Catalog.fetch!(:stt, id)
    silence = %Audio{data: :binary.copy(<<0, 0>>, 16_000), sample_rate: 16_000}

    case model.engine do
      :whisper ->
        {:ok, serving} =
          AudioFlow.Models.whisper(model.repo,
            load_options: [revision: model.revision],
            model_options: [backend: @gpu],
            defn_options: @defn
          )

        {name, pid} = start_serving(:"Chat.STT.#{id}", serving)

        adapter =
          {AudioFlow.NxAdapter,
           serving: name,
           input: &AudioFlow.NxAdapter.whisper_input/1,
           output: &AudioFlow.NxAdapter.transcript/1}

        Nx.Serving.batched_run(name, AudioFlow.NxAdapter.whisper_input(silence))
        {:ok, %{adapter: adapter, serving: name, pid: pid}}

      :qwen3_asr ->
        with {:ok, _} <- Qwen3ASR.load(model),
             {:ok, _} <- Qwen3ASR.transcribe(model, silence.data) do
          run = fn %Audio{data: data}, emit ->
            case Qwen3ASR.transcribe(model, data) do
              {:ok, text} -> emit.(text)
              {:error, reason} -> {:error, reason}
            end
          end

          {:ok, %{adapter: {Function, run: run}, sidecar: true}}
        end
    end
  end

  defp load(:llm, id) do
    model = Catalog.fetch!(:llm, id)
    dir = Chat.HF.snapshot!(model.repo, model.revision)
    {:ok, tokenizer} = Bumblebee.load_tokenizer({:local, dir})
    {:ok, weights} = EMLXAxon.Qwen3.Loader.load(dir)
    generate(tokenizer, weights, [%{role: :user, content: "Hi"}], fn _ -> :ok end)
    {:ok, %{adapter: {Function, run: &generate(tokenizer, weights, &1, &2)}}}
  end

  # Streams sentence chunks, so speech starts after the first sentence.
  defp generate(tokenizer, weights, input, emit) do
    key = make_ref()
    Process.put(key, "")

    try do
      EMLXAxon.TextGeneration.stream(
        tokenizer,
        weights,
        AudioFlow.Prompt.qwen3(input),
        fn text ->
          {sentences, pending} = AudioFlow.TextChunks.push(Process.get(key), text)
          Process.put(key, pending)
          Enum.each(sentences, emit)
        end,
        max_new_tokens: 256,
        stream_chunking: :token
      )

      pending = Process.get(key)
      if pending != "", do: emit.(pending)
      :ok
    after
      Process.delete(key)
    end
  end

  defp start_serving(name, serving) do
    {:ok, pid} =
      DynamicSupervisor.start_child(Chat.Servings, AudioFlow.Models.child_spec(name, serving))

    {name, pid}
  end

  defp release(_state, %{pid: pid}), do: DynamicSupervisor.terminate_child(Chat.Servings, pid)

  # The sidecar holds one model. Keep it while the STT stage uses it.
  defp release(state, %{sidecar: true}) do
    if not Map.get(state.loaded[:stt] || %{}, :sidecar, false) and
         Catalog.fetch!(:stt, state.selection.stt).engine != :qwen3_asr,
       do: Qwen3ASR.stop()

    :ok
  end

  defp release(_state, _loaded), do: :ok

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(Chat.PubSub, @topic, {:models, public(state)})
    state
  end

  defp public(state) do
    memory =
      Catalog.fetch!(:stt, state.selection.stt).memory_gb +
        Catalog.fetch!(:llm, state.selection.llm).memory_gb + Catalog.tts_memory_gb()

    %{selection: state.selection, status: state.status, memory_gb: memory}
  end

  defp error_text(reason) when is_binary(reason), do: reason
  defp error_text(reason), do: inspect(reason)
end
