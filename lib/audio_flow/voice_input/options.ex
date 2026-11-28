defmodule AudioFlow.VoiceInput.Options do
  @moduledoc """
  Reads the `AudioFlow.VoiceInput` options out of the options of a transport.

  A transport takes them in `:voice_input`. The older name `:endpoint_options`
  still works, but it logs a warning each time it is used. When both keys are
  present, `:voice_input` wins.
  """
  require Logger

  @doc """
  Returns the `VoiceInput.new/2` options of `options`.

  `defaults` are the transport defaults. The options of the caller override
  them. A transport that owns a process with a `handle_info` callback passes
  `async_turn: true`, so that a semantic turn check never blocks that process.
  """
  @spec fetch(keyword(), keyword()) :: keyword()
  def fetch(options, defaults \\ []) when is_list(options) do
    user =
      case {Keyword.fetch(options, :voice_input), Keyword.fetch(options, :endpoint_options)} do
        {{:ok, value}, :error} ->
          value

        {:error, :error} ->
          []

        {:error, {:ok, value}} ->
          warn_alias()
          value

        {{:ok, value}, {:ok, _ignored}} ->
          warn_alias()
          value
      end

    Keyword.merge(defaults, user)
  end

  defp warn_alias do
    Logger.warning(
      "the :endpoint_options option is deprecated, use :voice_input instead " <>
        "(options of AudioFlow.VoiceInput.new/2)"
    )
  end
end
