defmodule ChatWeb.Layouts do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" class="style-vega">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>AudioFlow chat</title>
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
end
