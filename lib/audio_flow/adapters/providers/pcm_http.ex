defmodule AudioFlow.Adapters.Providers.PCMHTTP do
  @moduledoc false
  alias AudioFlow.Adapters.Providers.Socket

  def run(endpoint, headers, body, rate, options, emit) do
    uri = URI.parse(endpoint)

    unless (uri.scheme in ["http", "https"] and uri.host) && is_nil(uri.userinfo),
      do: raise(ArgumentError, "expected HTTP(S) endpoint without user information")

    body = JSON.encode!(body)

    limit = Socket.positive!(options, :max_response_bytes, 16_777_216)
    timeout = Socket.positive!(options, :timeout_ms, 30_000)
    receive_timeout = Socket.positive!(options, :receive_timeout_ms, 10_000)

    if byte_size(body) > Socket.positive!(options, :max_request_bytes, 65_536) do
      {:error, :request_too_large}
    else
      state = %{
        status: nil,
        type: false,
        pending: "",
        bytes: 0,
        error: nil,
        limit: limit,
        rate: rate,
        emit: emit
      }

      request =
        Finch.build(:post, endpoint, [{"content-type", "application/json"} | headers], body)

      case Finch.stream_while(request, AudioFlow.HTTPClient, state, &receive_http/2,
             receive_timeout: receive_timeout,
             request_timeout: timeout
           ) do
        {:ok, %{error: error}} when error != nil -> {:error, error}
        {:ok, %{pending: pending}} when pending != "" -> {:error, :incomplete_sample}
        {:ok, %{bytes: 0}} -> {:error, :empty_response}
        {:ok, _} -> :ok
        {:error, _, _} -> {:error, :http_stream_failed}
      end
    end
  end

  defp receive_http({:status, 200}, state), do: {:cont, %{state | status: 200}}

  defp receive_http({:status, status}, state),
    do: {:halt, %{state | error: {:http_status, status}}}

  defp receive_http({:headers, headers}, state) do
    type =
      Enum.find_value(headers, "", fn {k, v} -> if String.downcase(k) == "content-type", do: v end)

    type = type |> String.split(";") |> hd() |> String.trim() |> String.downcase()

    if type in ["application/octet-stream", "audio/pcm", "audio/raw", "audio/x-raw"],
      do: {:cont, %{state | type: true}},
      else: {:halt, %{state | error: :invalid_content_type}}
  end

  defp receive_http({:data, chunk}, state) do
    bytes = state.bytes + byte_size(chunk)

    cond do
      not state.type ->
        {:halt, %{state | error: :invalid_content_type}}

      bytes > state.limit ->
        {:halt, %{state | error: :response_too_large}}

      true ->
        data = state.pending <> chunk
        size = byte_size(data) - rem(byte_size(data), 2)
        <<pcm::binary-size(^size), pending::binary>> = data
        if size > 0, do: :ok = state.emit.(%AudioFlow.Audio{data: pcm, sample_rate: state.rate})
        {:cont, %{state | pending: pending, bytes: bytes}}
    end
  end

  defp receive_http({:trailers, _}, state), do: {:cont, state}
end
