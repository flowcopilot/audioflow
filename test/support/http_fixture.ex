defmodule AudioFlow.Test.HTTPFixture do
  def start(owner, handler) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {_, port}} = :inet.sockname(listener)

    child = %{
      id: make_ref(),
      start: {Task, :start_link, [fn -> accept(listener, owner, handler) end]}
    }

    {child, listener, "http://127.0.0.1:#{port}/v1/chat/completions"}
  end

  defp accept(listener, owner, handler) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        request = read_request(socket, "")
        send(owner, {:http_request, self(), request})
        handler.(socket, request)
        :gen_tcp.close(socket)
        accept(listener, owner, handler)

      {:error, :closed} ->
        :ok
    end
  end

  defp read_request(socket, bytes) do
    case :binary.split(bytes, "\r\n\r\n") do
      [head, body] ->
        [request | headers] = String.split(head, "\r\n")

        headers =
          Map.new(headers, fn header ->
            [key, value] = String.split(header, ":", parts: 2)
            {String.downcase(key), String.trim(value)}
          end)

        size = String.to_integer(Map.fetch!(headers, "content-length"))
        %{line: request, headers: headers, body: read_body(socket, body, size)}

      [_] ->
        {:ok, chunk} = :gen_tcp.recv(socket, 0, 5_000)
        read_request(socket, bytes <> chunk)
    end
  end

  defp read_body(_, bytes, size) when byte_size(bytes) >= size, do: JSON.decode!(bytes)

  defp read_body(socket, bytes, size) do
    {:ok, chunk} = :gen_tcp.recv(socket, 0, 5_000)
    read_body(socket, bytes <> chunk, size)
  end

  def headers(socket, status \\ 200, extra \\ []) do
    :gen_tcp.send(socket, [
      "HTTP/1.1 #{status} Response\r\n",
      "Content-Type: text/event-stream; charset=utf-8\r\nTransfer-Encoding: chunked\r\n",
      Enum.map(extra, fn {key, value} -> "#{key}: #{value}\r\n" end),
      "\r\n"
    ])
  end

  def chunk(socket, data),
    do: :gen_tcp.send(socket, [Integer.to_string(byte_size(data), 16), "\r\n", data, "\r\n"])

  def finish(socket), do: :gen_tcp.send(socket, "0\r\n\r\n")

  def event(content, finish_reason \\ nil),
    do:
      "data: " <>
        JSON.encode!(%{
          choices: [%{index: 0, delta: %{content: content}, finish_reason: finish_reason}]
        }) <> "\n\n"

  def done, do: "data: [DONE]\n\n"
end
