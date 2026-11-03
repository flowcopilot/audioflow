defmodule AudioFlow.RTVISamplePlug do
  def init(options), do: options

  def call(conn, _) do
    WebSockAdapter.upgrade(
      conn,
      AudioFlow.RTVI.WebSocket,
      [session: AudioFlow.Adapters.Demo.options()],
      timeout: 60_000
    )
    |> Plug.Conn.halt()
  end
end

{:ok, server} = Bandit.start_link(plug: AudioFlow.RTVISamplePlug, port: 0, ip: {127, 0, 0, 1})
{:ok, {_, port}} = ThousandIsland.listener_info(server)
IO.puts("RTVI_PORT=#{port}")
Process.sleep(:infinity)
