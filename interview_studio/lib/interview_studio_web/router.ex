defmodule InterviewStudioWeb.Router do
  use InterviewStudioWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {InterviewStudioWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", InterviewStudioWeb do
    pipe_through :browser

    # Share session state between interview and debug pages
    live_session :interview, on_mount: [] do
      live "/", InterviewLive
      live "/interview", InterviewLive
      live "/debug", DebugLive
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", InterviewStudioWeb do
  #   pipe_through :api
  # end
end
