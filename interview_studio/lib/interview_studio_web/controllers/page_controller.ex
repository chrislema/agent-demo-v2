defmodule InterviewStudioWeb.PageController do
  use InterviewStudioWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
