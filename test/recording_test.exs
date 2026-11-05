defmodule AudioFlow.RecordingTest do
  use ExUnit.Case, async: true
  alias AudioFlow.Audio
  alias AudioFlow.Privacy
  alias AudioFlow.Recording
  alias AudioFlow.Recording.Store

  setup do
    root =
      Path.join(System.tmp_dir!(), "audioflow-recording-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, store} = Store.new(root)

    recorder =
      Recording.new(self(), store, redactor: Privacy.rules([{~r/alice@example\.com/, "[EMAIL]"}]))

    %{store: store, recorder: recorder, turn: make_ref(), root: root}
  end

  defp emit(recorder, turn, event),
    do: Recording.consume(recorder, {AudioFlow, self(), turn, event})

  test "redacts whole streams before disk, preserving event order and real PCM", ctx do
    recorder = %{ctx.recorder | audio: true}
    {:ok, recorder, nil} = emit(recorder, ctx.turn, {:transcript, "alice@"})

    {:ok, recorder, nil} =
      emit(recorder, ctx.turn, {:audio, %Audio{data: <<0, 1>>, sample_rate: 8000}, :speaker})

    {:ok, recorder, nil} = emit(recorder, ctx.turn, {:transcript, "example.com"})
    assert {:ok, recorder, id} = emit(recorder, ctx.turn, {:done, %{}})
    assert {:ok, record} = Store.read(ctx.store, id)
    assert record["streams"] == [%{"kind" => "transcript", "node" => nil, "text" => "[EMAIL]"}]
    assert Enum.map(record["events"], & &1["kind"]) == ["transcript", "audio", "transcript"]
    assert Enum.map(record["events"], & &1["sequence"]) == [0, 1, 2]
    assert Enum.at(record["events"], 1)["pcm_s16le"] == Base.encode64(<<0, 1>>)
    refute File.read!(Path.join(ctx.root, id)) =~ "alice"
    assert {:ok, ^recorder, nil} = emit(recorder, ctx.turn, {:done, %{}})
    assert {:ok, [^id]} = Store.list(ctx.store)
  end

  test "default drops audio, images and error reasons; cancellation and failure save partial text",
       ctx do
    for terminal <- [{:cancelled, %{}}, {:error, "secret reason", %{}}] do
      turn = make_ref()
      {:ok, recorder, nil} = emit(ctx.recorder, turn, {:text, "hello"})

      {:ok, recorder, nil} =
        emit(recorder, turn, {:audio, %Audio{data: <<0, 0>>, sample_rate: 8000}})

      {:ok, _, id} = emit(recorder, turn, terminal)
      {:ok, record} = Store.read(ctx.store, id)
      assert [_] = record["events"]
      assert record["status"] in ["cancelled", "error"]
      refute File.read!(Path.join(ctx.root, id)) =~ "secret"
    end
  end

  test "redactor failures never persist raw text", ctx do
    for redactor <- [
          fn _ -> raise "secret" end,
          fn _ -> throw("secret") end,
          fn _ -> {:error, "secret"} end,
          fn _ -> {:ok, <<255>>} end
        ] do
      recorder = %{ctx.recorder | redactor: redactor}
      {:ok, recorder, nil} = emit(recorder, ctx.turn, {:text, "alice@example.com"})
      assert {:error, :redaction_failed, reset} = emit(recorder, ctx.turn, {:done, %{}})
      assert reset.events == []
      assert {:ok, []} = Store.list(ctx.store)
    end
  end

  test "UTF-8 characters may span chunks, but invalid final text fails closed", ctx do
    recorder = %{ctx.recorder | redactor: &{:ok, &1}}
    {:ok, recorder, nil} = emit(recorder, ctx.turn, {:text, <<0xC3>>})
    {:ok, recorder, nil} = emit(recorder, ctx.turn, {:text, <<0xA9>>})
    assert {:ok, _, id} = emit(recorder, ctx.turn, {:done, %{}})
    {:ok, record} = Store.read(ctx.store, id)
    assert hd(record["streams"])["text"] == "é"
    {:ok, recorder, nil} = emit(ctx.recorder, ctx.turn, {:text, <<255>>})
    assert {:error, :redaction_failed, _} = emit(recorder, ctx.turn, {:done, %{}})
  end

  test "limits discard the entire turn and recover for next turn", ctx do
    for recorder <- [%{ctx.recorder | max_events: 1}, %{ctx.recorder | max_bytes: 80}] do
      {:ok, recorder, nil} = emit(recorder, ctx.turn, {:text, "ok"})

      assert {:error, reason, recorder} =
               emit(recorder, ctx.turn, {:text, String.duplicate("x", 100)})

      assert reason in [:byte_limit, :event_limit]
      assert recorder.events == []
      assert {:error, ^reason, recorder} = emit(recorder, ctx.turn, {:done, %{}})
      assert {:ok, []} = Store.list(ctx.store)
      assert {:ok, _, _} = emit(recorder, make_ref(), {:done, %{}})
      {:ok, ids} = Store.list(ctx.store)
      for id <- ids, do: Store.delete(ctx.store, id)
    end
  end

  test "discard, foreign messages, overlapping turns and write failures", ctx do
    assert {:ok, recorder, nil} =
             Recording.consume(
               ctx.recorder,
               {AudioFlow, spawn(fn -> :ok end), ctx.turn, {:text, "foreign"}}
             )

    assert recorder == ctx.recorder
    {:ok, recorder, nil} = emit(recorder, ctx.turn, {:text, "pending"})
    assert {:error, :turn_in_progress, ^recorder} = emit(recorder, make_ref(), {:text, "other"})
    assert Recording.discard(recorder).events == []
    File.rmdir!(ctx.root)
    assert {:error, :enoent, reset} = emit(recorder, ctx.turn, {:done, %{}})
    assert reset.events == []
  end

  test "safe IDs and symlinks cannot read or delete outside files", ctx do
    outside = ctx.root <> "-outside"
    File.write!(outside, "private")
    on_exit(fn -> File.rm(outside) end)
    assert {:error, :invalid_id} = Store.delete(ctx.store, "../outside")
    assert {:error, :invalid_id} = Store.read(ctx.store, outside)
    id = "#{System.system_time(:millisecond)}-#{String.duplicate("a", 32)}.json"
    File.ln_s!(outside, Path.join(ctx.root, id))
    assert {:error, :unsafe_path} = Store.delete(ctx.store, id)
    assert {:error, :not_found} = Store.read(ctx.store, id)
    assert File.read!(outside) == "private"
    linked = ctx.root <> "-link"
    File.ln_s!(ctx.root, linked)
    on_exit(fn -> File.rm(linked) end)
    assert {:error, :unsafe_path} = Store.new(Path.join(linked, "nested"))
    refute File.exists?(Path.join(ctx.root, "nested"))
  end

  test "retention removes expired and excess records, preserving unrelated files", ctx do
    store = %{ctx.store | max_records: 2}
    expired = "1-#{String.duplicate("a", 32)}.json"
    File.write!(Path.join(ctx.root, expired), "{}")
    File.write!(Path.join(ctx.root, ".#{expired}.tmp"), "sanitized orphan")
    File.write!(Path.join(ctx.root, "keep.txt"), "unrelated")
    for i <- 1..3, do: assert({:ok, _} = Store.write(store, %{i: i}))
    assert {:ok, ids} = Store.list(store)
    assert [_, _] = ids
    refute expired in ids
    assert File.exists?(Path.join(ctx.root, "keep.txt"))
    assert :ok = Store.delete(store, hd(ids))
    assert {:error, :not_found} = Store.read(store, hd(ids))
    assert {:error, :record_too_large} = Store.write(%{store | max_bytes: 1}, %{text: "x"})
    assert {:ok, _} = Store.cleanup(store)
    refute Enum.any?(File.ls!(ctx.root), &String.ends_with?(&1, ".tmp"))
  end

  test "oversized redactor output is rejected before a file is created", ctx do
    recorder = %{
      ctx.recorder
      | store: %{ctx.store | max_bytes: 100},
        redactor: fn _ -> {:ok, String.duplicate("sanitized", 100)} end
    }

    {:ok, recorder, nil} = emit(recorder, ctx.turn, {:text, "private"})
    assert {:error, :record_too_large, _} = emit(recorder, ctx.turn, {:done, %{}})
    assert File.ls!(ctx.root) == []
  end

  test "startup expires old artifacts and persisted paths have private permissions", ctx do
    expired = "1-#{String.duplicate("b", 32)}.json"
    File.write!(Path.join(ctx.root, expired), "{}")
    assert {:ok, store} = Store.new(ctx.root)
    refute File.exists?(Path.join(ctx.root, expired))
    assert {:ok, id} = Store.write(store, %{text: "sanitized"})
    assert Bitwise.band(File.stat!(ctx.root).mode, 0o777) == 0o700
    assert Bitwise.band(File.stat!(Path.join(ctx.root, id)).mode, 0o777) == 0o600
  end
end
