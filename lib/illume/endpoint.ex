defmodule Illume.Endpoint do
  @moduledoc """
  Phoenix endpoint for Component 3's LiveView front end. Never started by
  `Illume.Application`'s default children — only `mix illume.server` starts
  it, on demand, under its own supervisor (see DECISIONS.md entry 55). The
  plain CLI (`./illume <target_dir> "<question>"`) never touches this
  module at all.

  The two `Plug.Static` entries serve `phoenix.js`/`phoenix_live_view.js`
  straight from the `phoenix`/`phoenix_live_view` deps' own `priv/static`,
  not a copy under this app's own `priv/static` — see DECISIONS.md entry 61.
  """

  use Phoenix.Endpoint, otp_app: :illume

  @session_options [
    store: :cookie,
    key: "_illume_key",
    signing_salt: "illume_session_salt",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  plug Plug.Static, at: "/assets", from: {:phoenix, "priv/static"}, only: ~w(phoenix.js)

  plug Plug.Static,
    at: "/assets",
    from: {:phoenix_live_view, "priv/static"},
    only: ~w(phoenix_live_view.js)

  plug Plug.Session, @session_options
  plug Illume.Router
end
