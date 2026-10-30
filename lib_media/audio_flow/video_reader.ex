defmodule AudioFlow.VideoReader do
  @moduledoc false
  use Membrane.Pipeline
  alias Membrane.Pad

  @impl true
  def handle_init(_ctx, options) do
    owner = Keyword.fetch!(options, :owner)

    state = %{
      owner_ref: Process.monitor(owner),
      options: options,
      pending: nil,
      ready?: false,
      eof?: false,
      error: nil
    }

    spec =
      if source = options[:source] do
        child(:source, source) |> rgb_chain(options)
      else
        child(:source, %Membrane.File.Source{
          location: options[:location],
          seekable?: true,
          chunk_size: 4096,
          content_format: Membrane.MP4
        })
        |> child(:demuxer, %Membrane.MP4.Demuxer.ISOM{optimize_for_non_fast_start?: true})
      end

    {[spec: {spec, group: :decode, crash_group_mode: :temporary}],
     %{state | ready?: options[:source] != nil}}
  end

  @impl true
  def handle_child_notification({:new_tracks, tracks}, :demuxer, _ctx, state) do
    candidates =
      Enum.filter(tracks, fn {_, format} -> match?(%Membrane.H264{}, format) end)
      |> Enum.sort_by(&elem(&1, 0))

    selected =
      if id = state.options[:track_id],
        do: Enum.find(candidates, &(elem(&1, 0) == id)),
        else: List.first(candidates)

    if selected == nil do
      fail(state, :no_h264_track)
    else
      {selected_id, _} = selected

      specs =
        Enum.map(tracks, fn {id, _} ->
          link = get_child(:demuxer) |> via_out(Pad.ref(:output, id))

          if id == selected_id do
            link
            |> child(:parser, %Membrane.H264.Parser{
              output_stream_structure: :annexb,
              output_alignment: :au
            })
            |> child(:decoder, Membrane.H264.FFmpeg.Decoder)
            |> rgb_chain(state.options)
          else
            link |> child({:discard, id}, Membrane.Fake.Sink)
          end
        end)

      actions = [spec: {specs, group: :decode, crash_group_mode: :temporary}]

      actions =
        if state.pending != nil,
          do: actions ++ [notify_child: {:frames, :next_frame}],
          else: actions

      {actions, %{state | ready?: true}}
    end
  end

  def handle_child_notification({:frame, image}, :frames, _ctx, %{pending: pending} = state)
      when pending != nil,
      do: {[reply_to: {pending, {:ok, image}}], %{state | pending: nil}}

  def handle_child_notification(:frames_done, :frames, _ctx, state) do
    actions = if state.pending, do: [reply_to: {state.pending, :eof}], else: []
    {actions, %{state | pending: nil, eof?: true}}
  end

  def handle_child_notification({:frame_error, reason}, :frames, _ctx, state),
    do: fail(state, reason)

  @impl true
  def handle_call(:next_frame, ctx, state) do
    cond do
      state.error != nil -> {[reply: {:error, state.error}], state}
      state.eof? -> {[reply: :eof], state}
      state.pending != nil -> {[reply: {:error, :busy}], state}
      state.ready? -> {[notify_child: {:frames, :next_frame}], %{state | pending: ctx.from}}
      true -> {[], %{state | pending: ctx.from}}
    end
  end

  @impl true
  def handle_crash_group_down(:decode, ctx, state),
    do: fail(state, {:decode_failed, ctx.crash_reason})

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, _ctx, %{owner_ref: ref} = state),
    do: {[terminate: :normal], state}

  def handle_info(_, _, state), do: {[], state}

  defp fail(state, reason) do
    actions = if state.pending, do: [reply_to: {state.pending, {:error, reason}}], else: []
    {actions, %{state | pending: nil, error: reason}}
  end

  defp rgb_chain(builder, options) do
    builder
    |> via_in(:input, target_queue_size: 1, min_demand_factor: 0, auto_demand_size: 1)
    |> child(:rgb, %Membrane.FFmpeg.SWScale.Converter{
      format: :RGB,
      output_width: options[:width],
      output_height: options[:height]
    })
    |> via_in(:input, target_queue_size: 1, min_demand_factor: 0, auto_demand_size: 1)
    |> child(:frames, %AudioFlow.VideoFrameSink{
      interval_ns: options[:interval_ms] * 1_000_000,
      max_frame_bytes: options[:max_frame_bytes],
      normalize_timestamps?: options[:normalize_timestamps?]
    })
  end
end
