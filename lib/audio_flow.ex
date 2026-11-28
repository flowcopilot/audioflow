defmodule AudioFlow do
  @moduledoc """
  Supervised voice, image, and text sessions with interchangeable inference engines.

  Start a session with `start_session/1`, send input with `submit/2`, and read
  the events that the session sends to its owner:

      {:ok, session} = AudioFlow.start_session(AudioFlow.Adapters.Demo.options())
      {:ok, turn} = AudioFlow.submit(session, %AudioFlow.Text{data: "Hello"})

      receive do
        {AudioFlow, ^session, ^turn, event} -> event
      end

  ## Events

  Each session sends `{AudioFlow, session_pid, turn_ref, event}` to its owner
  (see `t:message/0`). A turn ends with exactly one terminal event.

  | Event | Type | Sent |
  | --- | --- | --- |
  | `{:transcript, text}` | pipeline | STT output, or text input |
  | `{:segment, %AudioFlow.Transcript.Segment{}}` | pipeline | STT adapters that emit segments |
  | `{:partial_transcript, text}` | pipeline | STT adapters that emit partial text |
  | `{:description, text}` | pipeline | Vision output for an image |
  | `{:text, text}` | pipeline | LLM output chunk |
  | `{:audio, %AudioFlow.Audio{}}` | pipeline | TTS output (not with `notify_audio: false`) |
  | `{kind, value, node_id}` | graph | Output of a graph node; `kind` can also be `:image` or `:vector` |
  | `{:done, metrics}` | terminal | The turn succeeded |
  | `{:cancelled, metrics}` | terminal | `cancel/1` ended the turn |
  | `{:error, reason, metrics}` | terminal | The turn failed (see `t:metrics/0`) |

  A session that runs an `AudioFlow.Graph` sends node outputs as
  `{kind, value, node_id}`. Pipeline sessions send `{kind, value}`. See
  `AudioFlow.Session` for the options and the turn rules.

  ## Configuration

  Streaming adapters share one HTTP/1 connection pool. Set its size in the
  application environment when more than 50 turns can stream from one host:

      config :audio_flow, :http_pool, size: 100, count: 2

  `:size` (50) is the connections per pool, `:count` (1) the pools per host and
  `:connect_timeout_ms` (5,000) the time to open a connection.
  """

  alias AudioFlow.Session
  alias AudioFlow.Session.Options

  @typedoc "A session pid or registered name."
  @type session :: GenServer.server()

  @typedoc "Input of one turn."
  @type input :: AudioFlow.Audio.t() | AudioFlow.Image.t() | AudioFlow.Text.t()

  @typedoc "Timing and size figures of a turn, in microseconds. A stage that did not run is `nil`."
  @type metrics :: %{
          duration_us: integer(),
          first_partial_transcript_us: integer() | nil,
          first_transcript_us: integer() | nil,
          first_description_us: integer() | nil,
          first_text_us: integer() | nil,
          first_audio_us: integer() | nil,
          events: non_neg_integer()
        }

  @typedoc "Event of a pipeline session: `{kind, value}`."
  @type pipeline_event ::
          {:transcript, String.t()}
          | {:segment, AudioFlow.Transcript.Segment.t()}
          | {:partial_transcript, String.t()}
          | {:description, String.t()}
          | {:text, String.t()}
          | {:audio, AudioFlow.Audio.t()}

  @typedoc "Event of a graph session: `{kind, value, node_id}`."
  @type graph_event ::
          {:transcript | :description | :text, String.t(), node_id :: String.t()}
          | {:audio, AudioFlow.Audio.t(), node_id :: String.t()}
          | {:image, AudioFlow.Image.t(), node_id :: String.t()}
          | {:vector, [number()], node_id :: String.t()}
          | {:segment, AudioFlow.Transcript.Segment.t(), node_id :: String.t()}
          | {:partial_transcript, String.t(), node_id :: String.t()}

  @typedoc "Last event of a turn."
  @type terminal_event ::
          {:done, metrics()} | {:cancelled, metrics()} | {:error, reason :: term(), metrics()}

  @typedoc "Any event of a turn."
  @type event :: pipeline_event() | graph_event() | terminal_event()

  @typedoc "Message that a session sends to its owner."
  @type message :: {AudioFlow, session_pid :: pid(), turn_ref :: reference(), event()}

  @doc """
  Start a supervised session. The caller is the owner unless `:owner` is set.

  Raises `ArgumentError` for an unknown option or an invalid value. Returns
  `{:error, reason}` when the combination of options is invalid. See
  `AudioFlow.Session` for the options.
  """
  @spec start_session(keyword()) :: DynamicSupervisor.on_start_child()
  def start_session(options) do
    options =
      options
      |> Keyword.put_new(:owner, self())
      |> Options.validate!()

    DynamicSupervisor.start_child(AudioFlow.Sessions, {AudioFlow.Session, options})
  end

  @doc """
  Start a turn with audio, an image or text. Returns `{:ok, turn_ref}`, and the
  owner then receives the events of the turn. Returns `{:error, :busy}` while a
  turn runs. Other errors are `:input_too_large`, `:invalid_audio`,
  `:invalid_image`, `:invalid_text`, `{:unsupported_input, stage}` and
  `{:output, reason}`.
  """
  @spec submit(session(), input()) :: {:ok, reference()} | {:error, term()}
  def submit(session, %AudioFlow.Audio{} = audio), do: Session.submit(session, audio)
  def submit(session, %AudioFlow.Image{} = image), do: Session.submit(session, image)
  def submit(session, %AudioFlow.Text{} = text), do: Session.submit(session, text)

  @doc """
  Cancel the running turn and flush the output. The owner receives
  `{:cancelled, metrics}`. Returns `:ok` also when no turn runs.
  """
  @spec cancel(session()) :: :ok | {:error, term()}
  def cancel(session), do: Session.cancel(session)

  @doc "True when the session has no turn and no pending interruption."
  @spec idle?(session()) :: boolean()
  defdelegate idle?(session), to: Session

  @doc "Transcribe long PCM audio with an STT adapter. See `AudioFlow.Transcription`."
  defdelegate transcribe(audio, stt, options \\ []), to: AudioFlow.Transcription

  @doc "Clear saved conversation text while idle. Returns `{:error, :busy}` during a turn."
  @spec clear_history(session()) :: :ok | {:error, :busy}
  defdelegate clear_history(session), to: Session

  @doc "Stop a session that `start_session/1` started."
  @spec stop_session(pid()) :: :ok | {:error, :not_found}
  def stop_session(session), do: DynamicSupervisor.terminate_child(AudioFlow.Sessions, session)
end
