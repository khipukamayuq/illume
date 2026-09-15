defmodule Illume.Layouts do
  @moduledoc """
  Root HTML layout for the LiveView page. Ships the CSRF meta tag and the
  vendored `phoenix.js`/`phoenix_live_view.js` client JS (served straight
  from those deps' own `priv/static` by `Illume.Endpoint`'s `Plug.Static`
  entries — no esbuild/asset pipeline; see DECISIONS.md entry 61) and
  constructs the `LiveSocket` by hand from their `Phoenix`/`LiveView`
  globals, since neither file is an ES module here.
  """

  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1.0" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>Illume</title>
        <script defer src="/assets/phoenix.js">
        </script>
        <script defer src="/assets/phoenix_live_view.js">
        </script>
      </head>
      <body>
        {@inner_content}
        <script>
          window.addEventListener("DOMContentLoaded", () => {
            let csrfToken = document
              .querySelector("meta[name='csrf-token']")
              .getAttribute("content");
            let liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
              params: { _csrf_token: csrfToken },
            });
            liveSocket.connect();
          });
        </script>
      </body>
    </html>
    """
  end
end
