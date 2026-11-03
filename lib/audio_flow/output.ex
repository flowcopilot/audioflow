defmodule AudioFlow.Output do
  @moduledoc """
  Output transport contract. A turn key is `{session_pid, turn_reference}`.

  `push/3` can block the turn worker to apply back pressure. `flush/2` must
  release a blocked push and stop queued output for that key. A completed turn
  can still have queued output, so `finish/2` must drain instead of discard it.
  """
  @type key :: {pid(), reference()}
  @callback start_turn(term(), key()) :: :ok | {:error, term()}
  @callback push(term(), key(), AudioFlow.Audio.t()) :: :ok | {:error, term()}
  @callback finish(term(), key()) :: :ok | {:error, term()}
  @callback flush(term(), key()) :: :ok | {:error, term()}

  @doc """
  Report actually rendered PCM in cumulative nanoseconds, never queued audio.
  Call from a trusted transport after endpoint acknowledgement. Stale turns,
  regressing offsets and offsets beyond emitted audio are rejected.
  """
  def acknowledge(session, turn, nanoseconds),
    do: GenServer.call(session, {:played, turn, nanoseconds})

  @doc """
  Ignore transcripts shorter than min_words (default 2), otherwise cancel.
  Ignored triggers leave generation and playback running; this is not
  pause/resume after cancellation.
  """
  def interrupt(session, transcript, options \\ []) do
    minimum = Keyword.fetch!(Keyword.validate!(options, min_words: 2), :min_words)

    if not (is_integer(minimum) and minimum > 0),
      do: raise(ArgumentError, "min_words must be positive")

    if length(String.split(transcript)) < minimum,
      do: {:ok, :ignored},
      else: AudioFlow.cancel(session)
  end

  @doc false
  def call(nil, _action, _arguments), do: :ok

  def call({module, target}, action, arguments) do
    case apply(module, action, [target | arguments]) do
      :ok -> :ok
      {:error, _} = error -> error
      other -> {:error, {:invalid_output_result, other}}
    end
  rescue
    error -> {:error, {:output_exception, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:output_exit, reason}}
  end
end
