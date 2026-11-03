defmodule AudioFlow.VideoOutput.IVFTest do
  use ExUnit.Case, async: true
  alias AudioFlow.VideoOutput.IVF

  test "reads real VP8 fixture with exact presentation timeline" do
    assert {:ok, %{width: 160, height: 90, frames: frames}} =
             IVF.read("examples/network/assets/test-pattern.ivf")

    assert Enum.map(frames, & &1.pts_us) == [0, 200_000, 400_000]
    assert Enum.all?(frames, &(byte_size(&1.data) > 0))
  end

  test "rejects unsupported codecs, truncated frames, oversized frames and regressing clocks" do
    {:ok, binary} = File.read("examples/network/assets/test-pattern.ivf")
    assert {:error, :invalid_ivf} = IVF.decode(<<"nope">>)
    <<head::binary-size(8), _::binary-size(4), rest::binary>> = binary
    assert {:error, :invalid_ivf} = IVF.decode(head <> "AV01" <> rest)
    assert {:error, :invalid_frame} = IVF.decode(binary_part(binary, 0, byte_size(binary) - 1))
    <<header::binary-size(32), _::binary>> = binary
    assert {:error, :invalid_frame} = IVF.decode(header <> <<262_145::little-32, 0::little-64>>)

    assert {:error, :invalid_frame} =
             IVF.decode(
               header <> <<1::little-32, 2::little-64, 0, 1::little-32, 1::little-64, 0>>
             )
  end
end
