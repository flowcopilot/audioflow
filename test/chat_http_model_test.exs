defmodule AudioFlow.ChatHTTPModelTest do
  use ExUnit.Case, async: false
  @moduletag :http_model
  @moduletag timeout: 120_000

  test "streamed model output matches an independent nonstreamed response through a session" do
    input = "What is 2 + 2? Reply with only the number."
    system = "You are a voice assistant. Reply in one short sentence. Use plain text."

    chat_options = [
      endpoint: System.fetch_env!("AUDIOFLOW_CHAT_ENDPOINT"),
      model: System.fetch_env!("AUDIOFLOW_LLM"),
      system: system,
      timeout_ms: 60_000,
      parameters: %{temperature: 0, max_tokens: 64}
    ]

    body =
      JSON.encode!(%{
        model: chat_options[:model],
        stream: false,
        temperature: 0,
        max_tokens: 64,
        messages: [%{role: "system", content: system}, %{role: "user", content: input}]
      })

    request =
      Finch.build(:post, chat_options[:endpoint], [{"content-type", "application/json"}], body)

    assert {:ok, %Finch.Response{status: 200, body: response}} =
             Finch.request(request, AudioFlow.HTTPClient, receive_timeout: 60_000)

    expected = JSON.decode!(response)["choices"] |> hd() |> get_in(["message", "content"])
    assert is_binary(expected) and String.trim(expected) != ""

    options =
      AudioFlow.Adapters.Demo.options()
      |> Keyword.put(
        :stt,
        {AudioFlow.Adapters.Function, run: fn _, emit -> emit.(input) end}
      )
      |> Keyword.put(:llm, {AudioFlow.Adapters.ChatHTTP, chat_options})
      |> Keyword.put(:timeout_ms, 60_000)

    {:ok, session} = AudioFlow.start_session(options)
    on_exit(fn -> if Process.alive?(session), do: AudioFlow.stop_session(session) end)
    {:ok, turn} = AudioFlow.submit(session, %AudioFlow.Audio{data: <<0, 0>>, sample_rate: 16_000})
    text = collect(session, turn, [])
    assert text == expected
  end

  defp collect(session, turn, chunks) do
    receive do
      {AudioFlow, ^session, ^turn, {:text, text}} ->
        collect(session, turn, [text | chunks])

      {AudioFlow, ^session, ^turn, {:done, metrics}} ->
        assert is_integer(metrics.first_audio_us)
        chunks |> Enum.reverse() |> Enum.join("")

      {AudioFlow, ^session, ^turn, {:error, reason, _}} ->
        flunk("HTTP model failed: #{inspect(reason)}")

      {AudioFlow, ^session, ^turn, _} ->
        collect(session, turn, chunks)
    after
      65_000 -> flunk("HTTP model did not finish")
    end
  end
end
