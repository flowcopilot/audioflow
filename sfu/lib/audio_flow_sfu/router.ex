defmodule AudioFlowSFU.Router do
  @moduledoc "HTTP endpoint: `/ws` for the AudioFlow JSON signaling protocol."
  use Plug.Router

  alias AudioFlowSFU.Signaling
  alias AudioFlowSFU.Token

  plug :match
  plug :dispatch

  get "/ws" do
    conn = fetch_query_params(conn)
    keys = Application.fetch_env!(:audio_flow_sfu, :api_keys)

    case Token.verify(conn.query_params["access_token"] || "", keys) do
      {:ok, grants} ->
        options = %{
          grants: grants,
          ice_servers: Application.fetch_env!(:audio_flow_sfu, :ice_servers)
        }

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

  match _ do
    send_resp(conn, 404, "not found")
  end
end
