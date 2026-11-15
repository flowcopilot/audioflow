defmodule AudioFlow.Adapters.Providers.PCMHTTP do
  @moduledoc false
  alias AudioFlow.Adapters.Providers.Socket

  def run(endpoint, headers, body, rate, options, emit, format \\ :pcm) do
    validate_endpoint!(endpoint)
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
        emit: emit,
        format: format,
        audio_bytes: 0
      }

      request =
        Finch.build(:post, endpoint, [{"content-type", "application/json"} | headers], body)

      request
      |> Finch.stream_while(AudioFlow.HTTPClient, state, &receive_http/2,
        receive_timeout: receive_timeout,
        request_timeout: timeout
      )
      |> stream_result()
    end
  end

  defp validate_endpoint!(endpoint) do
    uri = URI.parse(endpoint)

    unless (uri.scheme in ["http", "https"] and uri.host) && is_nil(uri.userinfo),
      do: raise(ArgumentError, "expected HTTP(S) endpoint without user information")
  end

  defp stream_result({:ok, %{error: error}}) when error != nil, do: {:error, error}

  defp stream_result({:ok, %{format: :wav}}), do: {:error, :invalid_wav}

  defp stream_result({:ok, %{pending: pending}}) when pending != "",
    do: {:error, :incomplete_sample}

  defp stream_result({:ok, %{audio_bytes: 0}}), do: {:error, :empty_response}
  defp stream_result({:ok, _}), do: :ok
  defp stream_result({:error, _, _}), do: {:error, :http_stream_failed}

  defp receive_http({:status, 200}, state), do: {:cont, %{state | status: 200}}

  defp receive_http({:status, status}, state),
    do: {:halt, %{state | error: {:http_status, status}}}

  defp receive_http({:headers, headers}, state) do
    type =
      Enum.find_value(headers, "", fn {k, v} -> if String.downcase(k) == "content-type", do: v end)

    type = type |> String.split(";") |> hd() |> String.trim() |> String.downcase()

    types =
      if state.format == :wav,
        do: ["audio/wav", "audio/x-wav", "audio/wave"],
        else: ["application/octet-stream", "audio/pcm", "audio/raw", "audio/x-raw"]

    if type in types,
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
        receive_audio(state.pending <> chunk, %{state | bytes: bytes, pending: ""})
    end
  end

  defp receive_http({:trailers, _}, state), do: {:cont, state}

  # Fish Speech uses a canonical 44-byte streaming WAV header. Both older zero
  # sizes and the current 0xFFFFFFFF sentinel mean PCM until HTTP EOF.
  defp receive_audio(data, %{format: :wav} = state) when byte_size(data) < 44,
    do: {:cont, %{state | pending: data}}

  defp receive_audio(
         <<"RIFF", riff_size::little-32, "WAVEfmt ", 16::little-32, 1::little-16, 1::little-16,
           rate::little-32, byte_rate::little-32, 2::little-16, 16::little-16, "data",
           data_size::little-32, pcm::binary>>,
         %{format: :wav} = state
       )
       when rate > 0 and byte_rate == rate * 2 and riff_size in [36, 0xFFFFFFFF] and
              data_size in [0, 0xFFFFFFFF] do
    receive_audio(pcm, %{state | format: :pcm, rate: rate})
  end

  defp receive_audio(_, %{format: :wav} = state),
    do: {:halt, %{state | error: :unsupported_wav}}

  defp receive_audio(data, state) do
    size = byte_size(data) - rem(byte_size(data), 2)
    <<pcm::binary-size(^size), pending::binary>> = data
    if size > 0, do: :ok = state.emit.(%AudioFlow.Audio{data: pcm, sample_rate: state.rate})
    {:cont, %{state | pending: pending, audio_bytes: state.audio_bytes + size}}
  end
end
