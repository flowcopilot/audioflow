defmodule AudioFlow.RecordingRuntimeTest do
  use ExUnit.Case, async: true
  alias AudioFlow.Adapters.Demo
  alias AudioFlow.Audio
  alias AudioFlow.Privacy
  alias AudioFlow.Recording
  alias AudioFlow.Recording.Store

  test "owner consumes actual session success, failure and cancellation events" do
    root =
      Path.join(
        System.tmp_dir!(),
        "audioflow-runtime-recorder-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, store} = Store.new(root)
    parent = self()

    for mode <- [:success, :failure, :cancel] do
      options =
        Demo.options()
        |> Keyword.put(
          :llm,
          {AudioFlow.Adapters.Function,
           run: fn _, emit ->
             emit.("alice@")
             emit.("example.com")

             case mode do
               :success ->
                 :ok

               :failure ->
                 {:error, "private failure"}

               :cancel ->
                 send(parent, {:blocked, self()})
                 receive do: (:continue -> :ok)
             end
           end}
        )

      {:ok, session} = AudioFlow.start_session(options)

      recorder =
        Recording.new(session, store,
          redactor: Privacy.rules([{~r/alice@example\.com/, "[EMAIL]"}])
        )

      {:ok, turn} = AudioFlow.submit(session, %Audio{data: <<0, 0>>, sample_rate: 8000})

      if mode == :cancel do
        assert_receive {:blocked, _}
        assert :ok = AudioFlow.cancel(session)
      end

      id = collect(recorder, session, turn)
      {:ok, artifact} = Store.read(store, id)
      expected = %{success: "done", failure: "error", cancel: "cancelled"}[mode]
      assert artifact["status"] == expected
      assert Enum.find(artifact["streams"], &(&1["kind"] == "text"))["text"] == "[EMAIL]"
      refute File.read!(Path.join(root, id)) =~ "alice"
      refute File.read!(Path.join(root, id)) =~ "private failure"
      AudioFlow.stop_session(session)
    end
  end

  defp collect(recorder, session, turn) do
    receive do
      {AudioFlow, ^session, ^turn, _} = message ->
        case Recording.consume(recorder, message) do
          {:ok, next, nil} -> collect(next, session, turn)
          {:ok, _, id} -> id
          error -> flunk("recording failed: #{inspect(error)}")
        end
    after
      2000 -> flunk("session did not terminate its turn")
    end
  end
end
