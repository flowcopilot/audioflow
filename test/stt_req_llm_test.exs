defmodule AudioFlow.STTReqLLMTest do
  use ExUnit.Case, async: true
  alias AudioFlow.Audio
  alias AudioFlow.Graph.Nodes.Providers
  alias AudioFlow.STT.ReqLLM, as: STT
  alias AudioFlow.Transcript.Segment

  # Records multipart (OpenAI-compatible) and raw-body (Deepgram) requests.
  defmodule Endpoint do
    @behaviour Plug
    import Plug.Conn

    def init(options), do: options

    def call(conn, %{owner: owner, status: status, body: body}) do
      conn = Plug.Conn.fetch_query_params(conn)
      auth = get_req_header(conn, "authorization")

      {params, file} =
        case get_req_header(conn, "content-type") do
          ["multipart/form-data" <> _] ->
            options = Plug.Parsers.init(parsers: [:multipart], length: 1_000_000)
            conn = Plug.Parsers.call(conn, options)
            upload = conn.params["file"]

            {Map.delete(conn.params, "file"), {upload.content_type, File.read!(upload.path)}}

          [type] ->
            {:ok, data, _} = read_body(conn)
            {conn.query_params, {type, data}}
        end

      send(owner, {:request, conn.request_path, auth, params, file})
      conn |> put_resp_content_type("application/json") |> send_resp(status, JSON.encode!(body))
    end
  end

  defp server(body, status \\ 200) do
    plug = {Endpoint, %{owner: self(), status: status, body: body}}

    server =
      start_supervised!({Bandit, plug: plug, port: 0, ip: {127, 0, 0, 1}, startup_log: false})

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    "http://127.0.0.1:#{port}"
  end

  defp run(options, audio \\ %Audio{data: <<1, 0, 2, 0>>, sample_rate: 16_000}) do
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

  test "Voxtral receives WAV, and segments: true requests and emits timed segments" do
    body = %{
      text: "Hello there. Bye.",
      segments: [
        %{text: " Hello there.", start: 0.0, end: 1.25},
        %{text: " ", start: 1.25, end: 1.3},
        %{text: "Bye.", start: 1.5, end: 2.0}
      ]
    }

    url = server(body) <> "/v1"
    options = [model: "mistral:voxtral-mini-latest", segments: true, base_url: url, api_key: "k"]
    assert {:ok, outputs} = run(options)

    assert outputs == [
             %Segment{text: "Hello there.", start_ms: 0, end_ms: 1250},
             %Segment{text: "Bye.", start_ms: 1500, end_ms: 2000}
           ]

    assert_receive {:request, "/v1/audio/transcriptions", ["Bearer k"], params, file}
    assert params["model"] == "voxtral-mini-latest"
    assert params["timestamp_granularities"] == "segment"
    assert {"audio/wav", wav} = file
    assert {:ok, %Audio{data: <<1, 0, 2, 0>>, sample_rate: 16_000}} = AudioFlow.Wav.decode(wav)
  end

  test "Mistral gets only the language when both are set, and text is emitted" do
    url = server(%{text: "Bonjour"}) <> "/v1"

    options = [
      model: "mistral:voxtral-mini-latest",
      language: "fr",
      segments: true,
      base_url: url,
      api_key: "k"
    ]

    assert {:ok, ["Bonjour"]} = run(options)
    assert_receive {:request, _, _, params, _}
    assert params["language"] == "fr"
    refute Map.has_key?(params, "timestamp_granularities")
  end

  test "Deepgram goes through the ReqLLM provider with a raw WAV body" do
    body = %{
      metadata: %{duration: 2.5},
      results: %{
        channels: [%{alternatives: [%{transcript: "hello world"}]}],
        utterances: [
          %{transcript: "hello", start: 0.25, end: 0.75},
          %{transcript: "world", start: 1.0, end: 1.5}
        ]
      }
    }

    url = server(body)

    options = [
      model: "deepgram:nova-3",
      language: "en",
      segments: true,
      base_url: url,
      api_key: "dg",
      provider_options: [smart_format: true]
    ]

    audio = %Audio{data: <<1, 0, 2, 0>>, sample_rate: 8000}
    assert {:ok, segments} = run(options, audio)

    assert segments == [
             %Segment{text: "hello", start_ms: 250, end_ms: 750},
             %Segment{text: "world", start_ms: 1000, end_ms: 1500}
           ]

    assert_receive {:request, "/v1/listen", ["Token dg"], params, {"audio/wav", wav}}

    assert params == %{
             "model" => "nova-3",
             "language" => "en",
             "smart_format" => "true",
             "utterances" => "true"
           }

    assert {:ok, %Audio{sample_rate: 8000}} = AudioFlow.Wav.decode(wav)

    url = server(%{results: %{channels: [%{alternatives: [%{transcript: "hi"}]}]}})
    assert {:ok, ["hi"]} = run(model: "deepgram:nova-3", base_url: url, api_key: fn -> "lazy" end)
    assert_receive {:request, "/v1/listen", ["Token lazy"], _, _}
  end

  test "text without segments, empty text, and HTTP failures" do
    url = server(%{text: "Hello world"}) <> "/v1"
    options = [model: "openai:whisper-1", language: "en", base_url: url, api_key: "k"]
    assert {:ok, ["Hello world"]} = run(options)
    assert_receive {:request, _, _, %{"language" => "en", "model" => "whisper-1"}, _}

    url = server(%{text: " "}) <> "/v1"
    assert {:ok, []} = run(model: "groq:whisper-large-v3-turbo", base_url: url, api_key: "k")

    url = server(%{error: %{message: "bad key"}}, 401) <> "/v1"

    assert {{:error, {:http_status, 401}}, []} =
             run(model: "openai:whisper-1", base_url: url, api_key: "k")
  end

  test "the common options are validated" do
    assert_raise NimbleOptions.ValidationError, fn ->
      run(model: "openai:whisper-1", segments: "yes")
    end

    assert_raise NimbleOptions.ValidationError, fn -> run(language: "en") end
  end

  test "remote STT graph nodes use a fixed provider and the server key" do
    for {type, provider} <- [{"mistral.stt", :mistral}, {"deepgram.stt", :deepgram}] do
      assert Enum.any?(Providers.nodes(), &(&1.type == type))

      assert {STT, options} =
               Providers.adapter(type, %{
                 model: "m",
                 language: "en",
                 timeout_ms: 5000
               })

      assert options[:model] == %{provider: provider, id: "m"}
      assert options[:receive_timeout] == 5000
      refute Keyword.has_key?(options, :api_key)
    end
  end

  test "a transcription session runs with this adapter" do
    url = server(%{text: "Hello from Voxtral"}) <> "/v1"
    options = [model: "mistral:voxtral-mini-latest", base_url: url, api_key: "k"]
    {:ok, session} = AudioFlow.start_session(stt: {STT, options})
    {:ok, turn} = AudioFlow.submit(session, %Audio{data: <<1, 0>>, sample_rate: 16_000})
    assert_receive {AudioFlow, ^session, ^turn, {:transcript, "Hello from Voxtral"}}, 5000
    assert_receive {AudioFlow, ^session, ^turn, {:done, _}}
  end
end
