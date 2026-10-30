defmodule AudioFlow.Image do
  @moduledoc """
  An RGB image or decoded video frame, with unsigned 8-bit channels in HWC order.

  Data must contain exactly `width * height * 3` bytes, without row padding.
  Decode compressed images before submission. Sessions process one frame per
  turn; frame sampling and decoding belong to the input transport.
  Optional `:pts` gives presentation time in nanoseconds. Video readers use a
  timeline starting at the first frame unless raw timestamp mode is selected.
  """
  @enforce_keys [:data, :width, :height]
  defstruct [:data, :width, :height, :pts]

  @type t :: %__MODULE__{
          data: binary(),
          width: pos_integer(),
          height: pos_integer(),
          pts: integer() | nil
        }

  def valid?(%__MODULE__{data: data, width: width, height: height, pts: pts}) do
    is_binary(data) and is_integer(width) and width > 0 and is_integer(height) and height > 0 and
      byte_size(data) == width * height * 3 and (pts == nil or is_integer(pts))
  end

  def valid?(_), do: false
end
