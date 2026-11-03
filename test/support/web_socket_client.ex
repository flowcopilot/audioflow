defmodule AudioFlow.Test.WebSocketClient do
  @moduledoc false
  # Minimal RFC 6455 client for tests: unfragmented frames, no extensions.

  def connect(port, path \\ "/") do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :line])
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    :ok =
      :gen_tcp.send(socket, [
        "GET #{path} HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nUpgrade: websocket\r\n",
        "Connection: Upgrade\r\nSec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
      ])

    {:ok, "HTTP/1.1 101" <> _} = :gen_tcp.recv(socket, 0, 1000)
    skip_headers(socket)
    :ok = :inet.setopts(socket, packet: :raw)
    socket
  end

  def send_binary(socket, data), do: send_frame(socket, 2, data)
  def send_json(socket, message), do: send_frame(socket, 1, JSON.encode!(message))
  def close(socket), do: send_frame(socket, 8, <<1000::16>>)

  @doc "Receive one frame. Text frames are decoded as JSON."
  def recv(socket, timeout \\ 1000) do
    with {:ok, <<_fin::1, _::3, opcode::4, 0::1, length::7>>} <- :gen_tcp.recv(socket, 2, timeout),
         {:ok, length} <- extended_length(socket, length, timeout),
         {:ok, payload} <- payload(socket, length, timeout) do
      case opcode do
        1 -> {:json, JSON.decode!(payload)}
        2 -> {:binary, payload}
        8 -> {:close, payload}
        9 -> recv(socket, timeout)
      end
    end
  end

  defp skip_headers(socket) do
    case :gen_tcp.recv(socket, 0, 1000) do
      {:ok, "\r\n"} -> :ok
      {:ok, _header} -> skip_headers(socket)
    end
  end

  defp extended_length(socket, 126, timeout) do
    with {:ok, <<length::16>>} <- :gen_tcp.recv(socket, 2, timeout), do: {:ok, length}
  end

  defp extended_length(socket, 127, timeout) do
    with {:ok, <<length::64>>} <- :gen_tcp.recv(socket, 8, timeout), do: {:ok, length}
  end

  defp extended_length(_socket, length, _timeout), do: {:ok, length}

  defp payload(_socket, 0, _timeout), do: {:ok, <<>>}
  defp payload(socket, length, timeout), do: :gen_tcp.recv(socket, length, timeout)

  defp send_frame(socket, opcode, payload) do
    mask = :crypto.strong_rand_bytes(4)
    size = byte_size(payload)

    length =
      cond do
        size < 126 -> <<1::1, size::7>>
        size < 65_536 -> <<1::1, 126::7, size::16>>
        true -> <<1::1, 127::7, size::64>>
      end

    :gen_tcp.send(socket, [<<1::1, 0::3, opcode::4>>, length, mask, mask(payload, mask)])
  end

  defp mask(payload, <<a, b, c, d>>) do
    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, i} -> Bitwise.bxor(byte, elem({a, b, c, d}, rem(i, 4))) end)
    |> :binary.list_to_bin()
  end
end
