# Private stdin/stdout bridge for scripts/compare_pipecat.py. No network listener.
Code.require_file("support/media_benchmark.exs", __DIR__)
Logger.configure(level: :warning)
{options, metadata} = Code.eval_file(Path.join(__DIR__, "../examples/models.exs")) |> elem(0)

silero =
  AudioFlow.Silero.serving(
    System.get_env("AUDIOFLOW_SILERO_MODEL") ||
      {:hf, "onnx-community/silero-vad", "onnx/model.onnx"},
    load_options: [revision: "e71cae966052b992a7eca6b17738916ce0eca4ec"]
  )

{:ok, _} =
  Supervisor.start_link([AudioFlow.Models.child_spec(AudioFlow.Bench.VAD, silero)],
    strategy: :one_for_one
  )

defmodule AudioFlow.Bench.Bridge do
  use GenServer
  def write(message), do: IO.puts("AUDIOFLOW_BENCH " <> JSON.encode!(message))
  def start_link(options), do: GenServer.start_link(__MODULE__, options)
  @impl true
  def init(options), do: {:ok, %{options: options, jobs: %{}}}
  @impl true
  def handle_call(%{"op" => "cancel", "target" => id}, _, state) do
    if job = state.jobs[id], do: Task.Supervisor.terminate_child(AudioFlow.Tasks, job.pid)
    {:reply, :ok, state}
  end

  def handle_call(%{"id" => id} = request, _, state) do
    if map_size(state.jobs) >= 32 or Map.has_key?(state.jobs, id) do
      write(%{id: id, error: "bridge_busy", done: true})
      {:reply, :ok, state}
    else
      task =
        Task.Supervisor.async_nolink(AudioFlow.Tasks, fn ->
          try do
            result = execute(request, state.options)
            write(%{id: id, done: true, result: result})
          rescue
            e -> write(%{id: id, error: Exception.message(e), done: true})
          catch
            kind, reason -> write(%{id: id, error: inspect({kind, reason}), done: true})
          end
        end)

      {:reply, :ok, put_in(state.jobs[id], task)}
    end
  end

  @impl true
  def handle_info({ref, _}, state) do
    Process.demonitor(ref, [:flush])
    {:noreply, delete_job(state, ref)}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, state) do
    if entry = Enum.find(state.jobs, fn {_, task} -> task.ref == ref end) do
      {id, _} = entry
      write(%{id: id, error: inspect(reason), done: true})
    end

    {:noreply, delete_job(state, ref)}
  end

  defp delete_job(state, ref),
    do: %{state | jobs: Map.reject(state.jobs, fn {_, task} -> task.ref == ref end)}

  defp execute(%{"op" => "native", "path" => path} = request, options),
    do: AudioFlow.Bench.Native.run(path, options, Map.get(request, "interrupt", false))

  defp execute(%{"op" => "ingress", "path" => path}, _) do
    audio = AudioFlow.Bench.Ingress.read(path)

    %{
      audio: Base.encode64(audio.data),
      sha256: AudioFlow.Bench.Native.sha(audio.data),
      bytes: byte_size(audio.data)
    }
  end

  defp execute(%{"op" => "stage", "id" => id, "stage" => stage, "input" => input}, options) do
    key =
      case stage do
        "stt" -> :stt
        "llm" -> :llm
        "tts" -> :tts
      end

    input =
      if key == :stt,
        do: %AudioFlow.Audio{data: Base.decode64!(input), sample_rate: 16_000},
        else: input

    AudioFlow.Adapter.run(Keyword.fetch!(options, key), input, fn value ->
      output =
        case value do
          %AudioFlow.Audio{data: data, sample_rate: rate} ->
            %{audio: Base.encode64(data), sample_rate: rate}

          text when is_binary(text) ->
            %{text: text}
        end

      write(%{id: id, output: output})
      :ok
    end)

    nil
  end
end

{:ok, bridge} = AudioFlow.Bench.Bridge.start_link(options)
{commit, 0} = System.cmd("git", ["rev-parse", "HEAD"])

AudioFlow.Bench.Bridge.write(%{
  ready: true,
  models: metadata,
  source_commit: String.trim(commit),
  runtime: %{
    elixir: System.version(),
    otp: System.otp_release(),
    schedulers: System.schedulers_online()
  },
  vad: %{
    repository: "onnx-community/silero-vad",
    revision: "e71cae966052b992a7eca6b17738916ce0eca4ec",
    local_sha256:
      if(path = System.get_env("AUDIOFLOW_SILERO_MODEL"),
        do: File.read!(path) |> AudioFlow.Bench.Native.sha(),
        else: nil
      ),
    frame_samples: 512,
    endpoint: %{
      threshold: 0.5,
      silence_threshold: 0.35,
      min_speech_ms: 96,
      min_silence_ms: 320,
      pre_roll_ms: 64,
      max_utterance_ms: 30_000
    }
  },
  script_sha256: %{
    bridge: File.read!(__ENV__.file) |> AudioFlow.Bench.Native.sha(),
    media:
      File.read!(Path.join(__DIR__, "support/media_benchmark.exs"))
      |> AudioFlow.Bench.Native.sha()
  }
})

IO.stream(:stdio, :line)
|> Enum.each(fn line ->
  GenServer.call(bridge, JSON.decode!(line), :infinity)
end)
