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
  """
  alias AudioFlow.Audio

  @type frame :: {:text | :binary, binary()}
  @type event :: :ready | {:audio, Audio.t()} | {:text, String.t()}

  @doc """
  Validates options in the caller of `AudioFlow.Duplex.start_link/1`. Raises
  `ArgumentError` for invalid options. `:url` must be `ws` or `wss`.
  """
  @callback config(options :: keyword()) :: %{
              url: String.t(),
              headers: [{String.t(), String.t()}],
              sample_rate: pos_integer(),
              options: term()
            }

  @doc "Returns the initial protocol state from `config/1` `:options`."
  @callback init(options :: term()) :: state :: term()

  @callback handle_frame(frame(), state :: term()) ::
              {:ok, [event()], [frame()], state :: term()} | {:error, term()}

  @doc "Maps one accepted input chunk to frames. Partial model frames may stay buffered."
  @callback handle_audio(Audio.t(), state :: term()) ::
              {:ok, [frame()], state :: term()} | {:error, term()}
end
