defmodule AudioFlow.Image do
  @moduledoc """
  An RGB image or decoded video frame, with unsigned 8-bit channels in HWC order.

  Data must contain exactly `width * height * 3` bytes, without row padding.
  Decode compressed images before submission. Sessions process one frame per
  turn; frame sampling and decoding belong to the input transport.
  """
  @enforce_keys [:data, :width, :height]
  defstruct [:data, :width, :height]

  @type t :: %__MODULE__{data: binary(), width: pos_integer(), height: pos_integer()}

  def valid?(%__MODULE__{data: data, width: width, height: height}) do
    is_binary(data) and is_integer(width) and width > 0 and is_integer(height) and height > 0 and
      byte_size(data) == width * height * 3
  end

  def valid?(_), do: false
end
