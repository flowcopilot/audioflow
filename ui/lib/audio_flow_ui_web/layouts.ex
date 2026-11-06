defmodule AudioFlowUIWeb.Layouts do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" class="style-vega">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>AudioFlow</title>
        <%!-- Follow the system color scheme, as the docs do. --%>
        <script>
          const dark = matchMedia("(prefers-color-scheme: dark)").matches;
          document.documentElement.classList.toggle("dark", dark);
          document.documentElement.style.colorScheme = dark ? "dark" : "light";
        </script>
        <link rel="stylesheet" href="/assets/fonts/bricolage-grotesque/standard.css" />
        <link rel="stylesheet" href="/assets/fonts/ibm-plex-mono/400.css" />
        <link rel="stylesheet" href="/assets/fonts/ibm-plex-mono/600.css" />
        <link rel="stylesheet" href="/assets/app.css" />
        <script defer type="text/javascript" src="/assets/app.js">
        </script>
      </head>
      <body class="bg-background text-foreground antialiased">
        {@inner_content}
      </body>
    </html>
    """
  end

  @doc "The AudioFlow mark from the docs."
  attr(:class, :any, default: "size-7")

  def logo(assigns) do
    ~H"""
    <svg viewBox="0 0 32 32" aria-hidden="true" class={@class}>
      <rect width="32" height="32" rx="8" fill="#5B2E91" />
      <g stroke="#7CE0C3" stroke-width="2.4" stroke-linecap="round">
        <path d="M8 14v4" /><path d="M12 10v12" /><path d="M16 7v18" /><path d="M20 11v10" /><path d="M24 14v4" />
      </g>
    </svg>
    """
  end
end
