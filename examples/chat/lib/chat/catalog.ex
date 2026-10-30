defmodule Chat.Catalog do
  @moduledoc """
  The models the chat can switch between. All run on the Apple GPU through MLX.

  `:memory_gb` estimates the loaded weights. Whisper loads in f32, so it uses
  about twice its f16 download. Compiled kernels and caches add to this.
  """

  @stt [
    %{
      id: "whisper-tiny",
      label: "Whisper tiny",
      engine: :whisper,
      repo: "openai/whisper-tiny",
      revision: "169d4a4341b33bc18d8881c4b69c2e104e1cc0af",
      memory_gb: 0.2
    },
    %{
      id: "whisper-small",
      label: "Whisper small",
      engine: :whisper,
      repo: "openai/whisper-small",
      revision: "973afd24965f72e36ca33b3055d56a652f456b4d",
      memory_gb: 1.0
    },
    %{
      id: "whisper-large-v3-turbo",
      label: "Whisper large v3 turbo",
      engine: :whisper,
      repo: "openai/whisper-large-v3-turbo",
      revision: "41f01f3fe87f28c78e2fbf8b568835947dd65ed9",
      memory_gb: 3.2
    },
    %{
      id: "qwen3-asr-0.6b",
      label: "Qwen3-ASR 0.6B (8-bit)",
      engine: :qwen3_asr,
      repo: "mlx-community/Qwen3-ASR-0.6B-8bit",
      revision: "89e96d92ba34aca20b3e29fb10cc284097d1219f",
      memory_gb: 1.0
    },
    %{
      id: "qwen3-asr-1.7b",
      label: "Qwen3-ASR 1.7B (8-bit)",
      engine: :qwen3_asr,
      repo: "mlx-community/Qwen3-ASR-1.7B-8bit",
      revision: "a8379a2e2f9e313c9292cdf1af4055ab56d50d55",
      memory_gb: 2.5
    }
  ]

  @llm [
    %{
      id: "qwen3-0.6b",
      label: "Qwen3 0.6B (4-bit)",
      repo: "lmstudio-community/Qwen3-0.6B-MLX-4bit",
      revision: "75429955681c1850a9c8723767fe4252da06eb57",
      memory_gb: 0.4
    },
    %{
      id: "qwen3-1.7b",
      label: "Qwen3 1.7B (4-bit)",
      repo: "lmstudio-community/Qwen3-1.7B-MLX-4bit",
      revision: "46a51038b9871ba2ad249422905f1defe1f289f5",
      memory_gb: 1.0
    },
    %{
      id: "qwen3-4b",
      label: "Qwen3 4B (4-bit)",
      repo: "lmstudio-community/Qwen3-4B-MLX-4bit",
      revision: "480ec45ecf06ae3c061e4ef11345d05c7fdb02f1",
      memory_gb: 2.3
    },
    %{
      id: "qwen3-8b",
      label: "Qwen3 8B (4-bit)",
      repo: "lmstudio-community/Qwen3-8B-MLX-4bit",
      revision: "a84107f5c4dfdecf389b208598faeac322048237",
      memory_gb: 4.6
    }
  ]

  @voices [
    %{id: "af_heart", label: "Heart (US, female)"},
    %{id: "am_adam", label: "Adam (US, male)"},
    %{id: "bf_emma", label: "Emma (UK, female)"},
    %{id: "bm_george", label: "George (UK, male)"}
  ]

  # Kokoro 82M in f32, with all listed voice styles.
  @tts_memory_gb 0.4

  def stt, do: @stt
  def llm, do: @llm
  def voices, do: @voices
  def tts_memory_gb, do: @tts_memory_gb

  def fetch!(:stt, id),
    do: Enum.find(@stt, &(&1.id == id)) || raise(ArgumentError, "unknown STT model #{id}")

  def fetch!(:llm, id),
    do: Enum.find(@llm, &(&1.id == id)) || raise(ArgumentError, "unknown LLM #{id}")

  def fetch!(:voice, id),
    do: Enum.find(@voices, &(&1.id == id)) || raise(ArgumentError, "unknown voice #{id}")

  @doc "The largest STT, LLM, and TTS combination, in GB."
  def max_memory_gb,
    do:
      Enum.max_by(@stt, & &1.memory_gb).memory_gb + Enum.max_by(@llm, & &1.memory_gb).memory_gb +
        @tts_memory_gb
end
