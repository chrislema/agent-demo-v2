defmodule InterviewStudio.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      InterviewStudioWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:interview_studio, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: InterviewStudio.PubSub},
      # Registry for session management (FSM, agents)
      {Registry, keys: :unique, name: InterviewStudio.SessionRegistry},
      # Interview signal bus for multi-agent communication
      InterviewStudio.InterviewBus,
      # Phase 7: Performance monitoring, circuit breakers, and caching
      InterviewStudio.Performance,
      # Phase 7: Agent supervisor for failure isolation
      InterviewStudio.AgentSupervisor,
      # Start to serve requests, typically the last entry
      InterviewStudioWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: InterviewStudio.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    InterviewStudioWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
