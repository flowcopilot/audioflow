defmodule AudioFlow.LiveAvatarTest do
  use ExUnit.Case, async: true
  alias AudioFlow.Avatars.LiveAvatar

  defmodule SocketFixture do
    @behaviour WebSock
    def init(owner) do
      send(owner, {:socket, self()})
      {:ok, owner}
    end

    def handle_in({data, opcode: :text}, owner) do
      send(owner, {:command, JSON.decode!(data)})
      {:ok, owner}
    end

    def handle_info({:event, event}, owner), do: {:push, {:text, JSON.encode!(event)}, owner}
    def terminate(_, owner), do: send(owner, :socket_closed)
  end

  defmodule Endpoint do
    import Plug.Conn
    def init(owner), do: owner

    def call(%{request_path: "/ws"} = conn, owner),
      do: conn |> WebSockAdapter.upgrade(SocketFixture, owner, []) |> halt()

    def call(conn, owner) do
      {:ok, data, conn} = read_body(conn)
      body = JSON.decode!(data)
      send(owner, {:request, conn.request_path, body, conn.req_headers})

      result =
        case conn.request_path do
          "/v1/sessions/token" ->
            %{session_token: "session-secret"}

          "/v1/sessions/start" ->
            %{
              ws_url: "ws://127.0.0.1:#{conn.port}/ws",
              livekit_url: "wss://room.invalid",
              livekit_client_token: "viewer-secret"
            }

          "/v1/sessions/stop" ->
            nil
        end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, JSON.encode!(%{code: 100, data: result}))
    end
  end

  defp publisher do
    server =
      start_supervised!(
        {Bandit, plug: {Endpoint, self()}, port: 0, ip: {127, 0, 0, 1}, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    {:ok, pid} =
      LiveAvatar.start_link(
        owner: self(),
        api_key: "fixture",
        avatar_id: "avatar",
        endpoint: "http://127.0.0.1:#{port}",
        audio: %AudioFlow.Audio{sample_rate: 24_000, data: :binary.copy(<<1, 0>>, 24_001)}
      )

    assert_receive {:request, "/v1/sessions/token", %{"mode" => "LITE", "avatar_id" => "avatar"},
                    headers}

    assert {"x-api-key", "fixture"} in headers
    assert_receive {:request, "/v1/sessions/start", %{}, headers}
    assert {"authorization", "Bearer session-secret"} in headers
    assert_receive {:socket, socket}
    {pid, socket}
  end

  test "waits for connected, publishes provider room, sends bounded PCM chunks and commits correlated utterance" do
    {pid, socket} = publisher()
    refute_receive {:command, _}, 20
    send(socket, {:event, %{type: "session.state_updated", state: "connected"}})

    assert_receive {LiveAvatar, ^pid,
                    {:published, %{url: "wss://room.invalid", token: "viewer-secret"}}}

    assert_receive {:command, %{"type" => "agent.speak", "event_id" => id, "audio" => first}}
    assert byte_size(Base.decode64!(first)) == 48_000
    assert_receive {:command, %{"type" => "agent.speak", "event_id" => ^id, "audio" => last}}
    assert Base.decode64!(last) == <<1, 0>>
    assert_receive {:command, %{"type" => "agent.speak_end", "event_id" => ^id}}
    send(socket, {:event, %{type: "agent.speak_ended", source_event_id: "stale"}})
    refute_receive {LiveAvatar, ^pid, {:done, _}}, 20
    send(socket, {:event, %{type: "agent.speak_ended", source_event_id: id}})
    assert_receive {LiveAvatar, ^pid, {:done, :ok}}
    assert_receive {:request, "/v1/sessions/stop", %{"reason" => "USER_CLOSED"}, _}
    assert_receive {LiveAvatar, ^pid, {:cleanup, :ok}}
    assert_receive :socket_closed
  end

  test "cancel while websocket is waiting closes socket and stops remote session" do
    {pid, _} = publisher()
    assert :ok = LiveAvatar.cancel(pid)
    assert_receive :socket_closed
    assert_receive {:request, "/v1/sessions/stop", _, _}
    assert_receive {LiveAvatar, ^pid, {:cleanup, :ok}}
  end

  test "provider errors end publication and clean up" do
    {pid, socket} = publisher()
    send(socket, {:event, %{type: "error", error: %{type: "server_error"}}})
    assert_receive {LiveAvatar, ^pid, {:done, {:error, :provider_error}}}
    assert_receive :socket_closed
    assert_receive {:request, "/v1/sessions/stop", _, _}
    assert_receive {LiveAvatar, ^pid, {:cleanup, :ok}}
  end
end
