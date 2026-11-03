defmodule AvatarExample.Socket do
  @behaviour WebSock
  alias AudioFlow.Avatars.LiveAvatar

  def init(opts), do: {:ok, %{opts: opts, publisher: nil}}

  def handle_in({data, opcode: :text}, s) do
    case JSON.decode(data) do
      {:ok, %{"type" => "start", "pcm" => pcm}} when is_nil(s.publisher) ->
        start(pcm, s)

      {:ok, %{"type" => "ready"}} when is_pid(s.publisher) ->
        LiveAvatar.viewer_ready(s.publisher)
        {:ok, s}

      {:ok, %{"type" => "cancel"}} when is_nil(s.publisher) ->
        reply(%{type: "complete", message: "No active utterance"}, s)

      {:ok, %{"type" => "cancel"}} ->
        cancel(s.publisher)
        reply(%{type: "status", message: "Cancelling; awaiting provider cleanup"}, s)

      _ ->
        reply(%{type: "error", message: "Invalid command or utterance already active"}, s)
    end
  end

  def handle_in(_, s), do: reply(%{type: "error", message: "Expected JSON text"}, s)

  defp start(pcm, s) do
    with true <- Keyword.get(s.opts, :enabled, false),
         key when is_binary(key) and byte_size(key) > 0 <- s.opts[:api_key],
         avatar when is_binary(avatar) and byte_size(avatar) > 0 <- s.opts[:avatar_id],
         true <- is_binary(pcm) and byte_size(pcm) <= 640_000,
         {:ok, bytes} <- Base.decode64(pcm),
         true <- byte_size(bytes) in 2..480_000 and rem(byte_size(bytes), 2) == 0 do
      opts =
        Keyword.take(s.opts, [:api_key, :avatar_id, :endpoint]) ++
          [
            owner: self(),
            wait_for_viewer: true,
            audio: %AudioFlow.Audio{sample_rate: 24_000, data: bytes}
          ]

      case LiveAvatar.start_link(opts) do
        {:ok, pid} ->
          Process.monitor(pid)

          reply(%{type: "status", message: "Provisioning one finite utterance"}, %{
            s
            | publisher: pid
          })

        _ ->
          reply(%{type: "error", message: "Publisher could not start"}, s)
      end
    else
      _ ->
        reply(
          %{
            type: "error",
            message:
              "Live mode/config missing, or invalid PCM (mono 24 kHz s16le, 1–240000 samples)"
          },
          s
        )
    end
  end

  def handle_info({LiveAvatar, pid, {:published, publication}}, %{publisher: pid} = s) do
    if subscription_only?(publication) do
      reply(Map.merge(publication, %{type: "publication"}), s)
    else
      cancel(pid)

      reply(
        %{
          type: "error",
          message:
            "Provider credential is not a room-scoped subscription-only token; session stopped"
        },
        s
      )
    end
  end

  def handle_info({LiveAvatar, pid, {:done, result}}, %{publisher: pid} = s) do
    message =
      if result == :ok, do: "Utterance ended; cleaning up", else: "Provider failed; cleaning up"

    reply(%{type: "ended", message: message}, s)
  end

  def handle_info({LiveAvatar, pid, {:cleanup, result}}, %{publisher: pid} = s) do
    reply(
      %{
        type: "complete",
        message:
          if(result == :ok,
            do: "Session stopped. Start another bounded utterance.",
            else: "Remote stop failed; check provider dashboard."
          )
      },
      %{s | publisher: nil}
    )
  end

  def handle_info({:DOWN, _, :process, pid, _}, %{publisher: pid} = s),
    do:
      reply(%{type: "complete", message: "Publisher exited; remote cleanup not confirmed"}, %{
        s
        | publisher: nil
      })

  def handle_info(_, s), do: {:ok, s}
  def terminate(_, s), do: cancel(s.publisher)
  defp cancel(nil), do: :ok

  defp cancel(pid) do
    try do
      LiveAvatar.cancel(pid)
    catch
      :exit, _ -> :ok
    end
  end

  defp reply(event, s), do: {:push, {:text, JSON.encode!(event)}, s}

  # This is an attenuation check on a credential received directly from the
  # trusted provider, not JWT authentication. LiveKit verifies its signature.
  # Do not accept caller-supplied tokens, re-sign tokens, or expose session JWTs.
  def subscription_only?(%{url: "wss://" <> _, token: token}) do
    with [_, payload, _] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{"exp" => exp, "video" => grant} = claims} <- JSON.decode(json),
         true <- is_integer(exp) and exp > System.system_time(:second),
         %{
           "room" => room,
           "roomJoin" => true,
           "canSubscribe" => true,
           "canPublish" => false,
           "canPublishData" => false
         } <- grant do
      is_binary(room) and room != "" and
        Enum.all?(
          [
            "roomAdmin",
            "roomCreate",
            "roomList",
            "roomRecord",
            "ingressAdmin",
            "canUpdateOwnMetadata"
          ],
          &(Map.get(grant, &1, false) == false)
        ) and
        not Map.has_key?(claims, "sip")
    else
      _ -> false
    end
  end

  def subscription_only?(_), do: false
end

defmodule AvatarExample.Endpoint do
  @behaviour Plug
  import Plug.Conn
  def init(opts), do: opts

  def call(conn, opts) do
    expected = "http://127.0.0.1:#{conn.port}"

    cond do
      conn.host != "127.0.0.1" ->
        send_resp(conn, 403, "Loopback host required")

      conn.method != "GET" ->
        send_resp(conn, 405, "GET required")

      conn.request_path == "/ws" and get_req_header(conn, "origin") == [expected] ->
        conn
        |> WebSockAdapter.upgrade(AvatarExample.Socket, opts,
          max_frame_size: 650_000,
          timeout: 90_000
        )
        |> halt()

      conn.request_path == "/ws" ->
        send_resp(conn, 403, "Same-origin browser required")

      true ->
        conn = if conn.request_path == "/", do: %{conn | path_info: ["index.html"]}, else: conn

        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_header("referrer-policy", "no-referrer")
        |> Plug.Static.call(
          Plug.Static.init(
            at: "/",
            from: Keyword.get(opts, :static_dir, Path.join(__DIR__, "dist"))
          )
        )
        |> finish()
    end
  end

  defp finish(%{state: state} = conn) when state in [:sent, :file], do: conn

  defp finish(conn),
    do: send_resp(conn, 404, "Build the client: cd examples/avatar && npm ci && npm run build")
end
