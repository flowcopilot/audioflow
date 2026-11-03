defmodule AudioFlow.ApplicationTest do
  use ExUnit.Case, async: true

  defmodule TestAgent do
    use Jido.Agent, name: "bootstrap_test", schema: []
  end

  test "the application can start and locate a Jido agent" do
    id = "bootstrap-#{System.unique_integer([:positive])}"
    assert {:ok, pid} = AudioFlow.Jido.start_agent(TestAgent, id: id)
    on_exit(fn -> AudioFlow.Jido.stop_agent(pid) end)

    assert AudioFlow.Jido.whereis(id) == pid
  end
end
