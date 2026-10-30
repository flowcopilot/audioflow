defmodule ChatWeb.Layouts do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" class="style-vega dark" style="color-scheme: dark">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>AudioFlow chat</title>
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
