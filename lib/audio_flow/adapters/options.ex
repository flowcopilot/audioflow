defmodule AudioFlow.Adapters.Options do
  @moduledoc """
  Option checks for adapters, for use in `c:AudioFlow.Adapter.validate_options/1`.

  Every function raises `ArgumentError` for an invalid option. The message
  names the option key only. It never contains an option value, because
  adapter options can hold credentials and the message can reach a client.
  """

  @pcm_sample_rates [8_000, 16_000, 22_050, 24_000, 44_100, 48_000]

  @doc "The PCM sample rates that most hosted speech-synthesis providers accept."
  def pcm_sample_rates, do: @pcm_sample_rates

  @doc "Raises unless `options` is a keyword list. Returns `options`."
  def keyword!(options) do
    unless Keyword.keyword?(options), do: raise(ArgumentError, "options must be a keyword list")
    options
  end

  @doc "Raises for a key that is not in `allowed`. The message lists keys, never values."
  def known!(options, allowed) do
    case Keyword.keys(options) -- allowed do
      [] -> options
      unknown -> raise ArgumentError, "unknown options #{inspect(Enum.uniq(unknown))}"
    end
  end

  @doc "Returns a required, non-blank string option."
  def string!(options, key) do
    case Keyword.fetch(options, key) do
      {:ok, value} -> nonblank!(value, key)
      :error -> raise ArgumentError, "#{key} is required"
    end
  end

  @doc "Returns a non-blank string option, or `default` when it is not set."
  def optional_string!(options, key, default \\ nil) do
    case Keyword.get(options, key) do
      nil -> default
      value -> nonblank!(value, key)
    end
  end

  @doc "Returns a string option that can be empty, or `default` when it is not set."
  def text!(options, key, default \\ nil) do
    case Keyword.get(options, key) do
      nil ->
        default

      value when is_binary(value) ->
        value

      _ ->
        raise ArgumentError, "#{key} must be a string"
    end
  end

  @doc """
  Checks a required API key: a non-blank string, or a function of no arguments
  that returns one when the adapter runs. Returns `:ok`.
  """
  def api_key!(options, key \\ :api_key) do
    case Keyword.fetch(options, key) do
      {:ok, value} -> key!(value, key)
      :error -> raise ArgumentError, "#{key} is required"
    end
  end

  @doc "Like `api_key!/2`, but returns `:ok` when the key is not set."
  def optional_api_key!(options, key \\ :api_key) do
    case Keyword.get(options, key) do
      nil -> :ok
      value -> key!(value, key)
    end
  end

  @doc """
  Returns the `:sample_rate` option, `default` when it is not set. Raises when
  the rate is not in `supported`.
  """
  def sample_rate!(options, supported, default, key \\ :sample_rate) do
    rate = Keyword.get(options, key, default)

    unless rate in supported,
      do: raise(ArgumentError, "#{key} must be one of #{Enum.join(supported, ", ")}")

    rate
  end

  @doc "Returns an option that must be one of `allowed`, `default` when it is not set."
  def one_of!(options, key, allowed, default) do
    value = Keyword.get(options, key, default)

    unless value in allowed,
      do:
        raise(ArgumentError, "#{key} must be one of #{Enum.map_join(allowed, ", ", &inspect/1)}")

    value
  end

  @doc "Returns a positive integer option, `default` when it is not set."
  def positive!(options, key, default) do
    value = Keyword.get(options, key, default)

    unless is_integer(value) and value > 0,
      do: raise(ArgumentError, "#{key} must be a positive integer")

    value
  end

  @doc """
  Resolves an API key that `api_key!/2` accepted. A function runs here, and
  must return a non-blank string.
  """
  def resolve_key!(options, key \\ :api_key) do
    value =
      case Keyword.get(options, key) do
        fun when is_function(fun, 0) -> fun.()
        value -> value
      end

    unless is_binary(value) and value != "",
      do: raise(ArgumentError, "#{key} must be a nonempty string or resolve to one")

    value
  end

  defp nonblank!(value, key) do
    unless is_binary(value) and String.trim(value) != "",
      do: raise(ArgumentError, "#{key} must be a nonempty string")

    value
  end

  defp key!(value, key) do
    unless is_function(value, 0) or (is_binary(value) and value != ""),
      do: raise(ArgumentError, "#{key} must be a nonempty string or a function")

    :ok
  end
end
