defmodule AudioFlow.SpeexDSP do
  @moduledoc """
  Native SpeexDSP denoising and reference-signal acoustic echo cancellation.
  Start one worker per input stream with `start_link(executable: path)`.
  The native worker uses mono s16le 16 kHz, 512-sample frames, a 200 ms echo
  tail, and -20 dB noise suppression. It never enables automatic gain control.
  Pass `{AudioFlow.SpeexDSP, worker: pid}` as VoiceInput's `:preprocessor`.
  A missing reference means silence; cancellation requires synchronized reference
  samples via `VoiceInput.push/3`. Native failure raises rather than silently
  passing unfiltered audio to VAD. See `docs/input-processing.md`.
  """
  alias AudioFlow.Audio
  alias AudioFlow.PacketWorker

  def start_link(options), do: PacketWorker.start_link(options)

  def init(options, 16_000, 512), do: %{worker: Keyword.fetch!(options, :worker)}

  def init(_, _, _),
    do: raise(ArgumentError, "SpeexDSP requires 512-sample 16 kHz detector frames")

  def process(%Audio{data: mic} = audio, %Audio{data: reference}, state) do
    case PacketWorker.request(state.worker, mic <> reference, 200) do
      {:ok, pcm} when byte_size(pcm) == byte_size(mic) -> {%{audio | data: pcm}, state}
      failure -> raise "SpeexDSP preprocessing failed: #{inspect(failure)}"
    end
  end
end
