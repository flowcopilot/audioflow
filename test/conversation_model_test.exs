if System.get_env("AUDIOFLOW_ML") == "1" do
  defmodule AudioFlow.ConversationModelTest do
    use ExUnit.Case, async: false
    @moduletag :model
    @moduletag :tmp_dir
    @moduletag timeout: 600_000

    test "one shared native model recalls a codeword from a previous session turn", %{
      tmp_dir: dir
    } do
      {:ok, serving} =
        AudioFlow.Models.language_model("Qwen/Qwen3-0.6B",
          load_options: [revision: "c1899de289a04d12100db370d81485cdf75e47ca"],
          model_options: [backend: EXLA.Backend],
          generation_options: [max_new_tokens: 64, strategy: %{type: :greedy_search}]
        )

      start_supervised!(AudioFlow.Models.child_spec(AudioFlow.ConversationLLM, serving))

      options =
        AudioFlow.Adapters.Demo.options()
        |> Keyword.put(:history, true)
        |> Keyword.put(:timeout_ms, 120_000)
        |> Keyword.put(
          :stt,
          {AudioFlow.Adapters.Function,
           run: fn audio, emit ->
             case audio.data do
               <<0, 0>> -> emit.("Remember the codeword: otter.")
               <<1, 0>> -> emit.("What is the codeword? Reply with only the codeword.")
             end
           end}
        )
        |> Keyword.put(
          :llm,
          {AudioFlow.NxAdapter,
           serving: AudioFlow.ConversationLLM,
           input: &AudioFlow.Prompt.qwen3/1,
           output: &AudioFlow.NxAdapter.sentences/1}
        )

      {:ok, session} = AudioFlow.start_session(options)
      on_exit(fn -> if Process.alive?(session), do: AudioFlow.stop_session(session) end)

      replies =
        for data <- [<<0, 0>>, <<1, 0>>] do
          {:ok, turn} =
            AudioFlow.submit(session, %AudioFlow.Audio{data: data, sample_rate: 16_000})

          collect(session, turn, [])
        end

      assert String.trim(hd(replies)) != ""
      assert List.last(replies) =~ ~r/\botter\b/i
      File.write!(Path.join(dir, "replies.json"), JSON.encode!(replies))
    end

    defp collect(session, turn, chunks) do
      receive do
        {AudioFlow, ^session, ^turn, {:text, text}} ->
          collect(session, turn, [text | chunks])

        {AudioFlow, ^session, ^turn, {:done, metrics}} ->
          assert is_integer(metrics.first_audio_us)
          chunks |> Enum.reverse() |> Enum.join("")

        {AudioFlow, ^session, ^turn, {:error, reason, _}} ->
          flunk("Conversation failed: #{inspect(reason)}")

        {AudioFlow, ^session, ^turn, _} ->
          collect(session, turn, chunks)
      after
        125_000 -> flunk("Conversation turn timed out")
      end
    end
  end
end
