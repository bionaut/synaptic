if Code.ensure_loaded?(Phoenix.Router) do
  defmodule Synaptic.Monitor.Web.Router do
    @moduledoc false

    use Phoenix.Router

    pipeline :browser do
      plug(:accepts, ["html"])
    end

    pipeline :api do
      plug(:accepts, ["json"])
    end

    scope "/" do
      pipe_through(:browser)
      get("/favicon.ico", Synaptic.Monitor.Web.PageController, :favicon)
      get("/", Synaptic.Monitor.Web.PageController, :index)
    end

    scope "/api" do
      pipe_through(:api)
      get("/snapshot", Synaptic.Monitor.Web.PageController, :snapshot)
    end
  end
end
