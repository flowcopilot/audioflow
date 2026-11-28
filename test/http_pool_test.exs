defmodule AudioFlow.HTTPPoolTest do
  # Reads and writes the application environment.
  use ExUnit.Case, async: false

  setup do
    previous = Application.fetch_env(:audio_flow, :http_pool)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:audio_flow, :http_pool, value)
        :error -> Application.delete_env(:audio_flow, :http_pool)
      end
    end)
  end

  test "the pool keeps the Finch defaults when nothing is configured" do
    Application.delete_env(:audio_flow, :http_pool)
    pool = AudioFlow.Application.http_pool()
    assert pool[:size] == 50
    assert pool[:count] == 1
    assert pool[:protocols] == [:http1]
    assert pool[:conn_opts] == [transport_opts: [timeout: 5_000]]
  end

  test "size, count and connect timeout come from the application environment" do
    Application.put_env(:audio_flow, :http_pool, size: 200, count: 4, connect_timeout_ms: 1_000)
    pool = AudioFlow.Application.http_pool()
    assert {pool[:size], pool[:count]} == {200, 4}
    assert pool[:conn_opts] == [transport_opts: [timeout: 1_000]]
  end

  test "an invalid pool option raises" do
    Application.put_env(:audio_flow, :http_pool, size: 0)
    assert_raise ArgumentError, ~r/size/, fn -> AudioFlow.Application.http_pool() end
  end
end
