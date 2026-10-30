defmodule Chat.Qwen3ASR do
  @moduledoc """
  Qwen3-ASR through mlx-audio, in a Python process that `uv` manages.

  Bumblebee has no Qwen3-ASR model, so this stage runs outside Nx. The process
  starts on first use and keeps one model loaded. Requests are JSON lines; see
  `priv/python/qwen3_asr.py`. Its standard error goes to `log_path/0`.
  """
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Load a model. Downloads it on first use."
  def load(model, timeout \\ :infinity),
    do: GenServer.call(__MODULE__, {:request, Map.take(model, [:repo, :revision]), nil}, timeout)

  @doc "Transcribe mono 16 kHz s16le PCM."
  def transcribe(model, pcm, timeout \\ 60_000),
    do: GenServer.call(__MODULE__, {:request, Map.take(model, [:repo, :revision]), pcm}, timeout)

  @doc "Stop the process and free its model memory."
  def stop, do: GenServer.call(__MODULE__, :stop)

  def log_path, do: Path.join(System.tmp_dir!(), "audioflow-chat-qwen3-asr.log")

  @impl true
  def init(nil), do: {:ok, %{port: nil, next: 1, pending: %{}, buffer: ""}}

  @impl true
  def handle_call(:stop, _from, %{port: nil} = state), do: {:reply, :ok, state}

  def handle_call(:stop, _from, state) do
    Port.close(state.port)
    fail_pending(state, "Qwen3-ASR process stopped")
    {:reply, :ok, %{state | port: nil, pending: %{}, buffer: ""}}
  end

  def handle_call({:request, model, pcm}, from, state) do
    state = ensure_port(state)

    request =
      %{id: state.next, model: model.repo, revision: model.revision}
      |> then(&if(pcm, do: Map.put(&1, :pcm, Base.encode64(pcm)), else: &1))

    Port.command(state.port, [Jason.encode!(request), ?\n])

    {:noreply, %{state | next: state.next + 1, pending: Map.put(state.pending, state.next, from)}}
  end

  @impl true
  def handle_info({port, {:data, {:noeol, data}}}, %{port: port} = state),
    do: {:noreply, %{state | buffer: state.buffer <> data}}

  def handle_info({port, {:data, {:eol, data}}}, %{port: port} = state) do
    line = state.buffer <> data
    state = %{state | buffer: ""}

    case Jason.decode(line) do
      {:ok, %{"id" => id} = reply} ->
        {from, pending} = Map.pop(state.pending, id)
        result = if reply["error"], do: {:error, reply["error"]}, else: {:ok, reply["text"]}
        if from, do: GenServer.reply(from, result)
        {:noreply, %{state | pending: pending}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    fail_pending(state, "Qwen3-ASR process exited (#{status}). See #{log_path()}")
    {:noreply, %{state | port: nil, pending: %{}, buffer: ""}}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp fail_pending(state, message),
    do: Enum.each(state.pending, fn {_, from} -> GenServer.reply(from, {:error, message}) end)

  defp ensure_port(%{port: nil} = state) do
    uv = System.find_executable("uv") || raise "Qwen3-ASR needs uv: https://docs.astral.sh/uv/"
    script = Application.app_dir(:chat, "priv/python/qwen3_asr.py")

    port =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        :exit_status,
        {:line, 65_536},
        args: ["-c", ~s(exec "$0" run --quiet "$1" 2>>"$2"), uv, script, log_path()]
      ])

    %{state | port: port}
  end

  defp ensure_port(state), do: state
end
