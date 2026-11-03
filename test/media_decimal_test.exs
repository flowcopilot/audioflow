if Code.ensure_loaded?(Ratio) do
  defmodule AudioFlow.MediaDecimalTest do
    use ExUnit.Case, async: true

    test "media rational clocks and Decimal 3 retain exact mixed arithmetic" do
      assert Version.match?(Application.spec(:decimal, :vsn) |> to_string(), "~> 3.2")
      third = Ratio.new(1, 3)
      decimal = Decimal.new("0.5")

      assert Ratio.new(decimal) == Ratio.new(1, 2)
      assert Numbers.add(third, decimal) == Ratio.new(5, 6)
      assert Numbers.add(decimal, third) == Ratio.new(5, 6)
      assert Numbers.sub(third, decimal) == Ratio.new(-1, 6)
      assert Numbers.mult(third, decimal) == Ratio.new(1, 6)
      assert Numbers.div(third, decimal) == Ratio.new(2, 3)
      assert Ratio.new(1_000_000_000, 48_000) |> Ratio.mult(48_000) == Ratio.new(1_000_000_000)
    end
  end
end
