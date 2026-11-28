defmodule AudioFlow.SessionOptionsTest do
  use ExUnit.Case, async: true
  alias AudioFlow.Adapters.Demo
  alias AudioFlow.Session.Options

  test "an unknown or misspelled option raises before a session starts" do
    before = DynamicSupervisor.count_children(AudioFlow.Sessions).active

    assert_raise ArgumentError, ~r/unknown options \[:timeout_msec\]/, fn ->
      AudioFlow.start_session(Keyword.put(Demo.options(), :timeout_msec, 10))
    end

    assert DynamicSupervisor.count_children(AudioFlow.Sessions).active == before
  end

  test "an invalid option value raises with the option name" do
    assert_raise ArgumentError, ~r/:timeout_ms/, fn ->
      AudioFlow.start_session(Keyword.put(Demo.options(), :timeout_ms, 0))
    end

    assert_raise ArgumentError, ~r/:notify_audio/, fn ->
      AudioFlow.start_session(Keyword.put(Demo.options(), :notify_audio, "no"))
    end

    assert_raise ArgumentError, ~r/:stt/, fn ->
      AudioFlow.start_session(stt: AudioFlow.Adapters.Demo)
    end
  end

  test "valid options, a nil output and an explicit owner start a session" do
    options = Keyword.merge(Demo.options(), owner: self(), output: nil, history: [max_turns: 2])
    assert {:ok, session} = AudioFlow.start_session(options)
    assert :ok = AudioFlow.stop_session(session)
  end

  test "the generated docs name every option" do
    docs = Options.docs()

    for {key, _} <- Options.schema() do
      assert docs =~ ":#{key}"
    end
  end
end
