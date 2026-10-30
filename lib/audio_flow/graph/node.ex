defmodule AudioFlow.Graph.Node do
  @moduledoc """
  A family of graph node types. A graph names node types; this behaviour gives
  each type its ports, its options, and its adapter.

  `nodes/0` returns one spec per type: `:type` (a unique string), `:title`,
  `:description`, `:input` and `:output` (`:audio`, `:image`, `:text`,
  `:vector`, or `nil` for no port), and `:options`. Each option is a map with
  `:name` (an atom), `:type` (`:string`, `:integer`, `:boolean`, or
  `{:enum, values}`), and optional `:required`, `:default`, and
  `:description`. An input node has no input port and needs no adapter.

  Optional spec keys:

    * `:input_mode` - `:join` (default) runs the node once, after all of its
      sources finish, on their joined output: text is concatenated and
      trimmed, and PCM is concatenated. `:stream` runs the node once for each
      value that arrives, such as TTS for each sentence.
    * `:event` - the session event kind of the outputs: `:transcript`,
      `:description`, `:text`, `:audio`, `:image`, or `:vector`. The default
      is the output kind.
    * `:history` - `true` when the adapter accepts a list of role/content
      messages. With the graph `"history"` setting, this node receives the
      conversation, and its output becomes the saved reply.

  `adapter/2` receives the type and its validated options, with atom keys and
  defaults applied, and returns an `AudioFlow.Adapter` tuple.
  """
  @type kind :: :audio | :image | :text | :vector
  @type spec :: %{
          required(:type) => String.t(),
          required(:title) => String.t(),
          required(:description) => String.t(),
          required(:input) => kind() | nil,
          required(:output) => kind() | nil,
          required(:options) => [map()],
          optional(:input_mode) => :join | :stream,
          optional(:event) => atom(),
          optional(:history) => boolean()
        }

  @callback nodes() :: [spec()]
  @callback adapter(type :: String.t(), options :: map()) :: {module(), keyword()}
  @optional_callbacks adapter: 2
end
