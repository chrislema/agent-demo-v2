defmodule InterviewStudio.AgentSupervisor do
  @moduledoc """
  Dynamic supervisor for interview session agents.

  Phase 4: Domain-Agnostic Architecture
  - Loads agents dynamically from domain configuration
  - Stores domain config in :persistent_term for session access

  Phase 7.2: Agent Failure Isolation
  - Single agent crash doesn't break the system
  - Automatic restart with backoff
  - Graceful degradation when agents are unavailable

  Each session gets its own set of supervised agents.
  The supervisor uses :one_for_one strategy so a single agent failure
  doesn't cascade to other agents.
  """

  use DynamicSupervisor
  require Logger

  alias InterviewStudio.DomainLoader

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: 10,
      max_seconds: 60
    )
  end

  @doc """
  Start all agents for a session under supervision.
  Returns {:ok, session_id} or {:error, reason}.

  Options:
  - :domain - Domain name to load configuration from (default: "interview")
  - :llm_config - Override LLM configuration

  Agents are started with restart: :transient so they only restart
  on abnormal termination.
  """
  def start_session_agents(session_id, opts \\ []) do
    domain_name = Keyword.get(opts, :domain, "interview")
    llm_config_override = Keyword.get(opts, :llm_config, %{})

    # Load domain configuration
    case DomainLoader.load(domain_name) do
      {:ok, domain} ->
        # Merge LLM config with domain defaults
        llm_config = Map.merge(domain.llm_defaults || %{}, llm_config_override)

        # Build agent specs from domain config
        agent_specs = build_specs_from_config(domain.agents, session_id, llm_config, domain)

        # Start agents
        results = start_agents(agent_specs, session_id)

        # Check if all critical agents started
        critical_agent_ids = get_critical_agent_ids(domain.agents)
        critical_failures = Enum.filter(results, fn
          {:error, name, _} -> name in critical_agent_ids
          _ -> false
        end)

        if critical_failures == [] do
          # Store domain config for session access
          DomainLoader.store_session_domain(session_id, domain)

          # Log any non-critical failures but continue
          non_critical_failures = Enum.filter(results, fn
            {:error, name, _} -> name not in critical_agent_ids
            _ -> false
          end)

          Enum.each(non_critical_failures, fn {:error, name, reason} ->
            Logger.warning("[AgentSupervisor] Non-critical agent #{name} failed: #{inspect(reason)}")
          end)

          Logger.info("[AgentSupervisor] Session #{session_id} started with #{length(results) - length(non_critical_failures)}/#{length(results)} agents (domain: #{domain_name})")
          {:ok, session_id}
        else
          # Critical failure - clean up and return error
          stop_session_agents(session_id)
          [{:error, name, reason} | _] = critical_failures
          {:error, "Critical agent #{name} failed: #{inspect(reason)}"}
        end

      {:error, reason} ->
        Logger.error("[AgentSupervisor] Failed to load domain #{domain_name}: #{inspect(reason)}")
        {:error, "Failed to load domain: #{inspect(reason)}"}
    end
  end

  @doc """
  Stop all agents for a session.
  """
  def stop_session_agents(session_id) do
    # Get domain to know which agents to stop
    case DomainLoader.get_session_domain(session_id) do
      nil ->
        # Fallback to default agent types if no domain cached
        stop_agents_by_type(session_id, default_agent_types())

      domain ->
        # Get agent IDs from domain config
        agent_ids = DomainLoader.get_all_agents(domain)
                    |> Enum.map(fn a -> String.to_atom(a[:id]) end)
        stop_agents_by_type(session_id, agent_ids)

        # Clear session domain
        DomainLoader.clear_session_domain(session_id)
    end

    Logger.info("[AgentSupervisor] Stopped agents for session #{session_id}")
    :ok
  end

  @doc """
  Check if a specific agent is alive for a session.
  """
  def agent_alive?(session_id, agent_type) do
    case Registry.lookup(InterviewStudio.SessionRegistry, {agent_type, session_id}) do
      [{pid, _}] -> Process.alive?(pid)
      [] -> false
    end
  end

  @doc """
  Get the status of all agents for a session.
  """
  def session_status(session_id) do
    # Get agent types from domain config or use defaults
    agent_types = case DomainLoader.get_session_domain(session_id) do
      nil -> default_agent_types()
      domain ->
        DomainLoader.get_all_agents(domain)
        |> Enum.map(fn a -> String.to_atom(a[:id]) end)
    end

    Enum.map(agent_types, fn type ->
      {type, agent_alive?(session_id, type)}
    end)
    |> Enum.into(%{})
  end

  @doc """
  Restart a specific agent for a session.
  Returns {:ok, pid} or {:error, reason}.
  """
  def restart_agent(session_id, agent_type, opts \\ []) do
    llm_config_override = Keyword.get(opts, :llm_config, %{})

    # Stop the agent if it's running
    stop_agent(session_id, agent_type)

    # Get domain config
    case DomainLoader.get_session_domain(session_id) do
      nil ->
        {:error, :no_domain_config}

      domain ->
        # Find agent config
        agent_id = to_string(agent_type)
        agent_config = DomainLoader.get_agent(domain, agent_id)

        if agent_config do
          llm_config = Map.merge(domain.llm_defaults || %{}, llm_config_override)
          opts = build_agent_opts(agent_config, session_id, llm_config, domain)
          module = resolve_module(agent_config[:module])
          start_child(module, opts)
        else
          {:error, :agent_not_found}
        end
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  # Build agent specs from domain configuration
  defp build_specs_from_config(agents_config, session_id, llm_config, domain) do
    critical_agents = agents_config[:critical] || []
    observer_agents = agents_config[:observers] || []
    all_agents = critical_agents ++ observer_agents

    Enum.map(all_agents, fn agent_config ->
      agent_id = String.to_atom(agent_config[:id])
      module = resolve_module(agent_config[:module])
      opts = build_agent_opts(agent_config, session_id, llm_config, domain)

      {agent_id, fn -> start_child(module, opts) end}
    end)
  end

  # Build opts for an agent based on its config
  defp build_agent_opts(agent_config, session_id, llm_config, domain) do
    opts = [session_id: session_id, domain: domain]

    # Add LLM config if agent requires it
    opts = if agent_config[:requires_llm] do
      [{:llm_config, llm_config} | opts]
    else
      opts
    end

    opts
  end

  # Resolve module from string to atom
  defp resolve_module(module_name) when is_binary(module_name) do
    String.to_existing_atom("Elixir.#{module_name}")
  rescue
    ArgumentError ->
      # Try without Elixir prefix
      String.to_atom("Elixir.#{module_name}")
  end

  defp resolve_module(module_name) when is_atom(module_name) do
    module_name
  end

  # Get critical agent IDs from config
  defp get_critical_agent_ids(agents_config) do
    critical_agents = agents_config[:critical] || []
    Enum.map(critical_agents, fn a -> String.to_atom(a[:id]) end)
  end

  # Start agents and collect results
  defp start_agents(agent_specs, session_id) do
    Enum.map(agent_specs, fn {name, start_fn} ->
      case start_fn.() do
        {:ok, pid} ->
          Logger.debug("[AgentSupervisor] Started #{name} for session #{session_id}")
          {:ok, name, pid}
        {:error, {:already_started, pid}} ->
          Logger.debug("[AgentSupervisor] #{name} already started for session #{session_id}")
          {:ok, name, pid}
        {:error, reason} ->
          Logger.error("[AgentSupervisor] Failed to start #{name}: #{inspect(reason)}")
          {:error, name, reason}
      end
    end)
  end

  # Stop agents by type
  defp stop_agents_by_type(session_id, agent_types) do
    Enum.each(agent_types, fn type ->
      stop_agent(session_id, type)
    end)
  end

  # Stop a single agent
  defp stop_agent(session_id, agent_type) do
    case Registry.lookup(InterviewStudio.SessionRegistry, {agent_type, session_id}) do
      [{pid, _}] ->
        try do
          DynamicSupervisor.terminate_child(__MODULE__, pid)
        rescue
          _ -> :ok
        catch
          :exit, _ -> :ok
        end
      [] ->
        :ok
    end
  end

  defp start_child(module, opts) do
    spec = %{
      id: make_ref(),
      start: {module, :start_link, [opts]},
      restart: :transient,
      shutdown: 5_000
    }

    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  # Default agent types (fallback when no domain config)
  defp default_agent_types do
    [:director, :scribe, :story_analyst, :probe_coach, :engagement_monitor, :timer_agent, :sentiment_agent]
  end
end
