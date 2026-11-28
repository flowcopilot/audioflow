defmodule AudioFlow do
  @moduledoc """
  Supervised voice, image, and text sessions with interchangeable inference engines.

  Each session sends `{AudioFlow, session_pid, turn_ref, event}` to its owner.
  Events are `{:transcript, text}`, `{:description, text}`, `{:text, text}`, `{:audio, audio}`,
  `{:done, metrics}`, `{:cancelled, metrics}`, or `{:error, reason, metrics}`.
  STT adapters can also cause `{:segment, %AudioFlow.Transcript.Segment{}}` and
  `{:partial_transcript, text}` events. See `AudioFlow.Session`.
  A session that runs an `AudioFlow.Graph` sends node outputs as
  `{kind, value, node_id}`, where kind can also be `:image` or `:vector`.
  """

  alias AudioFlow.Session
  alias AudioFlow.Session.Options

  def start_session(options) do
    options =
      options
      |> Keyword.put_new(:owner, self())
      |> Options.validate!()

    DynamicSupervisor.start_child(AudioFlow.Sessions, {AudioFlow.Session, options})
  end

  def submit(session, %AudioFlow.Audio{} = audio), do: Session.submit(session, audio)
  def submit(session, %AudioFlow.Image{} = image), do: Session.submit(session, image)
  def submit(session, %AudioFlow.Text{} = text), do: Session.submit(session, text)
  def cancel(session), do: Session.cancel(session)

  @doc "True when the session has no turn and no pending interruption."
  defdelegate idle?(session), to: Session

  @doc "Transcribe long PCM audio with an STT adapter. See `AudioFlow.Transcription`."
  defdelegate transcribe(audio, stt, options \\ []), to: AudioFlow.Transcription

  @doc "Clear saved conversation text while idle. Returns `{:error, :busy}` during a turn."
  defdelegate clear_history(session), to: Session
  def stop_session(session), do: DynamicSupervisor.terminate_child(AudioFlow.Sessions, session)
end
