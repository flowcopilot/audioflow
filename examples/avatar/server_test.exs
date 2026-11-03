Code.require_file("server.ex", __DIR__)

defmodule AvatarExampleTest do
  use ExUnit.Case, async: true
  alias AvatarExample.Socket
  alias AudioFlow.Avatars.LiveAvatar

  defmodule Media do
    @behaviour WebSock
    def init(owner), do: {:ok, owner}

    def handle_in({data, opcode: :text}, owner) do
      send(owner, {:command, JSON.decode!(data)})
      {:ok, owner}
    end

    def handle_info(event, s), do: {:push, {:text, JSON.encode!(event)}, s}
    def terminate(_, owner), do: send(owner, :media_closed)
  end

  defmodule Provider do
    import Plug.Conn
    def init(opts), do: opts

    def call(%{request_path: "/ws"} = conn, {owner, _}) do
      send(owner, {:media, self()})
      conn |> WebSockAdapter.upgrade(Media, owner, []) |> halt()
    end

    def call(conn, {owner, token}) do
      send(owner, {:request, conn.request_path, conn.req_headers})

      result =
        case conn.request_path do
          "/v1/sessions/token" ->
            %{session_token: "server-only-bearer"}

          "/v1/sessions/start" ->
            %{
              ws_url: "ws://127.0.0.1:#{conn.port}/ws",
              livekit_url: "wss://room.invalid",
              livekit_client_token: token
            }

          "/v1/sessions/stop" ->
            nil
        end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, JSON.encode!(%{code: 100, data: result}))
    end
  end

  defp token(overrides \\ %{}) do
    grant =
      Map.merge(
        %{
          room: "fixture-room",
          roomJoin: true,
          canSubscribe: true,
          canPublish: false,
          canPublishData: false
        },
        overrides
      )

    "header." <>
      Base.url_encode64(JSON.encode!(%{exp: System.system_time(:second) + 60, video: grant}),
        padding: false
      ) <> ".signature"
  end

  defp fixture(viewer_token) do
    server =
      start_supervised!(
        {Bandit,
         plug: {Provider, {self(), viewer_token}}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    {:ok, s} =
      Socket.init(
        enabled: true,
        api_key: "server-api-key",
        avatar_id: "fixture",
        endpoint: "http://127.0.0.1:#{port}"
      )

    {:push, _, s} =
      Socket.handle_in(
        {JSON.encode!(%{type: "start", pcm: Base.encode64(<<1, 0, 2, 0>>)}), opcode: :text},
        s
      )

    assert_receive {:request, "/v1/sessions/token", headers}
    assert {"x-api-key", "server-api-key"} in headers
    assert_receive {:request, "/v1/sessions/start", headers}
    assert {"authorization", "Bearer server-only-bearer"} in headers
    assert_receive {:media, media}
    send(media, %{type: "session.state_updated", state: "connected"})
    {s, media}
  end

  test "actual publisher routes only subscription credentials; PCM waits for viewer; cancel cleans up; repeat is explicit" do
    viewer_token = token()
    {s, _} = fixture(viewer_token)
    pid = s.publisher
    assert_receive {LiveAvatar, ^pid, {:published, _}} = event
    {:push, {:text, response}, s} = Socket.handle_info(event, s)

    assert JSON.decode!(response) == %{
             "type" => "publication",
             "url" => "wss://room.invalid",
             "token" => viewer_token
           }

    refute response =~ "server-only"
    refute response =~ "server-api"
    refute_receive {:command, _}, 30
    {:ok, s} = Socket.handle_in({~s({"type":"ready"}), opcode: :text}, s)
    assert_receive {:command, %{"type" => "agent.speak", "audio" => pcm}}
    assert Base.decode64!(pcm) == <<1, 0, 2, 0>>
    assert_receive {:command, %{"type" => "agent.speak_end"}}
    {:push, _, s} = Socket.handle_in({~s({"type":"cancel"}), opcode: :text}, s)
    assert_receive {:request, "/v1/sessions/stop", _}
    assert_receive :media_closed
    assert_receive {LiveAvatar, ^pid, {:cleanup, :ok}} = cleanup
    {:push, _, s} = Socket.handle_info(cleanup, s)
    assert s.publisher == nil

    assert {:push, _, %{publisher: next}} =
             Socket.handle_in({JSON.encode!(%{type: "start", pcm: "AQA="}), opcode: :text}, s)

    assert is_pid(next) and next != pid
    Socket.terminate(:normal, %{s | publisher: next})
  end

  test "broader credentials are withheld and provider stopped" do
    {s, _} = fixture(token(%{canPublish: true}))
    pid = s.publisher
    assert_receive {LiveAvatar, ^pid, {:published, _}} = event
    {:push, {:text, response}, _} = Socket.handle_info(event, s)
    assert JSON.decode!(response)["type"] == "error"
    refute response =~ "signature"
    assert_receive {:request, "/v1/sessions/stop", _}
  end

  test "disconnect stops the actual provider publisher" do
    {s, _} = fixture(token())
    Socket.terminate(:normal, s)
    assert_receive {:request, "/v1/sessions/stop", _}
    assert_receive :media_closed
    refute Process.alive?(s.publisher)
  end

  test "default disabled, malformed and oversized input never provision" do
    {:ok, s} = Socket.init([])

    for pcm <- ["AQA=", "bad", Base.encode64(:binary.copy(<<0>>, 480_002))] do
      assert {:push, {:text, response}, ^s} =
               Socket.handle_in({JSON.encode!(%{type: "start", pcm: pcm}), opcode: :text}, s)

      assert JSON.decode!(response)["type"] == "error"
    end

    refute_receive {:request, _, _}
    refute Socket.subscription_only?(%{url: "wss://test", token: token(%{roomAdmin: true})})
    refute Socket.subscription_only?(%{url: "wss://test", token: "bad"})
  end

  test "loopback host and exact browser origin required" do
    for {host, origin} <- [
          {"evil.test", "http://127.0.0.1"},
          {"127.0.0.1", "http://evil.test"},
          {"127.0.0.1", ""}
        ] do
      conn =
        Plug.Test.conn(:get, "http://#{host}/ws") |> Plug.Conn.put_req_header("origin", origin)

      assert AvatarExample.Endpoint.call(conn, []).status == 403
    end
  end

  test "natural completion routes done and cleanup separately" do
    {s, media} = fixture(token())
    pid = s.publisher
    assert_receive {LiveAvatar, ^pid, {:published, _}}
    {:ok, s} = Socket.handle_in({~s({"type":"ready"}), opcode: :text}, s)
    assert_receive {:command, %{"type" => "agent.speak_end", "event_id" => id}}
    send(media, %{type: "agent.speak_ended", source_event_id: id})
    assert_receive {LiveAvatar, ^pid, {:done, :ok}} = done
    assert {:push, {:text, json}, _} = Socket.handle_info(done, s)
    assert JSON.decode!(json)["type"] == "ended"
    assert_receive {LiveAvatar, ^pid, {:cleanup, :ok}} = cleanup
    assert {:push, _, %{publisher: nil}} = Socket.handle_info(cleanup, s)
  end

  test "root serves index and static assets; missing build returns useful error" do
    conn = Plug.Test.conn(:get, "http://127.0.0.1/")
    response = AvatarExample.Endpoint.call(conn, static_dir: __DIR__)
    assert response.status == 200
    assert response.resp_body =~ "LiveAvatar finite utterance viewer"

    response =
      AvatarExample.Endpoint.call(Plug.Test.conn(:get, "http://127.0.0.1/main.ts"),
        static_dir: __DIR__
      )

    assert response.status == 200
    response = AvatarExample.Endpoint.call(conn, static_dir: "/tmp/avatar-no-such-build")
    assert response.status == 404
    assert response.resp_body =~ "Build the client"
  end

  test "missing viewer readiness times out without sending PCM and cleans up" do
    {s, _} = fixture(token())
    pid = s.publisher
    assert_receive {LiveAvatar, ^pid, {:published, _}}
    assert_receive {LiveAvatar, ^pid, {:done, {:error, :viewer_timeout}}}, 16_000
    refute_receive {:command, _}, 10
    assert_receive {:request, "/v1/sessions/stop", _}
    assert_receive :media_closed
  end

  test "enabled configuration still rejects malformed audio before HTTP" do
    {:ok, s} = Socket.init(enabled: true, api_key: "fixture", avatar_id: "fixture")

    for pcm <- ["", "bad", "AA==", Base.encode64(:binary.copy(<<0>>, 480_002))] do
      assert {:push, {:text, json}, ^s} =
               Socket.handle_in({JSON.encode!(%{type: "start", pcm: pcm}), opcode: :text}, s)

      assert JSON.decode!(json)["type"] == "error"
    end

    refute_receive {:request, _, _}

    assert {:push, {:text, json}, ^s} =
             Socket.handle_in({~s({"type":"cancel"}), opcode: :text}, s)

    assert JSON.decode!(json)["type"] == "complete"
  end
end
