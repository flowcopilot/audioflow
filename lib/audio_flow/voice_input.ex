defmodule AudioFlow.VoiceInput do
  @moduledoc """
  Turns PCM frames into bounded utterances with a stateful voice detector.

  `new/2` takes a detector tuple and endpoint options. `push/2` accepts PCM
  chunks at the detector's sample rate and returns `{events, new_state}`.
  Events are `:speech_started` and `{:utterance, audio, reason}`, where reason
  is `:silence`, `:limit`, or `:end_of_stream`. A confirmed speech start can
  cancel a previous reply before the new utterance is complete.

  Defaults: speech probability 0.5, silence probability 0.35, speech confirmation
  96 ms, silence 320 ms, pre-roll 64 ms, and maximum utterance 30 seconds.
  Minimum durations round up to whole detector frames; the maximum rounds down.
  Utterances include pre-roll and
  trailing silence. After a forced limit, detection starts a new utterance.
  """
  alias AudioFlow.Audio

  defstruct [
    :detector,
    :detector_state,
    :rate,
    :frame_bytes,
    :limits,
    pending: <<>>,
    pre_roll: [],
    frames: [],
    frame_count: 0,
    speech_count: 0,
    silence_count: 0,
    speaking?: false
  ]

  def new({detector, detector_options}, options \\ []) do
    {samples, rate, state} = detector.init(detector_options)

    unless is_integer(samples) and samples > 0 and is_integer(rate) and rate > 0,
      do: raise(ArgumentError, "detector frame size and sample rate must be positive integers")

    threshold = Keyword.get(options, :threshold, 0.5)
    silence_threshold = Keyword.get(options, :silence_threshold, 0.35)

    unless is_number(threshold) and threshold > 0 and threshold <= 1 and
             is_number(silence_threshold) and silence_threshold >= 0 and
             silence_threshold < threshold,
           do:
             raise(
               ArgumentError,
               "probability thresholds must satisfy 0 <= silence < speech <= 1"
             )

    frames = fn key, default, zero? ->
      ms = Keyword.get(options, key, default)

      unless is_integer(ms) and (ms > 0 or (zero? and ms == 0)),
        do: raise(ArgumentError, "#{key} has an invalid duration")

      if key == :max_utterance_ms,
        do: div(ms * rate, samples * 1000),
        else: div(ms * rate + samples * 1000 - 1, samples * 1000)
    end

    limits = %{
      threshold: threshold,
      silence_threshold: silence_threshold,
      speech: frames.(:min_speech_ms, 96, false),
      silence: frames.(:min_silence_ms, 320, false),
      pre_roll: frames.(:pre_roll_ms, 64, true),
      utterance: frames.(:max_utterance_ms, 30_000, false)
    }

    if limits.utterance < limits.speech + limits.pre_roll,
      do:
        raise(ArgumentError, "maximum utterance is shorter than speech confirmation and pre-roll")

    %__MODULE__{
      detector: detector,
      detector_state: state,
      rate: rate,
      frame_bytes: samples * 2,
      limits: limits
    }
  end

  def push(%__MODULE__{} = state, %Audio{sample_rate: rate, data: data} = audio) do
    unless rate == state.rate and Audio.valid?(audio),
      do: raise(ArgumentError, "input must be valid PCM at #{state.rate} Hz")

    if byte_size(data) > 960_000, do: raise(ArgumentError, "input chunk exceeds 960000 bytes")
    consume(state.pending <> data, %{state | pending: <<>>}, [])
  end

  @doc "Flush an active utterance. A partial final frame is padded with silence."
  def flush(%__MODULE__{} = state) do
    {events, state} =
      if state.pending == <<>> do
        {[], state}
      else
        padding = :binary.copy(<<0>>, state.frame_bytes - byte_size(state.pending))
        consume(state.pending <> padding, %{state | pending: <<>>}, [])
      end

    if state.speaking? do
      {event, state} = finish(state, :end_of_stream)
      {events ++ [event], state}
    else
      {events, reset(state)}
    end
  end

  defp consume(data, state, events) when byte_size(data) < state.frame_bytes,
    do: {Enum.reverse(events), %{state | pending: :binary.copy(data)}}

  defp consume(data, state, events) do
    frame = :binary.copy(binary_part(data, 0, state.frame_bytes))
    rest = binary_part(data, state.frame_bytes, byte_size(data) - state.frame_bytes)

    {probability, detector_state} =
      state.detector.predict(%Audio{data: frame, sample_rate: state.rate}, state.detector_state)

    unless is_number(probability) and probability >= 0 and probability <= 1,
      do: raise(ArgumentError, "detector returned an invalid speech probability")

    {new_events, state} = step(%{state | detector_state: detector_state}, frame, probability)
    consume(rest, state, Enum.reverse(new_events, events))
  end

  defp step(%{speaking?: false} = state, frame, probability) do
    if probability >= state.limits.threshold do
      state = %{
        state
        | frames: [frame | state.frames],
          speech_count: state.speech_count + 1,
          frame_count: state.frame_count + 1
      }

      if state.speech_count >= state.limits.speech do
        state = %{
          state
          | speaking?: true,
            frames: state.frames ++ state.pre_roll,
            frame_count: state.frame_count + length(state.pre_roll),
            pre_roll: []
        }

        if state.frame_count >= state.limits.utterance do
          {event, state} = finish(state, :limit)
          {[:speech_started, event], state}
        else
          {[:speech_started], state}
        end
      else
        {[], state}
      end
    else
      history = Enum.take([frame | state.frames ++ state.pre_roll], state.limits.pre_roll)
      {[], %{state | frames: [], frame_count: 0, speech_count: 0, pre_roll: history}}
    end
  end

  defp step(state, frame, probability) do
    silence =
      if probability < state.limits.silence_threshold, do: state.silence_count + 1, else: 0

    state = %{
      state
      | frames: [frame | state.frames],
        frame_count: state.frame_count + 1,
        silence_count: silence
    }

    reason =
      cond do
        silence >= state.limits.silence -> :silence
        state.frame_count >= state.limits.utterance -> :limit
        true -> nil
      end

    if reason do
      {event, state} = finish(state, reason)
      {[event], state}
    else
      {[], state}
    end
  end

  defp finish(state, reason) do
    audio = %Audio{
      data: state.frames |> Enum.reverse() |> IO.iodata_to_binary(),
      sample_rate: state.rate
    }

    {{:utterance, audio, reason}, reset(state)}
  end

  defp reset(state),
    do: %{
      state
      | frames: [],
        pre_roll: [],
        speech_count: 0,
        silence_count: 0,
        frame_count: 0,
        speaking?: false,
        pending: <<>>
    }
end
