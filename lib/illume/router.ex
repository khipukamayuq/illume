defmodule Illume.Router do
  @moduledoc "Routes for Component 3's web front end. Only reachable via `mix illume.server`."

  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :fetch_session
    plug :fetch_live_flash
  end

  scope "/" do
    pipe_through :browser

    live "/", Illume.QuestionLive
  end
end
