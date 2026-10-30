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
