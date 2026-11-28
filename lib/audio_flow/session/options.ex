defmodule AudioFlow.Session.Options do
  @moduledoc """
  Options of `AudioFlow.Session`, validated by `AudioFlow.start_session/1`.

  Unknown or misspelled keys raise `ArgumentError`. Combinations that need the
  other options (for example `:speech_to_speech` with `:graph`) are checked when
  the session starts, and `start_session/1` returns `{:error, reason}` for them.
  """

  @adapter {:tuple, [:atom, :keyword_list]}
  @optional_output {:or, [{:in, [nil]}, {:tuple, [:atom, :any]}]}

  @limits_schema [
    timeout_ms: [
      type: :pos_integer,
      default: 30_000,
      doc: "Deadline of one turn, in milliseconds."
    ],
    max_input_bytes: [
      type: :pos_integer,
      default: 960_000,
      doc: "Largest audio or text input, in bytes."
    ],
    max_image_bytes: [
      type: :pos_integer,
      default: 6_291_456,
      doc: "Largest image input, in bytes."
    ],
    max_events: [
      type: :pos_integer,
      default: 1024,
      doc: "Most output events in one turn."
    ],
    max_output_bytes: [
      type: :pos_integer,
      default: 16_777_216,
      doc: "Most cumulative event payload bytes in one turn, in every mode."
    ]
  ]

  @schema [
    owner: [
      type: :pid,
      required: true,
      doc:
        "The process that receives the events. The session stops when it exits. " <>
          "`AudioFlow.start_session/1` defaults it to the caller."
    ],
    stt: [
      type: @adapter,
      doc: "Speech-to-text adapter `{module, options}`. Image-only sessions can omit it."
    ],
    llm: [
      type: @adapter,
      doc: "Language model adapter `{module, options}`. Needs `:tts`; omit both to transcribe."
    ],
    tts: [
      type: @adapter,
      doc: "Text-to-speech adapter `{module, options}`. Needs `:llm`."
    ],
    vision: [
      type: @adapter,
      doc: "Adapter that converts RGB images to description strings."
    ],
    speech_to_speech: [
      type: @adapter,
      doc:
        "Mixed-event adapter for committed PCM turns without STT, LLM and TTS stages. " <>
          "Exclusive with `:graph`, the stage adapters, `:conversation` and history."
    ],
    graph: [
      type: {:struct, AudioFlow.Graph.Plan},
      doc: "Plan from `AudioFlow.Graph.session_options/2`, in place of the stage adapters."
    ],
    conversation: [
      type: {:struct, AudioFlow.Graph.Conversation},
      doc: "Conversation flow. `AudioFlow.Graph.Conversation.start_session/2` sets it."
    ],
    history: [
      type: {:or, [:boolean, {:in, [nil]}, :keyword_list]},
      default: false,
      doc:
        "`true` or `[max_turns: 8, max_bytes: 16_384]` retains successful user and " <>
          "assistant pairs, and the LLM then receives role/content message maps."
    ],
    restore: [
      type: :map,
      doc:
        "Snapshot from an earlier session: " <>
          "`%{history: [{user, assistant}], conversation_state: name, turns: count}`."
    ],
    on_commit: [
      type: :any,
      doc:
        "Receives the durable snapshot each time saved history or conversation state " <>
          "changes: a one-argument function, `{pid, tag}` (sends `{tag, snapshot}`) or " <>
          "`{module, function, args}` (snapshot appended). Prefer the last two in code " <>
          "that hot upgrades replace."
    ],
    output: [
      type: @optional_output,
      doc: "Output transport `{module, target}` implementing `AudioFlow.Output`."
    ],
    notify_audio: [
      type: :boolean,
      default: true,
      doc:
        "Send `{:audio, audio}` events to the owner. Set `false` when an `:output` " <>
          "transport already receives the audio; all other events still arrive."
    ]
  ]

  @doc "The resource limit options of a session."
  def limits_schema, do: @limits_schema

  @doc "The NimbleOptions schema of all session options."
  def schema, do: @schema ++ @limits_schema

  @doc "Documentation of all session options."
  def docs, do: NimbleOptions.docs(schema())

  @doc """
  Returns the validated options with defaults applied, or raises
  `ArgumentError` for unknown keys and invalid values.
  """
  @spec validate!(keyword()) :: keyword()
  def validate!(options) do
    case NimbleOptions.validate(options, schema()) do
      {:ok, validated} ->
        validated

      {:error, error} ->
        raise ArgumentError, "invalid session options: " <> Exception.message(error)
    end
  end
end
