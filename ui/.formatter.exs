[
  import_deps: [:phoenix, :sake],
  locals_without_parens: [sake_endpoint: 2],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: ["*.{ex,exs}", "{config,lib,test}/**/*.{ex,exs,heex}"]
]
