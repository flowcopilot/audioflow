defmodule AudioFlowSFU.Router do
  @moduledoc """
  HTTP endpoint: `/ws` for the AudioFlow JSON signaling protocol, and
  `/rtc/v1` for LiveKit client SDKs.
  """
  use Plug.Router

  alias AudioFlowSFU.LiveKit
  alias AudioFlowSFU.Signaling
  alias AudioFlowSFU.Token

  plug :match
  plug :dispatch

  get "/ws" do
    conn = fetch_query_params(conn)

    case verify(conn) do
      {:ok, grants} ->
        options = %{
          grants: grants,
          ice_servers: Application.fetch_env!(:audio_flow_sfu, :ice_servers)
        }

        options =
          case conn.query_params["resume"] do
            token when is_binary(token) and token != "" -> Map.put(options, :resume, token)
            _ -> options
          end

        conn
        |> WebSockAdapter.upgrade(Signaling.JSON, options,
          timeout: 60_000,
          max_frame_size: 131_072
        )
        |> halt()

      {:error, reason} ->
        send_resp(conn, 401, Atom.to_string(reason))
    end
  end

  # LiveKit client protocol v1. Clients fall back to /rtc (two peer
  # connections) on a 404 from /rtc/v1; that path is not supported.
  get "/rtc/v1" do
    conn = fetch_query_params(conn)

    with {:ok, grants} <- verify(conn),
         {:ok, join} <- LiveKit.decode_join_request(conn.query_params["join_request"]) do
      options = %{
        grants: grants,
        join: join,
        ice_servers: Application.fetch_env!(:audio_flow_sfu, :ice_servers)
      }

      conn
      |> WebSockAdapter.upgrade(Signaling.LiveKit, options,
        timeout: 60_000,
        max_frame_size: 262_144
      )
      |> halt()
    else
      {:error, :invalid_join_request} -> send_resp(conn, 400, "invalid join request")
      {:error, reason} -> send_resp(conn, 401, Atom.to_string(reason))
    end
  end

  # The client calls this after a failed connection to learn why.
  get "/rtc/v1/validate" do
    conn = fetch_query_params(conn)

    case verify(conn) do
      {:ok, _} -> send_resp(conn, 200, "success")
      {:error, reason} -> send_resp(conn, 401, Atom.to_string(reason))
    end
  end

  # Browsers pass the token as `access_token`; the Rust-based SDKs send an
  # `Authorization: Bearer` header.
  defp verify(conn) do
    keys = Application.fetch_env!(:audio_flow_sfu, :api_keys)

    token =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token | _] -> token
        _ -> conn.query_params["access_token"] || ""
      end

    Token.verify(token, keys)
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
