defmodule AudioFlow.ApplicationTest do
  use ExUnit.Case, async: true

  test "sessions stop before the inference children and the HTTP client they use" do
    # which_children/1 lists the most recently started child first.
    stop_order =
      AudioFlow.Supervisor
      |> Supervisor.which_children()
      |> Enum.map(&elem(&1, 0))

    position = &Enum.find_index(stop_order, fn id -> id == &1 end)

    assert position.(AudioFlow.Sessions) < position.(AudioFlow.Tasks)
    assert position.(AudioFlow.Tasks) < position.(AudioFlow.HTTPClient)
  end
end
