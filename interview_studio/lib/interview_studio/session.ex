defmodule InterviewStudio.Session do
  @moduledoc """
  Session manager - coordinates all agents for an interview session.

  Phase 4: Domain-Agnostic Architecture
  - Uses DomainLoader to get action configurations
  - Fallback text comes from YAML config, not hardcoded values

  Responsibilities:
  - Start/stop Director and all observer agents together
  - Provide unified API for session management
  - Track session state across all components
  """

  require Logger

  alias InterviewStudio.Agents.{Director, Scribe, StoryAnalyst, ProbeCoach, EngagementMonitor}
  alias InterviewStudio.InterviewBus
  alias InterviewStudio.Performance
  alias InterviewStudio.AgentSupervisor
  alias InterviewStudio.DomainLoader

  @doc """
  Start a new interview session with all agents.
  Returns {:ok, session_id} or {:error, reason}

  Options:
  - :session_id - Custom session ID (default: generated)
  - :domain - Domain name (default: "interview")
  - :llm_config - Override LLM configuration
  """
  def start_session(opts \\ []) do
    session_id = Keyword.get(opts, :session_id, generate_session_id())

    # PHASE 7: Use AgentSupervisor for failure isolation
    # PHASE 4: Pass domain option for config-driven loading
    case AgentSupervisor.start_session_agents(session_id, opts) do
      {:ok, ^session_id} ->
        Logger.info("[Session] Started session #{session_id}")
        {:ok, session_id}

      {:error, reason} ->
        Logger.error("[Session] Failed to start session: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Stop an interview session and all its agents.
  """
  def stop_session(session_id) do
    # PHASE 7: Use AgentSupervisor to stop all agents
    AgentSupervisor.stop_session_agents(session_id)
    Logger.info("[Session] Stopped session #{session_id}")
    :ok
  end

  @doc """
  Get the combined state of a session.
  """
  def get_session_state(session_id) do
    %{
      session_id: session_id,
      phase: get_current_phase(session_id),
      director: get_director_state(session_id),
      scribe: get_scribe_state(session_id),
      engagement: get_engagement_level(session_id),
      # PHASE 7: Include agent health status
      agent_status: AgentSupervisor.session_status(session_id)
    }
  end

  @doc """
  Get performance metrics for the system.
  """
  def get_performance_metrics do
    Performance.get_metrics()
  end

  @doc """
  Get recent operation timings.
  """
  def get_recent_timings(limit \\ 10) do
    Performance.get_recent_timings(limit)
  end

  @doc """
  Process a user message through the session.
  Returns {:ok, response} or {:error, reason}

  This implements the multi-agent collaboration pattern:
  1. Record message with Director
  2. Trigger parallel analysis from all observer agents
  3. Wait for insights (with timeout)
  4. Director synthesizes insights into next action
  5. Execute action
  """
  def process_message(session_id, message) do
    # PHASE 7: Track overall response time
    op_id = Performance.record_start(:process_message, %{session_id: session_id})

    # Invalidate insight cache when new message arrives
    Performance.invalidate_cache(session_id)

    # Record the message with Director
    :ok = Director.process_user_message(session_id, message)

    # MULTI-AGENT: Gather insights from all observers in parallel
    # This is the synchronization barrier - we wait for all agents before deciding
    # PHASE 7: Use 4 second timeout to leave room for response generation
    # PHASE 4: Get timeout from domain config if available
    timeout = get_config_timeout(session_id, :gather_insights_ms, 4_000)
    insights = gather_insights(session_id, timeout: timeout)

    # Get Director's next action, informed by agent insights
    action = Director.get_next_action(session_id, insights)

    # Handle the action
    result = handle_action(session_id, action)

    # PHASE 7: Record timing
    Performance.record_end(op_id)

    result
  end

  @doc """
  Gather insights from all observer agents with timeout.

  Triggers parallel analysis and waits for results. Returns a consolidated
  map of insights from all agents:

    %{
      themes: [%{theme: "...", evidence: "...", confidence: 0.8}, ...],
      probes: [%{topic: "...", rationale: "...", priority: :high}, ...],
      engagement: %{level: :high, trend: :stable, recommendation: "..."}
    }

  If an agent times out, partial results from other agents are still included.
  """
  def gather_insights(session_id, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 4_000)

    # PHASE 7: Track insight gathering time
    op_id = Performance.record_start(:gather_insights, %{session_id: session_id})

    # Start parallel tasks for each observer agent with circuit breaker protection
    tasks = [
      Task.async(fn -> {:themes, get_story_analyst_insights_safe(session_id)} end),
      Task.async(fn -> {:probes, get_probe_coach_insights_safe(session_id)} end),
      Task.async(fn -> {:engagement, get_engagement_insights_safe(session_id)} end)
    ]

    # Wait for all tasks with timeout
    results = Task.yield_many(tasks, timeout)

    # Collect results, using defaults for timed-out tasks
    insights = Enum.reduce(results, %{themes: [], probes: [], engagement: default_engagement()}, fn
      {_task, {:ok, {key, value}}}, acc ->
        Map.put(acc, key, value)

      {_task, {:exit, reason}}, acc ->
        Logger.warning("[Session] Agent task failed: #{inspect(reason)}")
        acc

      {task, nil}, acc ->
        # Task timed out - kill it and use default
        Task.shutdown(task, :brutal_kill)
        Logger.warning("[Session] Agent task timed out")
        acc
    end)

    # PHASE 7: Record timing
    Performance.record_end(op_id)

    Logger.debug("[Session] Gathered insights: #{inspect(insights, pretty: true, limit: 3)}")
    insights
  end

  # PHASE 7: Wrapped insight getters with circuit breakers and caching

  defp get_story_analyst_insights_safe(session_id) do
    # Check cache first
    case Performance.get_cached_insights(session_id, :story_analyst) do
      {:ok, cached} -> cached
      :miss ->
        # Use circuit breaker
        case Performance.with_circuit_breaker(:story_analyst, fn ->
          get_story_analyst_insights(session_id)
        end) do
          {:ok, insights} ->
            Performance.cache_insights(session_id, :story_analyst, insights)
            insights
          {:error, :circuit_open} ->
            Logger.warning("[Session] Story Analyst circuit open, using empty themes")
            []
          {:error, _} ->
            []
        end
    end
  end

  defp get_probe_coach_insights_safe(session_id) do
    case Performance.get_cached_insights(session_id, :probe_coach) do
      {:ok, cached} -> cached
      :miss ->
        case Performance.with_circuit_breaker(:probe_coach, fn ->
          get_probe_coach_insights(session_id)
        end) do
          {:ok, insights} ->
            Performance.cache_insights(session_id, :probe_coach, insights)
            insights
          {:error, :circuit_open} ->
            Logger.warning("[Session] Probe Coach circuit open, using empty probes")
            []
          {:error, _} ->
            []
        end
    end
  end

  defp get_engagement_insights_safe(session_id) do
    # Engagement doesn't use LLM, so no caching needed, but still use circuit breaker
    case Performance.with_circuit_breaker(:engagement_monitor, fn ->
      get_engagement_insights(session_id)
    end) do
      {:ok, insights} -> insights
      {:error, _} -> default_engagement()
    end
  end

  defp get_story_analyst_insights(session_id) do
    try do
      # Request fresh analysis and get current themes
      case StoryAnalyst.analyze_now(session_id) do
        {:ok, themes} -> themes
        {:error, _} -> StoryAnalyst.get_themes(session_id)
      end
    rescue
      _ -> []
    end
  end

  defp get_probe_coach_insights(session_id) do
    try do
      # Request fresh analysis and get current probes
      case ProbeCoach.analyze_now(session_id) do
        {:ok, probes} -> probes
        {:error, _} -> ProbeCoach.get_pending_probes(session_id)
      end
    rescue
      _ -> []
    end
  end

  defp get_engagement_insights(session_id) do
    try do
      # Engagement Monitor is already synchronous (no LLM)
      state = EngagementMonitor.get_state(session_id)
      %{
        level: state.level,
        trend: state.trend,
        indicators: state.indicators,
        recommendation: engagement_recommendation(state.level, state.trend)
      }
    rescue
      _ -> default_engagement()
    end
  end

  defp default_engagement do
    %{level: :medium, trend: :stable, indicators: %{}, recommendation: "Monitor and adjust"}
  end

  defp engagement_recommendation(level, trend) do
    case {level, trend} do
      {:critical, _} -> "Wrap up or change topic - user wants to finish"
      {:low, :declining} -> "Try a different approach or easier question"
      {:low, _} -> "Keep questions light and build rapport"
      {:medium, :declining} -> "Engagement dropping, consider more engaging topic"
      {:high, _} -> "Good engagement, lean in and go deeper"
      _ -> "Monitor and adjust as needed"
    end
  end

  @doc """
  Transition the session to a new phase.
  """
  def transition_to(session_id, phase, reason \\ "Manual transition") do
    Director.transition(session_id, phase, reason)
  end

  @doc """
  Get the current phase of the session.
  Returns {:ok, phase} or {:error, reason}
  """
  def current_phase(session_id) do
    {:ok, Director.current_phase(session_id)}
  rescue
    _ -> {:error, :not_found}
  end

  # Private functions
  # Note: Agent start/stop moved to AgentSupervisor for Phase 7 failure isolation

  defp get_current_phase(session_id) do
    case Director.current_phase(session_id) do
      phase when is_atom(phase) -> phase
      _ -> :unknown
    end
  rescue
    _ -> :unknown
  end

  defp get_director_state(session_id) do
    Director.get_state(session_id)
  rescue
    _ -> nil
  end

  defp get_scribe_state(session_id) do
    Scribe.get_state(session_id)
  rescue
    _ -> nil
  end

  defp get_engagement_level(session_id) do
    EngagementMonitor.get_level(session_id)
  rescue
    _ -> :unknown
  end

  # PHASE 4: Config-driven action dispatch
  defp handle_action(session_id, %{type: action_type} = action) do
    # Get domain config for action fallbacks
    domain = DomainLoader.get_session_domain(session_id)
    action_config = if domain, do: DomainLoader.get_action(domain, action_type), else: nil

    case action_type do
      :transition -> do_transition(session_id, action)
      :ask -> do_ask(session_id, action, action_config)
      :ask_dynamic -> do_ask_dynamic(session_id, action, action_config)
      :probe -> do_probe(session_id, action, action_config)
      :synthesize -> do_synthesize(session_id, action, action_config)
      :close -> do_close(session_id, action, action_config)
      :wait -> {:ok, nil}
      _ ->
        Logger.warning("[Session] Unknown action type: #{inspect(action)}")
        {:ok, nil}
    end
  end

  defp do_transition(session_id, %{to_phase: phase, reason: reason} = _action) do
    # Director now owns the FSM — transition validates and updates phase in one call
    result = try do
      Director.transition(session_id, phase, reason)
    catch
      :exit, {:shutdown, _} ->
        Logger.debug("[Session] Director shutting down during transition to #{phase} - session closing")
        {:ok, phase}
      :exit, :shutdown ->
        Logger.debug("[Session] Director shutdown during transition to #{phase} - session closing")
        {:ok, phase}
      :exit, {:noproc, _} ->
        Logger.debug("[Session] Director not found during transition to #{phase} - session already closed")
        {:ok, phase}
    end

    case result do
      {:ok, ^phase} ->
        # After transitioning, get the next action (question/probe/etc)
        # This ensures we ask the first question after entering a new phase
        if phase in [:opening, :core_questions, :probing, :synthesis, :closing] do
          try do
            action = Director.get_next_action(session_id)
            handle_action(session_id, action)
          catch
            :exit, _ -> {:ok, nil}  # Session closing, no more actions needed
          end
        else
          {:ok, nil}
        end
      {:ok, _other_phase} ->
        {:ok, nil}
      {:error, err} ->
        {:error, err}
    end
  end

  defp do_ask(session_id, %{question: question} = action, _action_config) do
    context = Map.take(action, [:question, :question_id, :source])

    case Director.generate_response(session_id, :ask, context) do
      {:ok, response} ->
        Director.record_host_message(session_id, response)
        publish_host_utterance(response, action, session_id)
        {:ok, response}
      {:error, _reason} ->
        # Fallback to the raw question
        Director.record_host_message(session_id, question)
        publish_host_utterance(question, action, session_id)
        {:ok, question}
    end
  end

  # DYNAMIC QUESTION - Generated from collective agent intelligence
  # This is where multi-agent collaboration produces emergent questions
  defp do_ask_dynamic(session_id, action, action_config) do
    # Pass all context to Director for dynamic generation
    context = Map.take(action, [:topic, :themes, :probes, :engagement, :source])

    Logger.debug("[Session] Generating dynamic question for topic: #{action.topic}")

    case Director.generate_response(session_id, :ask_dynamic, context) do
      {:ok, response} ->
        Director.record_host_message(session_id, response)
        publish_host_utterance(response, action, session_id)
        {:ok, response}
      {:error, reason} ->
        # PHASE 4: Fallback from config
        Logger.warning("[Session] Dynamic generation failed: #{inspect(reason)}, using fallback")
        fallback = get_topic_fallback(action.topic, action_config)
        Director.record_host_message(session_id, fallback)
        publish_host_utterance(fallback, action, session_id)
        {:ok, fallback}
    end
  end

  defp do_probe(session_id, %{question: question, topic: topic} = _action, _action_config) do
    context = %{question: question, topic: topic}

    case Director.generate_response(session_id, :probe, context) do
      {:ok, response} ->
        Director.record_host_message(session_id, response)
        publish_host_utterance(response, %{type: :probe, topic: topic}, session_id)
        {:ok, response}
      {:error, _reason} ->
        Director.record_host_message(session_id, question)
        publish_host_utterance(question, %{type: :probe, topic: topic}, session_id)
        {:ok, question}
    end
  end

  defp do_synthesize(session_id, %{themes: themes} = _action, action_config) do
    context = %{themes: themes}

    case Director.generate_response(session_id, :synthesize, context) do
      {:ok, response} ->
        Director.record_host_message(session_id, response)
        publish_host_utterance(response, %{type: :synthesize}, session_id)
        {:ok, response}
      {:error, _reason} ->
        # PHASE 4: Fallback from config
        fallback = get_action_fallback(action_config, :fallback_message,
          "I've really enjoyed learning about you. Let me share what I've heard...")
        Director.record_host_message(session_id, fallback)
        publish_host_utterance(fallback, %{type: :synthesize}, session_id)
        {:ok, fallback}
    end
  end

  defp do_close(session_id, _action, action_config) do
    case Director.generate_response(session_id, :close, %{}) do
      {:ok, response} ->
        Director.record_host_message(session_id, response)
        publish_host_utterance(response, %{type: :close}, session_id)
        {:ok, response}
      {:error, _reason} ->
        # PHASE 4: Fallback from config
        fallback = get_action_fallback(action_config, :fallback_message,
          "Thank you so much for sharing your story with me. This has been wonderful!")
        Director.record_host_message(session_id, fallback)
        publish_host_utterance(fallback, %{type: :close}, session_id)
        {:ok, fallback}
    end
  end

  # PHASE 4: Get topic fallback from config
  defp get_topic_fallback(topic, nil), do: default_topic_fallback(topic)
  defp get_topic_fallback(topic, action_config) do
    topic_fallbacks = action_config[:topic_fallbacks] || %{}
    Map.get(topic_fallbacks, topic) ||
      Map.get(topic_fallbacks, :default) ||
      default_topic_fallback(topic)
  end

  # Default fallbacks (used when config not available)
  defp default_topic_fallback(:origin) do
    "I'd love to hear about your background - how did you get to where you are today?"
  end
  defp default_topic_fallback(:passion) do
    "What drives you? What are you most passionate about in your work?"
  end
  defp default_topic_fallback(:differentiation) do
    "What would you say makes your approach or perspective unique?"
  end
  defp default_topic_fallback(:moments) do
    "Was there a pivotal moment or turning point that really shaped who you've become?"
  end
  defp default_topic_fallback(:vision) do
    "Where are you headed? What's the vision you're working toward?"
  end
  defp default_topic_fallback(_topic) do
    "Tell me more about that - I'd love to hear your thoughts."
  end

  # PHASE 4: Get action fallback from config
  defp get_action_fallback(nil, _key, default), do: default
  defp get_action_fallback(action_config, key, default) do
    action_config[key] || default
  end

  # PHASE 4: Get timeout from domain config
  defp get_config_timeout(session_id, key, default) do
    case DomainLoader.get_session_domain(session_id) do
      nil -> default
      domain ->
        action_config = DomainLoader.get_action(domain, :ask_dynamic)
        if action_config do
          timeouts = domain.actions[:timeouts] || %{}
          timeouts[key] || default
        else
          default
        end
    end
  end

  defp publish_host_utterance(content, action, _session_id) do
    # Phase 5: Include attribution data for debug panel visibility
    signal = %Jido.Signal{
      type: "interview.utterance.host",
      source: "director",
      id: Jido.Util.generate_id(),
      data: %{
        content: content,
        timestamp: DateTime.utc_now(),
        action_type: action[:type],
        question_id: action[:question_id],
        # Attribution data for Phase 5 UI visibility
        action_source: action[:source],
        topic: action[:topic],
        themes_used: extract_theme_names(action[:themes]),
        probes_used: extract_probe_topics(action[:probes]),
        engagement: action[:engagement],
        consensus: action[:consensus],
        votes: action[:votes]
      }
    }
    InterviewBus.publish(signal)
  end

  defp extract_theme_names(nil), do: []
  defp extract_theme_names(themes) when is_list(themes) do
    Enum.map(themes, fn t -> t[:theme] || t.theme || "unknown" end) |> Enum.take(5)
  end
  defp extract_theme_names(_), do: []

  defp extract_probe_topics(nil), do: []
  defp extract_probe_topics(probes) when is_list(probes) do
    Enum.map(probes, fn p -> p[:topic] || p.topic || "unknown" end) |> Enum.take(3)
  end
  defp extract_probe_topics(_), do: []

  defp generate_session_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end
end
