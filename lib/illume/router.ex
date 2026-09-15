defmodule Illume.Router do
  @moduledoc "Routes for Component 3's web front end. Only reachable via `mix illume.server`."

  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/" do
    pipe_through :browser

    live_session :default, root_layout: {Illume.Layouts, :root} do
      live "/", Illume.QuestionLive
    end
  end
end
