defmodule Illume.Endpoint do
  @moduledoc """
  Phoenix endpoint for Component 3's LiveView front end. Never started by
  `Illume.Application`'s default children — only `mix illume.server` starts
  it, on demand, under its own supervisor (see DECISIONS.md entry 55). The
  plain CLI (`./illume <target_dir> "<question>"`) never touches this
  module at all.
  """

  use Phoenix.Endpoint, otp_app: :illume

  @session_options [
    store: :cookie,
    key: "_illume_key",
    signing_salt: "illume_session_salt",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  # Served straight from the deps' own `priv/static` (`Plug.Static`'s `:from`
  # tuple resolves via `Application.app_dir/1`, which works for any loaded
  # OTP app, not just the host) — no esbuild/asset pipeline needed for two
  # prebuilt, vendored files (see DECISIONS.md entry 61).
  plug Plug.Static, at: "/assets", from: {:phoenix, "priv/static"}, only: ~w(phoenix.js)

  plug Plug.Static,
    at: "/assets",
    from: {:phoenix_live_view, "priv/static"},
    only: ~w(phoenix_live_view.js)

  plug Plug.Session, @session_options
  plug Illume.Router
end
