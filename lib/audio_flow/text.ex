defmodule AudioFlow.Text do
  @moduledoc """
  A typed user message. Its trimmed UTF-8 data is the LLM prompt.

  Text turns skip the STT and vision stages and emit no input events. The reply
  follows the normal text, speech, and history path. `:max_input_bytes` applies.
  """
  @enforce_keys [:data]
  defstruct [:data]

  @type t :: %__MODULE__{data: String.t()}

  def valid?(%__MODULE__{data: data}), do: is_binary(data) and String.valid?(data)
  def valid?(_), do: false
end
