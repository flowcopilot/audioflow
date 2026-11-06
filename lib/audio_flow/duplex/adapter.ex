defmodule AudioFlow.Duplex.Adapter do
  @moduledoc """
  Wire protocol of one continuous `AudioFlow.Duplex` model connection.

  `AudioFlow.Duplex` owns the WebSocket, the timers, the bounds and the owner
  messages. An adapter only maps audio to frames and frames to events. All
  callbacks except `config/1` run in the session process.

  `handle_frame/2` returns events in wire order:

    * `:ready` once, after the model handshake. The session rejects audio
      until then.
    * `{:audio, %AudioFlow.Audio{}}` with model output at `:sample_rate`.
    * `{:text, text}` with model text.

  Adapters for models with their own turn detection also return:

    * `{:speech_started, item}`: the model detected user speech. Audio of the
      current reply is obsolete; the owner flushes queued playback. `item` is
      the provider ID of the user input.
    * `{:transcript, item, text}`: final transcript of the user input `item`,
      or `{:transcript, item, :failed}`.
    * `{:response, id, status}`: a model reply starts (`:created`) or ends
      (`:completed`, `:cancelled`, `:incomplete` or `:failed`).
    * `{:output, item}`: the next `{:audio, _}` events belong to the reply
      audio `item`, until the next `{:output, _}` or `{:speech_started, _}`.
  """
  alias AudioFlow.Audio

  @type frame :: {:text | :binary, binary()}
  @type item :: String.t()
  @type event ::
          :ready
          | {:audio, Audio.t()}
          | {:text, String.t()}
          | {:speech_started, item()}
          | {:transcript, item(), String.t() | :failed}
          | {:response, String.t(), :created | :completed | :cancelled | :incomplete | :failed}
          | {:output, item()}

  @doc """
  Validates options in the caller of `AudioFlow.Duplex.start_link/1`. Raises
  `ArgumentError` for invalid options. `:url` must be `ws` or `wss`.

  `:headers` can be a function that returns the headers. The session calls it
  only to connect, so credentials do not stay in the session state.

  `:input_flow` (default `:answered`) selects the input bound. `:answered`
  counts input that model audio has not answered; use it when the model sends
  one output frame for each input frame. `:realtime` counts input ahead of the
  wall clock; use it when the model is silent while the user speaks.
  """
  @callback config(options :: keyword()) :: %{
              required(:url) => String.t(),
              required(:headers) => [{String.t(), String.t()}] | (-> [{String.t(), String.t()}]),
              required(:sample_rate) => pos_integer(),
              required(:options) => term(),
              optional(:input_flow) => :answered | :realtime
            }

  @doc "Returns the initial protocol state from `config/1` `:options`."
  @callback init(options :: term()) :: state :: term()

  @callback handle_frame(frame(), state :: term()) ::
              {:ok, [event()], [frame()], state :: term()} | {:error, term()}

  @doc "Maps one accepted input chunk to frames. Partial model frames may stay buffered."
  @callback handle_audio(Audio.t(), state :: term()) ::
              {:ok, [frame()], state :: term()} | {:error, term()}

  @doc """
  Maps a command from `AudioFlow.Duplex.control/2` to frames. An error leaves
  the session open.
  """
  @callback handle_control(command :: term(), state :: term()) ::
              {:ok, [frame()], state :: term()} | {:error, term()}

  @optional_callbacks handle_control: 2
end
