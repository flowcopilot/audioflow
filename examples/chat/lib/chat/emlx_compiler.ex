defmodule Chat.EMLXCompiler do
  @moduledoc """
  EMLX as an `Nx.Serving` compiler.

  `Nx.Serving` passes `:batch_keys` to its compiler. EXLA ignores the option;
  EMLX 0.5 rejects unknown options. This module removes it and delegates.
  """
  @behaviour Nx.Defn.Compiler

  @impl true
  def __jit__(key, vars, fun, args, opts), do: EMLX.__jit__(key, vars, fun, args, clean(opts))

  @impl true
  def __compile__(key, vars, fun, opts), do: EMLX.__compile__(key, vars, fun, clean(opts))

  @impl true
  def __partitions_options__(opts), do: EMLX.__partitions_options__(clean(opts))

  @impl true
  def __to_backend__(opts), do: EMLX.__to_backend__(clean(opts))

  defp clean(opts), do: Keyword.delete(opts, :batch_keys)
end
