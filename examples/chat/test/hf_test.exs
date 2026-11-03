defmodule Chat.HFTest.Hub do
  alias Plug.Conn

  @behaviour Plug
  def init(opts), do: opts

  def call(conn, state) do
    Agent.update(state, &Map.update!(&1, :requests, fn paths -> [conn.request_path | paths] end))
    conn = Conn.fetch_query_params(conn)
    revision = Agent.get(state, & &1.revision)

    case {conn.request_path, conn.query_params} do
      {"/api/models/test/model", %{"revision" => ^revision}} ->
        listing_response(conn, state)

      {"/test/model/resolve/" <> rest, _} ->
        file_response(conn, state, revision, rest)

      _ ->
        Conn.send_resp(conn, 404, "unknown repository")
    end
  end

  defp listing_response(conn, state) do
    if Agent.get(state, & &1.fail_listing) do
      Conn.send_resp(conn, 404, "missing repository")
    else
      body =
        Jason.encode!(%{
          siblings: [%{rfilename: "config.json"}, %{rfilename: "model.safetensors"}]
        })

      conn
      |> Conn.put_resp_content_type("application/json")
      |> Conn.send_resp(200, body)
    end
  end

  defp file_response(conn, state, revision, rest) do
    case String.split(rest, "/", parts: 2) do
      [^revision, "config.json"] ->
        Conn.send_resp(conn, 200, ~s({"model_type":"qwen3"}))

      [^revision, "model.safetensors"] ->
        if Agent.get(state, & &1.fail_weights),
          do: Conn.send_resp(conn, 404, "missing weights"),
          else: Conn.send_resp(conn, 200, "fixture weights")

      _ ->
        Conn.send_resp(conn, 404, "wrong revision")
    end
  end
end

defmodule Chat.HFTest do
  use ExUnit.Case, async: false

  @revision "0123456789abcdef0123456789abcdef01234567"

  setup do
    cache = Path.join(System.tmp_dir!(), "chat-hf-#{System.unique_integer([:positive])}")

    state =
      start_supervised!(
        {Agent,
         fn -> %{revision: @revision, fail_weights: false, fail_listing: false, requests: []} end}
      )

    server =
      start_supervised!({Bandit, plug: {Chat.HFTest.Hub, state}, ip: {127, 0, 0, 1}, port: 0})

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    previous =
      for key <- [:endpoint, :cache_dir, :token], do: {key, Application.fetch_env(:hf_hub, key)}

    Application.put_env(:hf_hub, :endpoint, "http://127.0.0.1:#{port}")
    Application.put_env(:hf_hub, :cache_dir, cache)
    Application.put_env(:hf_hub, :token, nil)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:hf_hub, key, value)
          :error -> Application.delete_env(:hf_hub, key)
        end
      end

      File.rm_rf!(cache)
    end)

    dir = Path.join([cache, "hub", "models--test--model", "snapshots", @revision])
    %{state: state, dir: dir, cache: cache}
  end

  test "returns a loader directory at the pinned revision and reuses complete files", %{
    state: state,
    dir: dir
  } do
    assert Chat.HF.snapshot!("test/model", @revision) == dir
    assert File.read!(Path.join(dir, "config.json")) == ~s({"model_type":"qwen3"})
    assert File.read!(Path.join(dir, "model.safetensors")) == "fixture weights"
    Agent.update(state, &%{&1 | requests: []})

    assert Chat.HF.snapshot!("test/model", @revision) == dir
    assert Agent.get(state, & &1.requests) == ["/api/models/test/model"]
  end

  test "config alone and interrupted weights are repaired, including after a failed attempt", %{
    state: state,
    dir: dir
  } do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "config.json"), ~s({"model_type":"qwen3"}))
    weights = Path.join(dir, "model.safetensors")
    File.write!(weights <> ".incomplete", "partial")
    Agent.update(state, &%{&1 | fail_weights: true})

    error = assert_raise RuntimeError, fn -> Chat.HF.snapshot!("test/model", @revision) end
    assert error.message =~ "test/model at #{@revision}"
    assert error.message =~ "download_failed"
    refute File.exists?(weights)
    refute File.exists?(weights <> ".incomplete")

    Agent.update(state, &%{&1 | fail_weights: false})
    assert Chat.HF.snapshot!("test/model", @revision) == dir
    assert File.read!(weights) == "fixture weights"
    refute File.exists?(weights <> ".incomplete")
  end

  test "listing errors are reported even when a cached config exists", %{state: state, dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "config.json"), "{}")
    Agent.update(state, &%{&1 | fail_listing: true})
    error = assert_raise RuntimeError, fn -> Chat.HF.snapshot!("test/model", @revision) end
    assert error.message =~ "test/model at #{@revision}"
    assert error.message =~ "not_found"
  end
end
