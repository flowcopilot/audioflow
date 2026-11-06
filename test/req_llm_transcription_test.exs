defmodule AudioFlow.ReqLLMTranscriptionTest do
  use ExUnit.Case, async: true
  alias AudioFlow.Adapters.ReqLLMTranscription, as: STT
  alias AudioFlow.Audio
  alias AudioFlow.Transcript.Segment

  defmodule Endpoint do
    @behaviour Plug
    import Plug.Conn

    def init(options), do: options

    def call(conn, %{owner: owner, status: status, body: body}) do
      options = Plug.Parsers.init(parsers: [:multipart], length: 1_000_000)
      conn = Plug.Parsers.call(conn, options)
      %Plug.Upload{} = upload = conn.params["file"]

      send(owner, {
        :request,
        conn.request_path,
        get_req_header(conn, "authorization"),
        Map.delete(conn.params, "file"),
        {upload.content_type, File.read!(upload.path)}
      })

      conn |> put_resp_content_type("application/json") |> send_resp(status, JSON.encode!(body))
    end
  end

  defp server(body, status \\ 200) do
    plug = {Endpoint, %{owner: self(), status: status, body: body}}

    server =
      start_supervised!({Bandit, plug: plug, port: 0, ip: {127, 0, 0, 1}, startup_log: false})

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    [base_url: "http://127.0.0.1:#{port}/v1", api_key: "test-key"]
  end

  defp run(options) do
    audio = %Audio{data: <<1, 0, 2, 0>>, sample_rate: 16_000}
    owner = self()

    result =
      STT.run(audio, options, fn value ->
        send(owner, {:output, value})
        :ok
      end)

    {result, collect([])}
  end

  defp collect(acc) do
    receive do
      {:output, value} -> collect([value | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "Voxtral receives WAV and provider options, and timed segments are emitted" do
    body = %{
      model: "voxtral-mini-latest",
      text: "Hello there. Bye.",
      segments: [
        %{text: " Hello there.", start: 0.0, end: 1.25},
        %{text: " ", start: 1.25, end: 1.3},
        %{text: "Bye.", start: 1.5, end: 2.0}
      ]
    }

    options =
      server(body) ++
        [
          model: "mistral:voxtral-mini-latest",
          segments: true,
          provider_options: [timestamp_granularities: "segment"]
        ]

    assert {:ok, outputs} = run(options)

    assert outputs == [
             %Segment{text: "Hello there.", start_ms: 0, end_ms: 1250},
             %Segment{text: "Bye.", start_ms: 1500, end_ms: 2000}
           ]

    assert_receive {:request, "/v1/audio/transcriptions", ["Bearer test-key"], params, file}
    assert params["model"] == "voxtral-mini-latest"
    assert params["timestamp_granularities"] == "segment"
    assert params["max_retries"] == nil

    assert {:ok, %Audio{data: <<1, 0, 2, 0>>, sample_rate: 16_000}} =
             AudioFlow.Wav.decode(elem(file, 1))

    assert elem(file, 0) == "audio/wav"
  end

  test "text is emitted without segments, and empty text emits nothing" do
    options = server(%{text: "Hello world"}) ++ [model: "openai:whisper-1", language: "en"]
    assert {:ok, ["Hello world"]} = run(options)
    assert_receive {:request, _, _, %{"language" => "en", "model" => "whisper-1"}, _}

    options = server(%{text: " "}) ++ [model: "groq:whisper-large-v3-turbo"]
    assert {:ok, []} = run(options)
  end

  test "an HTTP failure fails the turn without output" do
    options = server(%{error: %{message: "bad key"}}, 401) ++ [model: "openai:whisper-1"]
    assert {{:error, {:http_status, 401}}, []} = run(options)
  end

  test "a transcription session runs with this adapter" do
    options = server(%{text: "Hello from Voxtral"}) ++ [model: "mistral:voxtral-mini-latest"]
    {:ok, session} = AudioFlow.start_session(stt: {STT, options})
    {:ok, turn} = AudioFlow.submit(session, %Audio{data: <<1, 0>>, sample_rate: 16_000})
    assert_receive {AudioFlow, ^session, ^turn, {:transcript, "Hello from Voxtral"}}, 5000
    assert_receive {AudioFlow, ^session, ^turn, {:done, _}}
  end
end
