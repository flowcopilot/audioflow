defmodule AudioFlow.Playout do
  @moduledoc false
  # Offsets are cumulative nanoseconds of mono PCM, independent of input PTS.
  def new, do: %{emitted: 0, played: 0, boundary: 0, covered?: true, checkpoints: []}

  def audio(state, audio) do
    ns =
      div(
        div(byte_size(audio.data), 2) * 1_000_000_000 + audio.sample_rate - 1,
        audio.sample_rate
      )

    %{state | emitted: state.emitted + ns}
  end

  def checkpoint(state, bytes) do
    if state.covered? and state.emitted > state.boundary do
      %{
        state
        | boundary: state.emitted,
          checkpoints: [{state.emitted, bytes} | state.checkpoints]
      }
    else
      %{state | covered?: false}
    end
  end

  def acknowledge(state, ns) when is_integer(ns) and ns >= 0 do
    if ns >= state.played and ns <= state.emitted,
      do: {:ok, %{state | played: ns}},
      else: {:error, :invalid_playback_offset}
  end

  def acknowledge(_, _), do: {:error, :invalid_playback_offset}

  def heard_bytes(state) do
    state.checkpoints
    |> Enum.filter(fn {ns, _} -> ns <= state.played end)
    |> Enum.map(fn {_, bytes} -> bytes end)
    |> Enum.max(fn -> 0 end)
  end
end
