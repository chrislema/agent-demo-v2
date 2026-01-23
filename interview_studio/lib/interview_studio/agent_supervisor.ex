defmodule InterviewStudio.AgentSupervisor do
  @moduledoc """
  Dynamic supervisor for interview session agents.

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

  alias InterviewStudio.Agents.{Director, Scribe, StoryAnalyst, ProbeCoach, EngagementMonitor}
  alias InterviewStudio.Pipeline.InterviewFSM

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

  Agents are started with restart: :transient so they only restart
  on abnormal termination.
  """
  def start_session_agents(session_id, opts \\ []) do
    llm_config = Keyword.get(opts, :llm_config, %{})

    # Start agents in order, collecting results
    agent_specs = [
      {:fsm, fn -> start_child(InterviewFSM, session_id: session_id) end},
      {:director, fn -> start_child(Director, session_id: session_id, llm_config: llm_config) end},
      {:scribe, fn -> start_child(Scribe, session_id: session_id) end},
      {:story_analyst, fn -> start_child(StoryAnalyst, session_id: session_id, llm_config: llm_config) end},
      {:probe_coach, fn -> start_child(ProbeCoach, session_id: session_id, llm_config: llm_config) end},
      {:engagement_monitor, fn -> start_child(EngagementMonitor, session_id: session_id) end}
    ]

    results = Enum.map(agent_specs, fn {name, start_fn} ->
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

    # Check if all critical agents started
    critical_agents = [:fsm, :director]
    critical_failures = Enum.filter(results, fn
      {:error, name, _} -> name in critical_agents
      _ -> false
    end)

    if critical_failures == [] do
      # Log any non-critical failures but continue
      non_critical_failures = Enum.filter(results, fn
        {:error, name, _} -> name not in critical_agents
        _ -> false
      end)

      Enum.each(non_critical_failures, fn {:error, name, reason} ->
        Logger.warning("[AgentSupervisor] Non-critical agent #{name} failed: #{inspect(reason)}")
      end)

      Logger.info("[AgentSupervisor] Session #{session_id} started with #{length(results) - length(non_critical_failures)}/#{length(results)} agents")
      {:ok, session_id}
    else
      # Critical failure - clean up and return error
      stop_session_agents(session_id)
      [{:error, name, reason} | _] = critical_failures
      {:error, "Critical agent #{name} failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Stop all agents for a session.
  """
  def stop_session_agents(session_id) do
    agent_types = [:fsm, :director, :scribe, :story_analyst, :probe_coach, :engagement_monitor]

    Enum.each(agent_types, fn type ->
      case Registry.lookup(InterviewStudio.SessionRegistry, {type, session_id}) do
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
    end)

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
    agent_types = [:fsm, :director, :scribe, :story_analyst, :probe_coach, :engagement_monitor]

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
    llm_config = Keyword.get(opts, :llm_config, %{})

    # Stop the agent if it's running
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

    # Start the agent fresh
    case agent_type do
      :fsm -> start_child(InterviewFSM, session_id: session_id)
      :director -> start_child(Director, session_id: session_id, llm_config: llm_config)
      :scribe -> start_child(Scribe, session_id: session_id)
      :story_analyst -> start_child(StoryAnalyst, session_id: session_id, llm_config: llm_config)
      :probe_coach -> start_child(ProbeCoach, session_id: session_id, llm_config: llm_config)
      :engagement_monitor -> start_child(EngagementMonitor, session_id: session_id)
      _ -> {:error, :unknown_agent_type}
    end
  end

  # Private functions

  defp start_child(module, opts) do
    spec = %{
      id: make_ref(),
      start: {module, :start_link, [opts]},
      restart: :transient,
      shutdown: 5_000
    }

    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end
