defmodule AudioFlowUIWeb.MCPToken do
  @moduledoc """
  Requires `Authorization: Bearer <token>` on the MCP endpoint when
  `config :audio_flow_ui, :mcp_token` is set (`AUDIOFLOW_UI_TOKEN`).
  Without a token, any local process can call the endpoint.
  """
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(options), do: options

  @impl true
  def call(conn, _options) do
    with token when is_binary(token) <- Application.get_env(:audio_flow_ui, :mcp_token),
         false <- authorized?(conn, token) do
      conn
      |> put_resp_header("www-authenticate", ~s(Bearer realm="audioflow"))
      |> send_resp(401, "")
      |> halt()
    else
      _ -> conn
    end
  end

  defp authorized?(conn, token) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> given] -> Plug.Crypto.secure_compare(given, token)
      _ -> false
    end
  end
end
