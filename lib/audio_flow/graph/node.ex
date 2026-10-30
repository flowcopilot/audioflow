defmodule AudioFlow.Graph.Node do
  @moduledoc """
  A family of graph node types. A graph names node types; this behaviour gives
  each type its ports, its options, and its adapter.

  `nodes/0` returns one spec per type: `:type` (a unique string), `:title`,
  `:description`, `:input` and `:output` (`:audio`, `:image`, `:text`, or
  `nil` for no port), and `:options`. Each option is a map with `:name` (an
  atom), `:type` (`:string`, `:integer`, `:boolean`, or `{:enum, values}`),
  and optional `:required`, `:default`, and `:description`. An input node has
  no input port and needs no adapter.

  `adapter/2` receives the type and its validated options, with atom keys and
  defaults applied, and returns an `AudioFlow.Adapter` tuple.
  """
  @type kind :: :audio | :image | :text
  @type spec :: %{
          required(:type) => String.t(),
          required(:title) => String.t(),
          required(:description) => String.t(),
          required(:input) => kind() | nil,
          required(:output) => kind() | nil,
          required(:options) => [map()]
        }

  @callback nodes() :: [spec()]
  @callback adapter(type :: String.t(), options :: map()) :: {module(), keyword()}
  @optional_callbacks adapter: 2
end
