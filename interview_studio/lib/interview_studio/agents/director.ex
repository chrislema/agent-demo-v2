defmodule InterviewStudio.Agents.Director do
  @moduledoc """
  The Director Agent - the orchestrator and user-facing voice.

  Merged with InterviewFSM for phase management.
  Converted to Jido.Agent with signal_routes and Actions.

  Responsibilities:
  - Formulate natural, warm questions
  - Decide whether to follow script, probe deeper, or transition
  - Synthesize swarm input into conversational decisions
  - Maintain interview flow and pacing
  - Validate and execute phase transitions (previously InterviewFSM)
  """

  use Jido.Agent,
    name: "director",
    description: "Orchestrates interview flow, generates questions, manages phase transitions",
    schema: [
      session_id: [type: :any, default: nil],
      current_phase: [type: :atom, default: :preparation],
      topics_explored: [type: :any, default: []],
      topics_to_explore: [type: :any, default: []],
      active_themes: [type: :any, default: []],
      pending_probes: [type: :any, default: []],
      engagement_level: [type: :atom, default: :high],
      conversation_history: [type: :any, default: []],
      last_user_message: [type: :any, default: nil],
      llm_config: [type: :any, default: %{}],
      synthesis_delivered: [type: :boolean, default: false],
      user_responded_to_synthesis: [type: :boolean, default: false],
      last_insights: [type: :any, default: %{}],
      questions_asked: [type: :any, default: []],
      frustration_level: [type: :atom, default: :none],
      user_intent: [type: :atom, default: :continue],
      chronological_direction: [type: :atom, default: :neutral],
      config: [type: :any, default: %{}],
      domain: [type: :any, default: nil],
      heuristics: [type: :any, default: %{}],
      # FSM fields (merged from InterviewFSM)
      phase_history: [type: :any, default: []],
      phase_started_at: [type: :any, default: nil],
      # Result fields for sync call extraction
      last_action_result: [type: :any, default: nil],
      last_response_result: [type: :any, default: nil],
      last_transition_result: [type: :any, default: nil],
      last_votes_result: [type: :any, default: nil],
      last_consensus_result: [type: :any, default: nil]
    ],
    signal_routes: [
      # Async observer signals
      {"interview.phase.entered", InterviewStudio.Agents.Director.Actions.HandlePhaseEntered},
      {"interview.phase.changed", InterviewStudio.Agents.Director.Actions.HandlePhaseEntered},
      {"observer.insight.theme", InterviewStudio.Agents.Director.Actions.HandleInsightTheme},
      {"observer.suggestion.probe", InterviewStudio.Agents.Director.Actions.HandleSuggestionProbe},
      {"observer.status.engagement", InterviewStudio.Agents.Director.Actions.HandleEngagementStatus},
      {"observer.status.frustration", InterviewStudio.Agents.Director.Actions.HandleFrustrationStatus},
      {"observer.status.sentiment", InterviewStudio.Agents.Director.Actions.HandleSentimentStatus},
      {"observer.status.timer", InterviewStudio.Agents.Director.Actions.HandleTimerStatus},
      # Sync command signals
      {"director.cmd.user_message", InterviewStudio.Agents.Director.Actions.ProcessUserMessage},
      {"director.cmd.next_action", InterviewStudio.Agents.Director.Actions.DecideNextAction},
      {"director.cmd.generate_response", InterviewStudio.Agents.Director.Actions.GenerateResponse},
      {"director.cmd.set_phase", InterviewStudio.Agents.Director.Actions.SetPhase},
      {"director.cmd.host_message", InterviewStudio.Agents.Director.Actions.RecordHostMessage},
      {"director.cmd.transition", InterviewStudio.Agents.Director.Actions.TransitionPhase},
      {"director.cmd.poll_transition", InterviewStudio.Agents.Director.Actions.PollTransition},
      {"director.cmd.check_consensus", InterviewStudio.Agents.Director.Actions.CheckConsensus}
    ]

  require Logger

  alias InterviewStudio.InterviewBus
  alias InterviewStudio.Pipeline.Phases
  alias InterviewStudio.ConfigLoader
  alias InterviewStudio.DomainLoader

  # FSM transition map (merged from InterviewFSM)
  @transitions %{
    preparation: [:opening],
    opening: [:core_questions],
    core_questions: [:probing, :synthesis, :closing],
    probing: [:core_questions, :synthesis, :closing],
    synthesis: [:closing],
    closing: []
  }

  # Default config (used if YAML file not found)
  @default_config %{
    topic_descriptions: %{
      origin: "their ORIGIN STORY - their professional journey, how they got into this field, the path that led them here",
      passion: "their PASSION - what drives them, what they care deeply about",
      differentiation: "what makes them UNIQUE - their distinctive approach or perspective",
      moments: "PIVOTAL MOMENTS - turning points that shaped who they became",
      vision: "their VISION - where they're headed, what they're working toward"
    },
    engagement_guidance: %{
      high: "User is highly engaged - lean in!",
      medium: "User engagement is moderate - balance depth with accessibility.",
      low: "User engagement is lower - keep it lighter.",
      critical: "User seems ready to wrap up.",
      default: "Adjust your approach based on the conversation flow."
    },
    frustration_guidance: %{
      high: "CRITICAL: User is frustrated. Ask about something COMPLETELY DIFFERENT.",
      moderate: "User seems a bit irritated. Pivot to a fresh topic.",
      mild: "User may be getting impatient. Keep your question short.",
      default: "Sentiment is neutral - proceed normally."
    },
    chronological_guidance: %{
      forward: "User is talking about future/current work - RESPECT THIS MOMENTUM.",
      backward: "User is discussing their past. Look for opportunities to bridge to the present/future.",
      neutral: "No strong chronological preference - follow the natural flow of conversation."
    }
  }

  # ==========================================================================
  # Client API
  # ==========================================================================

  def start_link(opts \\ []) do
    session_id = Keyword.fetch!(opts, :session_id)
    llm_config = Keyword.get(opts, :llm_config, default_llm_config())
    domain = Keyword.get(opts, :domain)

    heuristics = if domain do
      DomainLoader.get_heuristics(domain, :director)
    else
      %{}
    end

    config = ConfigLoader.load_with_defaults(:director, @default_config)
    config = deep_merge_config(config, heuristics)

    core_categories = if domain do
      domain.phases[:core_categories] || Phases.core_categories()
    else
      Phases.core_categories()
    end

    now = DateTime.utc_now()

    {:ok, pid} = Jido.AgentServer.start_link(
      agent: __MODULE__,
      name: via_tuple(session_id),
      id: "director_#{session_id}",
      register_global: false,
      initial_state: %{
        session_id: session_id,
        topics_to_explore: core_categories,
        llm_config: llm_config,
        config: config,
        domain: domain,
        heuristics: heuristics,
        phase_started_at: now
      }
    )

    # Subscribe to InterviewBus signals
    subscribe_to_signals(domain, pid)

    # Emit initial phase entered signal
    emit_phase_entered_signal(:preparation)

    Logger.info("[Director] Started for session #{session_id} (domain: #{domain && domain.name || "default"})")
    {:ok, pid}
  end

  def get_state(session_id) do
    get_agent_state(session_id)
  end

  def process_user_message(session_id, message) do
    case send_cmd_signal(session_id, "director.cmd.user_message", %{content: message}, 30_000) do
      {:ok, _agent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def get_next_action(session_id, insights \\ %{}) do
    case send_cmd_signal(session_id, "director.cmd.next_action", %{insights: insights}, 30_000) do
      {:ok, agent} -> agent.state.last_action_result || %{type: :wait}
      {:error, _reason} -> %{type: :wait}
    end
  end

  def generate_response(session_id, action_type, context) do
    case send_cmd_signal(session_id, "director.cmd.generate_response", %{action_type: action_type, context: context}, 60_000) do
      {:ok, agent} -> agent.state.last_response_result || {:error, "No response"}
      {:error, reason} -> {:error, reason}
    end
  end

  def set_phase(session_id, phase) do
    case send_cmd_signal(session_id, "director.cmd.set_phase", %{phase: phase}) do
      {:ok, _agent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def record_host_message(session_id, message) do
    case send_cmd_signal(session_id, "director.cmd.host_message", %{content: message}) do
      {:ok, _agent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Execute a phase transition (replaces InterviewFSM.transition).
  Returns {:ok, phase} or {:error, reason}.
  """
  def transition(session_id, to_phase, reason \\ "requested") do
    case send_cmd_signal(session_id, "director.cmd.transition", %{to_phase: to_phase, reason: reason}, 10_000) do
      {:ok, agent} -> agent.state.last_transition_result || {:error, "Transition failed"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Get the current phase (replaces InterviewFSM.current_phase).
  """
  def current_phase(session_id) do
    state = get_agent_state(session_id)
    state.current_phase
  end

  @doc """
  Check if a transition to the target phase is valid from the current phase.
  """
  def can_transition?(session_id, to_phase) do
    state = get_agent_state(session_id)
    valid_transition?(state.current_phase, to_phase)
  end

  def poll_transition_readiness(session_id, target_phase) do
    case send_cmd_signal(session_id, "director.cmd.poll_transition", %{target_phase: target_phase}, 10_000) do
      {:ok, agent} -> agent.state.last_votes_result || %{}
      {:error, _reason} -> %{}
    end
  end

  def check_transition_consensus(session_id, target_phase) do
    case send_cmd_signal(session_id, "director.cmd.check_consensus", %{target_phase: target_phase}, 10_000) do
      {:ok, agent} -> agent.state.last_consensus_result || {:no_consensus, %{}}
      {:error, _reason} -> {:no_consensus, %{}}
    end
  end

  # ==========================================================================
  # Shared Helpers (public for Actions to call)
  # ==========================================================================

  def valid_transition?(from_phase, to_phase) do
    to_phase in Map.get(@transitions, from_phase, [])
  end

  def valid_transitions_from(phase) do
    Map.get(@transitions, phase, [])
  end

  def gather_transition_votes(session_id, target_phase) do
    alias InterviewStudio.Agents.{StoryAnalyst, ProbeCoach, EngagementMonitor}

    tasks = [
      Task.async(fn -> {:story_analyst, safe_vote(StoryAnalyst, session_id, target_phase)} end),
      Task.async(fn -> {:probe_coach, safe_vote(ProbeCoach, session_id, target_phase)} end),
      Task.async(fn -> {:engagement_monitor, safe_vote(EngagementMonitor, session_id, target_phase)} end)
    ]

    results = Task.yield_many(tasks, 3_000)

    results
    |> Enum.map(fn {task, result} ->
      case result do
        {:ok, {agent, vote}} -> {agent, vote}
        {:exit, _reason} -> {:unknown, {:abstain, "Agent failed to respond"}}
        nil ->
          Task.shutdown(task, :brutal_kill)
          {:unknown, {:abstain, "Agent timed out"}}
      end
    end)
    |> Enum.into(%{})
  end

  def evaluate_consensus(votes, target_phase, state) do
    ready_count = Enum.count(votes, fn {_agent, {vote, _}} -> vote == :ready end)
    not_ready_count = Enum.count(votes, fn {_agent, {vote, _}} -> vote == :not_ready end)

    weighted_votes = apply_vote_weights(votes, target_phase, state)

    cond do
      ready_count >= 2 -> {:consensus, votes}
      ready_count > not_ready_count -> {:consensus, votes}
      weighted_votes.weighted_ready > weighted_votes.threshold -> {:consensus, votes}
      true -> {:no_consensus, votes}
    end
  end

  def emit_phase_entered_signal(phase) do
    signal = %Jido.Signal{
      type: "interview.phase.entered",
      source: "director",
      id: Jido.Util.generate_id(),
      data: %{
        phase_name: phase,
        timestamp: DateTime.utc_now(),
        context: %{}
      }
    }
    InterviewBus.publish(signal)
  end

  def emit_phase_completed_signal(phase, summary) do
    next_phase = case Map.get(@transitions, phase, []) do
      [first | _] -> first
      [] -> nil
    end

    signal = %Jido.Signal{
      type: "interview.phase.completed",
      source: "director",
      id: Jido.Util.generate_id(),
      data: %{
        phase_name: phase,
        summary: summary,
        next_phase: next_phase,
        timestamp: DateTime.utc_now()
      }
    }
    InterviewBus.publish(signal)
  end

  def emit_disagreement_signal(target_phase, votes) do
    signal = %Jido.Signal{
      type: "director.consensus.disagreement",
      source: "director",
      id: Jido.Util.generate_id(),
      data: %{
        target_phase: target_phase,
        votes: format_votes_for_signal(votes),
        resolution: :director_override,
        timestamp: DateTime.utc_now()
      }
    }
    InterviewBus.publish(signal)
  end

  def get_current_engagement(session_id) do
    alias InterviewStudio.Agents.EngagementMonitor
    try do
      EngagementMonitor.get_level(session_id)
    rescue
      _ -> :medium
    catch
      :exit, _ -> :medium
    end
  end

  def deep_merge_config(base, override) when is_map(base) and is_map(override) do
    Map.merge(base, override, fn
      _k, base_val, override_val when is_map(base_val) and is_map(override_val) ->
        deep_merge_config(base_val, override_val)
      _k, _base_val, override_val ->
        override_val
    end)
  end
  def deep_merge_config(_base, override), do: override

  def default_llm_config do
    %{
      provider: :openrouter,
      model: "meta-llama/llama-4-scout-17b-16e-instruct",
      temperature: 0.7
    }
  end

  # ==========================================================================
  # Private Helpers
  # ==========================================================================

  defp get_agent_state(session_id) do
    {:ok, server_state} = Jido.AgentServer.state(via_tuple(session_id))
    server_state.agent.state
  end

  defp via_tuple(session_id) do
    {:via, Registry, {InterviewStudio.SessionRegistry, {:director, session_id}}}
  end

  defp send_cmd_signal(session_id, type, data, timeout \\ 10_000) do
    signal = %Jido.Signal{
      type: type,
      source: "session",
      id: Jido.Util.generate_id(),
      data: data,
      time: DateTime.utc_now()
    }
    GenServer.call(via_tuple(session_id), {:signal, signal}, timeout)
  end

  defp subscribe_to_signals(nil, pid) do
    InterviewBus.subscribe_pid("interview.phase.**", pid)
    InterviewBus.subscribe_pid("observer.insight.**", pid)
    InterviewBus.subscribe_pid("observer.suggestion.**", pid)
    InterviewBus.subscribe_pid("observer.status.**", pid)
  end

  defp subscribe_to_signals(domain, pid) do
    subscriptions = DomainLoader.get_subscriptions(domain, :director)

    if subscriptions == [] do
      subscribe_to_signals(nil, pid)
    else
      Enum.each(subscriptions, fn pattern ->
        InterviewBus.subscribe_pid(pattern, pid)
      end)
    end
  end

  defp safe_vote(agent_module, session_id, target_phase) do
    try do
      agent_module.vote_transition(session_id, target_phase)
    rescue
      _ -> {:abstain, "Agent error"}
    catch
      :exit, _ -> {:abstain, "Agent unavailable"}
    end
  end

  defp apply_vote_weights(votes, target_phase, state) do
    consensus_config = if state[:domain] do
      DomainLoader.get_consensus_weights(state[:domain], target_phase)
    else
      %{weights: default_consensus_weights(target_phase), threshold: 0.6}
    end

    weights = consensus_config[:weights] || default_consensus_weights(target_phase)
    threshold_pct = consensus_config[:threshold] || 0.6

    weighted_ready = votes
    |> Enum.reduce(0.0, fn {agent, {vote, _}}, acc ->
      weight = Map.get(weights, agent, 1.0)
      case vote do
        :ready -> acc + weight
        _ -> acc
      end
    end)

    total_weight = weights |> Map.values() |> Enum.sum()
    threshold = total_weight * threshold_pct

    %{weighted_ready: weighted_ready, threshold: threshold, weights: weights}
  end

  defp default_consensus_weights(:closing) do
    %{story_analyst: 1.0, probe_coach: 1.0, engagement_monitor: 2.0}
  end
  defp default_consensus_weights(:synthesis) do
    %{story_analyst: 1.5, probe_coach: 1.0, engagement_monitor: 1.0}
  end
  defp default_consensus_weights(:probing) do
    %{story_analyst: 1.0, probe_coach: 1.5, engagement_monitor: 1.0}
  end
  defp default_consensus_weights(_) do
    %{story_analyst: 1.0, probe_coach: 1.0, engagement_monitor: 1.0}
  end

  defp format_votes_for_signal(votes) do
    votes
    |> Enum.map(fn {agent, {vote, rationale}} ->
      %{agent: agent, vote: vote, rationale: rationale}
    end)
  end
end

# =============================================================================
# ASYNC SIGNAL HANDLERS
# =============================================================================

defmodule InterviewStudio.Agents.Director.Actions.HandlePhaseEntered do
  @moduledoc "Updates Director state when a phase.entered signal arrives."

  use Jido.Action,
    name: "director_handle_phase_entered",
    description: "Update current phase from phase entered signal",
    schema: [
      phase_name: [type: :any, default: nil],
      phase: [type: :any, default: nil],
      to_phase: [type: :any, default: nil],
      timestamp: [type: :any, default: nil],
      context: [type: :any, default: nil]
    ]

  @impl true
  def run(params, context) do
    phase = params[:phase_name] || params[:phase] || params[:to_phase]

    if phase && phase != context.state.current_phase do
      {:ok, %{current_phase: phase, phase_started_at: DateTime.utc_now()}}
    else
      {:ok, %{}}
    end
  end
end

defmodule InterviewStudio.Agents.Director.Actions.HandleInsightTheme do
  @moduledoc "Merges a discovered theme into active_themes."

  use Jido.Action,
    name: "director_handle_insight_theme",
    description: "Add discovered theme to active themes",
    schema: [
      theme: [type: :any, default: nil],
      evidence: [type: :any, default: nil],
      confidence: [type: :any, default: nil]
    ]

  require Logger

  @impl true
  def run(params, context) do
    theme = %{
      theme: params[:theme],
      evidence: params[:evidence],
      confidence: params[:confidence]
    }
    Logger.debug("[Director] Theme received: #{params[:theme]}")

    updated = [theme | context.state.active_themes || []] |> Enum.take(10)
    {:ok, %{active_themes: updated}}
  end
end

defmodule InterviewStudio.Agents.Director.Actions.HandleSuggestionProbe do
  @moduledoc "Adds a suggested probe to pending_probes."

  use Jido.Action,
    name: "director_handle_suggestion_probe",
    description: "Add suggested probe to pending probes",
    schema: [
      topic: [type: :any, default: nil],
      suggested_question: [type: :any, default: nil],
      rationale: [type: :any, default: nil],
      priority: [type: :any, default: nil]
    ]

  require Logger

  @impl true
  def run(params, context) do
    probe = %{
      topic: params[:topic],
      question: params[:suggested_question],
      rationale: params[:rationale],
      priority: params[:priority] || :medium
    }
    Logger.debug("[Director] Probe suggested: #{probe.topic}")

    probes = [probe | context.state.pending_probes || []]
    |> Enum.sort_by(fn p ->
      case p.priority do
        :high -> 0
        :medium -> 1
        :low -> 2
        _ -> 1
      end
    end)
    |> Enum.take(5)

    {:ok, %{pending_probes: probes}}
  end
end

defmodule InterviewStudio.Agents.Director.Actions.HandleEngagementStatus do
  @moduledoc "Updates engagement level from engagement monitor signal."

  use Jido.Action,
    name: "director_handle_engagement_status",
    description: "Update engagement level",
    schema: [
      level: [type: :any, default: nil]
    ]

  require Logger

  @impl true
  def run(params, _context) do
    level = params[:level]
    Logger.debug("[Director] Engagement status: #{level}")
    {:ok, %{engagement_level: level}}
  end
end

defmodule InterviewStudio.Agents.Director.Actions.HandleFrustrationStatus do
  @moduledoc "Updates frustration level from sentiment agent signal."

  use Jido.Action,
    name: "director_handle_frustration_status",
    description: "Update frustration level",
    schema: [
      level: [type: :any, default: nil]
    ]

  require Logger

  @impl true
  def run(params, _context) do
    level = params[:level] || :none
    Logger.info("[Director] Frustration detected: #{level}")
    {:ok, %{frustration_level: level}}
  end
end

defmodule InterviewStudio.Agents.Director.Actions.HandleSentimentStatus do
  @moduledoc "Updates semantic sentiment data (intent, chronological direction, frustration)."

  use Jido.Action,
    name: "director_handle_sentiment_status",
    description: "Update sentiment data",
    schema: [
      user_intent: [type: :any, default: nil],
      chronological_direction: [type: :any, default: nil],
      frustration_level: [type: :any, default: nil]
    ]

  require Logger

  @impl true
  def run(params, _context) do
    Logger.info("[Director] Semantic sentiment - intent: #{params[:user_intent]}, direction: #{params[:chronological_direction]}, frustration: #{params[:frustration_level]}")
    {:ok, %{
      user_intent: params[:user_intent],
      chronological_direction: params[:chronological_direction],
      frustration_level: params[:frustration_level]
    }}
  end
end

defmodule InterviewStudio.Agents.Director.Actions.HandleTimerStatus do
  @moduledoc "Handles timer milestone signals (informational, no state change)."

  use Jido.Action,
    name: "director_handle_timer_status",
    description: "Log timer update",
    schema: [
      elapsed_minutes: [type: :any, default: nil],
      milestone: [type: :any, default: nil],
      recommendation: [type: :any, default: nil]
    ]

  require Logger

  @impl true
  def run(params, _context) do
    Logger.debug("[Director] Timer update: #{params[:elapsed_minutes]} minutes elapsed")
    {:ok, %{}}
  end
end

# =============================================================================
# SYNC COMMAND ACTIONS
# =============================================================================

defmodule InterviewStudio.Agents.Director.Actions.ProcessUserMessage do
  @moduledoc "Records a user message and publishes the user utterance signal."

  use Jido.Action,
    name: "director_process_user_message",
    description: "Record user message and publish utterance signal",
    schema: [
      content: [type: :any, default: nil]
    ]

  require Logger

  alias InterviewStudio.InterviewBus

  @impl true
  def run(params, context) do
    state = context.state
    content = params[:content] || ""

    if content == "" or content == nil do
      {:ok, %{}}
    else
      Logger.debug("[Director] Processing user message: #{String.slice(content, 0, 50)}...")

      timestamp = DateTime.utc_now()
      entry = %{role: :user, content: content, timestamp: timestamp}

      new_history = [entry | state.conversation_history || []]

      # Publish user utterance signal
      publish_user_utterance(content, state.current_phase)

      changes = %{
        conversation_history: new_history,
        last_user_message: content
      }

      # Track if user responded after synthesis was delivered
      changes = if state.current_phase == :synthesis and state.synthesis_delivered do
        Map.put(changes, :user_responded_to_synthesis, true)
      else
        changes
      end

      {:ok, changes}
    end
  end

  defp publish_user_utterance(content, phase) do
    signal = %Jido.Signal{
      type: "interview.utterance.user",
      source: "director",
      id: Jido.Util.generate_id(),
      data: %{
        content: content,
        timestamp: DateTime.utc_now(),
        phase_context: phase
      }
    }
    InterviewBus.publish(signal)
  end
end

defmodule InterviewStudio.Agents.Director.Actions.SetPhase do
  @moduledoc "Directly sets the current phase."

  use Jido.Action,
    name: "director_set_phase",
    description: "Set the current interview phase",
    schema: [
      phase: [type: :any, default: nil]
    ]

  require Logger

  @impl true
  def run(params, _context) do
    phase = params[:phase]
    Logger.debug("[Director] Phase set directly to: #{phase}")
    {:ok, %{current_phase: phase}}
  end
end

defmodule InterviewStudio.Agents.Director.Actions.RecordHostMessage do
  @moduledoc "Records a host message in conversation history."

  use Jido.Action,
    name: "director_record_host_message",
    description: "Record host message to conversation history",
    schema: [
      content: [type: :any, default: nil]
    ]

  @impl true
  def run(params, context) do
    state = context.state
    content = params[:content] || ""
    timestamp = DateTime.utc_now()

    entry = %{role: :host, content: content, timestamp: timestamp}
    new_history = [entry | state.conversation_history || []]

    # Track question to prevent repetition (keep last 20)
    questions_asked = [content | state.questions_asked || []] |> Enum.take(20)

    {:ok, %{conversation_history: new_history, questions_asked: questions_asked}}
  end
end

defmodule InterviewStudio.Agents.Director.Actions.TransitionPhase do
  @moduledoc "Validates and executes a phase transition (replaces InterviewFSM)."

  use Jido.Action,
    name: "director_transition_phase",
    description: "Validate and execute phase transition",
    schema: [
      to_phase: [type: :any, default: nil],
      reason: [type: :any, default: "requested"]
    ]

  require Logger

  alias InterviewStudio.Agents.Director

  @impl true
  def run(params, context) do
    state = context.state
    to_phase = params[:to_phase]
    reason = params[:reason] || "requested"

    cond do
      # Idempotent: already in this phase
      state.current_phase == to_phase ->
        Logger.debug("[Director] Already in #{to_phase}, ignoring transition request")
        {:ok, %{last_transition_result: {:already_in_phase, to_phase}}}

      # Valid transition
      Director.valid_transition?(state.current_phase, to_phase) ->
        Logger.info("[Director] Transitioning from #{state.current_phase} to #{to_phase}: #{reason}")

        history_entry = %{
          phase: state.current_phase,
          started_at: state.phase_started_at,
          completed_at: DateTime.utc_now(),
          summary: reason
        }

        # Emit phase signals
        Director.emit_phase_completed_signal(state.current_phase, reason)
        Director.emit_phase_entered_signal(to_phase)

        {:ok, %{
          current_phase: to_phase,
          phase_started_at: DateTime.utc_now(),
          phase_history: [history_entry | state.phase_history || []],
          last_transition_result: {:ok, to_phase}
        }}

      # Invalid transition
      true ->
        reason_msg = "Invalid transition from #{state.current_phase} to #{to_phase}"
        Logger.warning("[Director] Transition denied: #{reason_msg}")
        {:ok, %{last_transition_result: {:error, reason_msg}}}
    end
  end
end

defmodule InterviewStudio.Agents.Director.Actions.PollTransition do
  @moduledoc "Gathers transition votes from all observer agents."

  use Jido.Action,
    name: "director_poll_transition",
    description: "Poll agents for transition readiness votes",
    schema: [
      target_phase: [type: :any, default: nil]
    ]

  require Logger

  alias InterviewStudio.Agents.Director

  @impl true
  def run(params, context) do
    state = context.state
    target_phase = params[:target_phase]
    votes = Director.gather_transition_votes(state.session_id, target_phase)
    Logger.debug("[Director] Polled transition votes for #{target_phase}: #{inspect(votes)}")
    {:ok, %{last_votes_result: votes}}
  end
end

defmodule InterviewStudio.Agents.Director.Actions.CheckConsensus do
  @moduledoc "Gathers votes and evaluates consensus for a phase transition."

  use Jido.Action,
    name: "director_check_consensus",
    description: "Check consensus for phase transition",
    schema: [
      target_phase: [type: :any, default: nil]
    ]

  require Logger

  alias InterviewStudio.Agents.Director

  @impl true
  def run(params, context) do
    state = context.state
    target_phase = params[:target_phase]
    votes = Director.gather_transition_votes(state.session_id, target_phase)
    result = Director.evaluate_consensus(votes, target_phase, state)
    Logger.debug("[Director] Consensus check for #{target_phase}: #{elem(result, 0)}")
    {:ok, %{last_consensus_result: result}}
  end
end

# =============================================================================
# DecideNextAction — the core decision engine
# =============================================================================

defmodule InterviewStudio.Agents.Director.Actions.DecideNextAction do
  @moduledoc """
  Merges parallel agent insights and decides the Director's next action.
  This is the heart of the multi-agent collaboration system.
  """

  use Jido.Action,
    name: "director_decide_next_action",
    description: "Merge insights from observers and decide next action",
    schema: [
      insights: [type: :any, default: %{}]
    ]

  require Logger

  alias InterviewStudio.Agents.Director
  alias InterviewStudio.Pipeline.Phases

  @impl true
  def run(params, context) do
    state = context.state
    insights = params[:insights] || %{}

    # Merge insights — compute state changes
    insight_changes = compute_insight_changes(state, insights)

    # Build working state for decision-making
    working_state = Map.merge(state, insight_changes)

    # Decide next action
    action = decide_next_action(working_state)

    # Compute action-related state changes
    action_changes = compute_action_changes(action, working_state)

    Logger.debug("[Director] Synthesized action from insights: #{inspect(action[:type])}")

    # Combine all changes + store action result
    all_changes = insight_changes
    |> Map.merge(action_changes)
    |> Map.put(:last_action_result, action)

    {:ok, all_changes}
  end

  # ---- Insight merging ----

  defp compute_insight_changes(state, insights) when map_size(insights) == 0 do
    current_engagement = Director.get_current_engagement(state.session_id)
    %{engagement_level: current_engagement}
  end

  defp compute_insight_changes(state, insights) do
    new_themes = Map.get(insights, :themes, [])
    merged_themes = merge_themes(state.active_themes || [], new_themes)

    new_probes = Map.get(insights, :probes, [])
    merged_probes = merge_probes(state.pending_probes || [], new_probes)

    engagement_data = Map.get(insights, :engagement, %{})
    engagement_level = Map.get(engagement_data, :level, state.engagement_level)

    Logger.debug("[Director] Merged insights - themes: #{length(merged_themes)}, probes: #{length(merged_probes)}, engagement: #{engagement_level}")

    %{
      active_themes: merged_themes,
      pending_probes: merged_probes,
      engagement_level: engagement_level,
      last_insights: insights
    }
  end

  defp merge_themes(existing, new) do
    (new ++ existing)
    |> Enum.uniq_by(fn t -> t[:theme] || t.theme end)
    |> Enum.take(10)
  end

  defp merge_probes(existing, new) do
    formatted_new = Enum.map(new, fn p ->
      %{
        topic: p[:topic] || p.topic,
        question: p[:suggested_question] || p[:question] || p.suggested_question,
        rationale: p[:rationale] || p.rationale,
        priority: p[:priority] || p.priority || :medium
      }
    end)

    (formatted_new ++ existing)
    |> Enum.uniq_by(fn p -> p.topic end)
    |> Enum.sort_by(fn p ->
      case p.priority do
        :high -> 0
        :medium -> 1
        :low -> 2
        _ -> 1
      end
    end)
    |> Enum.take(5)
  end

  # ---- Decision logic ----

  defp decide_next_action(state) do
    cond do
      # User explicitly wants to END the interview
      state.user_intent == :end_interview ->
        if state.current_phase in [:synthesis, :closing] do
          %{type: :transition, to_phase: :closing, reason: "User requested to end interview", consensus_override: :user_request}
        else
          %{type: :transition, to_phase: :synthesis, reason: "User requested to end interview", consensus_override: :user_request}
        end

      # User wants to CHANGE TOPIC (not end)
      state.user_intent == :change_topic ->
        handle_topic_change_request(state)

      # Critical engagement - wrap up
      state.engagement_level == :critical ->
        %{type: :transition, to_phase: :closing, reason: "Engagement dropped to critical level", consensus_override: :critical_engagement}

      # High frustration - move toward synthesis/closing
      state.frustration_level == :high and state.current_phase not in [:synthesis, :closing] ->
        %{type: :transition, to_phase: :synthesis, reason: "User frustration detected - moving to synthesis", consensus_override: :frustration_detected}

      # In preparation - auto-advance to opening
      state.current_phase == :preparation ->
        %{type: :transition, to_phase: :opening, reason: "Preparation complete"}

      # In opening - greet or move to core questions
      state.current_phase == :opening ->
        user_messages = Enum.filter(state.conversation_history || [], fn m ->
          m.role == :user and m.content != "" and m.content != nil
        end)
        if length(user_messages) >= 1 do
          maybe_transition_with_consensus(state, :core_questions, "Opening complete, user engaged")
        else
          question = get_opening_question()
          %{type: :ask, question: question, source: :question_bank}
        end

      # In core questions
      state.current_phase == :core_questions ->
        decide_core_questions_action(state)

      # In probing
      state.current_phase == :probing ->
        decide_probing_action(state)

      # In synthesis
      state.current_phase == :synthesis ->
        cond do
          state.synthesis_delivered and state.user_responded_to_synthesis ->
            maybe_transition_with_consensus(state, :closing, "Synthesis complete, user confirmed")
          state.synthesis_delivered and state.last_user_message != nil ->
            maybe_transition_with_consensus(state, :closing, "Synthesis delivered, moving to closing")
          true ->
            %{type: :synthesize, themes: state.active_themes || []}
        end

      # In closing
      state.current_phase == :closing ->
        %{type: :close, themes: state.active_themes || []}

      true ->
        %{type: :wait}
    end
  end

  defp maybe_transition_with_consensus(state, target_phase, default_reason) do
    votes = Director.gather_transition_votes(state.session_id, target_phase)
    {consensus_result, _votes} = Director.evaluate_consensus(votes, target_phase, state)

    case consensus_result do
      :consensus ->
        Logger.info("[Director] CONSENSUS reached for transition to #{target_phase}")
        %{type: :transition, to_phase: target_phase, reason: default_reason, consensus: :reached, votes: votes}

      :no_consensus ->
        Logger.warning("[Director] NO CONSENSUS for #{target_phase} - Director overriding. Votes: #{inspect(votes)}")
        Director.emit_disagreement_signal(target_phase, votes)
        %{type: :transition, to_phase: target_phase, reason: "#{default_reason} (Director override - no consensus)", consensus: :director_override, votes: votes}
    end
  end

  defp handle_topic_change_request(state) do
    if (state.topics_to_explore || []) != [] do
      next_topic = select_topic_respecting_momentum(state)
      Logger.info("[Director] Topic change requested - pivoting to: #{next_topic}")
      %{type: :ask_dynamic, topic: next_topic, themes: state.active_themes || [], probes: [], engagement: state.engagement_level, source: :topic_change_request, reason: "User requested topic change"}
    else
      Logger.info("[Director] Topic change requested but topics exhausted - moving to synthesis")
      %{type: :transition, to_phase: :synthesis, reason: "User requested topic change, but all topics explored"}
    end
  end

  defp decide_core_questions_action(state) do
    cond do
      (state.topics_to_explore || []) != [] ->
        next_topic = select_topic_respecting_momentum(state)
        Logger.debug("[Director] Topic rotation: moving to #{next_topic}, remaining: #{inspect(state.topics_to_explore)}")
        %{type: :ask_dynamic, topic: next_topic, themes: state.active_themes || [], probes: state.pending_probes || [], engagement: state.engagement_level, source: :collective_intelligence}

      (state.pending_probes || []) != [] ->
        high_probe = Enum.find(state.pending_probes, fn p -> p.priority == :high end)
        probe = high_probe || hd(state.pending_probes)
        Logger.debug("[Director] All topics covered, now probing: #{probe.topic}")
        %{type: :probe, question: probe.question, topic: probe.topic, source: :probe_coach}

      true ->
        maybe_transition_with_consensus(state, :synthesis, "Core topics explored")
    end
  end

  defp decide_probing_action(state) do
    if (state.pending_probes || []) != [] do
      [probe | _rest] = state.pending_probes
      %{type: :probe, question: probe.question, topic: probe.topic}
    else
      maybe_transition_with_consensus(state, :synthesis, "Probing complete")
    end
  end

  # ---- Topic selection ----

  defp select_topic_respecting_momentum(state) do
    remaining = state.topics_to_explore || []

    case state.chronological_direction do
      :forward ->
        forward_topics = (state.config || %{})[:forward_topics] || [:vision, :passion, :differentiation]
        selected = Enum.find(forward_topics, fn t -> t in remaining end) || hd(remaining)
        Logger.info("[Director] MOMENTUM: User moved FORWARD -> selecting forward topic: #{selected}")
        selected

      :backward ->
        selected = hd(remaining)
        Logger.debug("[Director] MOMENTUM: User in backward mode -> using default: #{selected}")
        selected

      _ ->
        select_next_topic(state)
    end
  end

  defp select_next_topic(state) do
    remaining = state.topics_to_explore || []
    theme_suggested = find_theme_related_topic(state.active_themes || [], remaining, state)
    probe_suggested = find_probe_related_topic(state.pending_probes || [], remaining, state)

    cond do
      theme_suggested != nil -> theme_suggested
      probe_suggested != nil -> probe_suggested
      true -> hd(remaining)
    end
  end

  defp find_theme_related_topic(themes, remaining_topics, state) do
    topic_keywords = (state.config || %{})[:topic_keywords] || default_topic_keywords()

    Enum.find(remaining_topics, fn topic ->
      keywords = Map.get(topic_keywords, topic, [])
      Enum.any?(themes, fn theme ->
        theme_text = (theme[:theme] || theme.theme || "") |> String.downcase()
        Enum.any?(keywords, fn kw -> String.contains?(theme_text, kw) end)
      end)
    end)
  end

  defp find_probe_related_topic(probes, remaining_topics, state) do
    topic_keywords = (state.config || %{})[:probe_topic_keywords] || default_probe_topic_keywords()

    Enum.find(remaining_topics, fn topic ->
      keywords = Map.get(topic_keywords, topic, [])
      Enum.any?(probes, fn probe ->
        probe_text = (probe[:topic] || probe.topic || "") |> String.downcase()
        Enum.any?(keywords, fn kw -> String.contains?(probe_text, kw) end)
      end)
    end)
  end

  defp default_topic_keywords do
    %{
      origin: ["background", "start", "began", "journey", "path", "career", "how you got here", "first job", "started out"],
      passion: ["love", "passion", "drive", "motivate", "care about", "excited", "energy", "fulfilling"],
      differentiation: ["unique", "different", "approach", "perspective", "style", "stand out", "special"],
      moments: ["moment", "turning point", "pivotal", "changed", "realized", "breakthrough", "milestone"],
      vision: ["future", "goal", "vision", "next", "working toward", "dream", "aspiration", "building"]
    }
  end

  defp default_probe_topic_keywords do
    %{
      origin: ["background", "start", "how", "where"],
      passion: ["why", "love", "passion", "drive"],
      differentiation: ["unique", "different", "approach"],
      moments: ["when", "moment", "turning", "pivotal"],
      vision: ["future", "goal", "next", "plan"]
    }
  end

  defp get_opening_question do
    case Phases.questions(:opening) do
      [first | _] -> first.text
      [] -> "Hi! I'm excited to learn more about you and your story. Ready to dive in?"
    end
  end

  # ---- Action-to-state mapping ----

  defp compute_action_changes(%{type: :ask_dynamic, topic: topic}, state) do
    explored = [topic | state.topics_explored || []]
    remaining = Enum.reject(state.topics_to_explore || [], fn t -> t == topic end)
    Logger.debug("[Director] Topic explored: #{topic}, remaining: #{inspect(remaining)}")
    %{topics_explored: explored, topics_to_explore: remaining}
  end

  defp compute_action_changes(%{type: :probe, topic: topic}, state) do
    remaining_probes = Enum.reject(state.pending_probes || [], fn p -> p.topic == topic end)
    %{pending_probes: remaining_probes}
  end

  defp compute_action_changes(%{type: :synthesize}, _state) do
    %{synthesis_delivered: true}
  end

  # Transitions triggered by user_intent must clear the intent to prevent re-triggering loops
  defp compute_action_changes(%{type: :transition} = action, _state) do
    if action[:reason] && String.contains?(to_string(action[:reason]), "User requested") do
      %{user_intent: :continue}
    else
      %{}
    end
  end

  defp compute_action_changes(_action, _state), do: %{}
end

# =============================================================================
# GenerateResponse — LLM response generation
# =============================================================================

defmodule InterviewStudio.Agents.Director.Actions.GenerateResponse do
  @moduledoc """
  Builds prompts and calls the LLM to generate natural interview responses.
  """

  use Jido.Action,
    name: "director_generate_response",
    description: "Generate LLM response for interview action",
    schema: [
      action_type: [type: :any, default: nil],
      context: [type: :any, default: %{}]
    ]

  require Logger

  alias InterviewStudio.PromptLoader

  @impl true
  def run(params, context) do
    state = context.state
    action_type = params[:action_type]
    action_context = params[:context] || %{}

    response = do_generate_response(action_type, action_context, state)
    {:ok, %{last_response_result: response}}
  end

  defp do_generate_response(action_type, context, state) do
    system_prompt = build_system_prompt(state)
    user_prompt = build_user_prompt(action_type, context, state)

    case call_llm(system_prompt, user_prompt, state.llm_config || %{}) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---- System prompt ----

  defp build_system_prompt(state) do
    themes_text = case state.active_themes || [] do
      [] -> "No themes identified yet."
      themes ->
        themes
        |> Enum.map(fn t -> "- #{t[:theme] || t.theme || "unknown"}" end)
        |> Enum.join("\n")
    end

    topics_explored = (state.topics_explored || []) |> Enum.map(&to_string/1) |> Enum.join(", ")
    topics_remaining = (state.topics_to_explore || []) |> Enum.map(&to_string/1) |> Enum.join(", ")
    questions_asked = format_questions_asked(state.questions_asked)
    interview_memory = get_interview_memory(state.session_id)

    variables = %{
      current_phase: state.current_phase,
      topics_explored: if(topics_explored == "", do: "none yet", else: topics_explored),
      topics_remaining: if(topics_remaining == "", do: "none", else: topics_remaining),
      questions_asked: questions_asked,
      themes_text: themes_text,
      interview_memory: interview_memory
    }

    PromptLoader.load_with_vars!("interview", "director", "system", variables, default_system_prompt(variables))
  end

  defp default_system_prompt(vars) do
    """
    You are a warm, skilled interviewer conducting a "Story of You" interview.
    Your goal is to discover what makes this person unique.

    Current phase: #{vars.current_phase}
    Topics explored: #{vars.topics_explored}
    Topics remaining: #{vars.topics_remaining}

    Questions you've already asked (DO NOT repeat these):
    #{vars.questions_asked}

    Themes discovered:
    #{vars.themes_text}

    #{vars.interview_memory}

    Always respond in first person as the interviewer.
    """
  end

  # ---- User prompts ----

  defp build_user_prompt(:ask, context, state) do
    history = format_recent_history(state.conversation_history || [], 3)
    question = context[:question] || context.question || ""

    variables = %{history: history, question: question}

    PromptLoader.load_with_vars!("interview", "director", "ask", variables,
      "Recent conversation:\n#{history}\n\nAsk this question naturally: \"#{question}\"\n\nRespond with just the question.")
  end

  defp build_user_prompt(:ask_dynamic, context, state) do
    history = format_recent_history(state.conversation_history || [], 5)
    topic = context[:topic] || context.topic
    themes = context[:themes] || context.themes || []
    probes = context[:probes] || context.probes || []
    engagement = context[:engagement] || context.engagement || :medium
    frustration = state.frustration_level || :none
    chronological_direction = state.chronological_direction || :neutral
    config = state.config || %{}

    themes_text = format_themes_for_prompt(themes)
    probes_text = format_probes_for_prompt(probes)
    engagement_guidance = engagement_to_guidance(engagement, config)
    frustration_guidance = frustration_to_guidance(frustration, config)
    chronological_guidance = chronological_to_guidance(chronological_direction, config)
    topic_description = topic_to_description(topic, config)

    topic_change_note = if context[:source] == :topic_change_request do
      "\n\nIMPORTANT: User just asked to change topics. Make sure this question is about something COMPLETELY DIFFERENT from what you were just discussing."
    else
      ""
    end

    variables = %{
      history: history,
      themes_text: themes_text,
      probes_text: probes_text,
      engagement: engagement,
      engagement_guidance: engagement_guidance,
      frustration: frustration,
      frustration_guidance: frustration_guidance,
      chronological_direction: chronological_direction,
      chronological_guidance: chronological_guidance,
      topic_change_note: topic_change_note,
      topic_description: topic_description
    }

    PromptLoader.load_with_vars!("interview", "director", "dynamic_question", variables,
      default_dynamic_question_prompt(variables))
  end

  defp build_user_prompt(:probe, context, state) do
    history = format_recent_history(state.conversation_history || [], 3)
    question = context[:question] || context.question || ""
    topic = context[:topic] || context.topic || ""

    variables = %{history: history, topic: topic, question: question}

    PromptLoader.load_with_vars!("interview", "director", "probe", variables,
      "Recent conversation:\n#{history}\n\nThe user said something interesting about: #{topic}\nAsk this follow-up: \"#{question}\"")
  end

  defp build_user_prompt(:synthesize, context, state) do
    history = format_recent_history(state.conversation_history || [], 5)
    themes = context[:themes] || context.themes || []
    theme_list = themes |> Enum.map(fn t -> t[:theme] || t.theme end) |> Enum.join(", ")

    variables = %{history: history, theme_list: theme_list}

    PromptLoader.load_with_vars!("interview", "director", "synthesize", variables,
      "Recent conversation:\n#{history}\n\nKey themes: #{theme_list}\n\nSummarize what you've learned in 2-3 sentences.")
  end

  defp build_user_prompt(:close, _context, state) do
    history = format_recent_history(state.conversation_history || [], 3)
    variables = %{history: history}

    PromptLoader.load_with_vars!("interview", "director", "close", variables,
      "Recent conversation:\n#{history}\n\nThank them warmly for sharing their story. Keep it brief and genuine.")
  end

  defp build_user_prompt(_action_type, _context, _state) do
    "Respond naturally to continue the conversation."
  end

  # ---- Prompt helpers ----

  defp default_dynamic_question_prompt(vars) do
    """
    Recent conversation:
    #{vars.history}

    Generate a question about: #{vars.topic_description}

    Themes: #{vars.themes_text}
    Engagement: #{vars.engagement}

    Respond with just the question, naturally phrased.
    """
  end

  defp format_themes_for_prompt([]), do: "No themes identified yet - this is early in the conversation."
  defp format_themes_for_prompt(themes) do
    themes
    |> Enum.take(5)
    |> Enum.map(fn t ->
      theme = t[:theme] || t.theme || "unknown"
      evidence = t[:evidence] || t.evidence || ""
      confidence = t[:confidence] || t.confidence || 0.5

      base = "- **#{theme}**"
      evidence_text = if evidence != "" do
        " — they said: \"#{String.slice(evidence, 0, 200)}\""
      else
        ""
      end
      confidence_text = if confidence >= 0.8, do: " [strong]", else: ""

      base <> confidence_text <> evidence_text
    end)
    |> Enum.join("\n")
  end

  defp format_probes_for_prompt([]), do: "No specific probes suggested yet."
  defp format_probes_for_prompt(probes) do
    probes
    |> Enum.take(3)
    |> Enum.map(fn p ->
      topic = p[:topic] || p.topic || "unknown"
      question = p[:question] || p.question || p[:suggested_question] || ""
      rationale = p[:rationale] || p.rationale || ""
      priority = p[:priority] || p.priority || :medium

      priority_label = case priority do
        :high -> "HIGH"
        :medium -> "MEDIUM"
        :low -> "low"
        _ -> "medium"
      end

      base = "- [#{priority_label}] **#{topic}**"
      question_text = if question != "", do: "\n  Suggested: \"#{String.slice(question, 0, 150)}\"", else: ""
      rationale_text = if rationale != "", do: "\n  Why: #{String.slice(rationale, 0, 100)}", else: ""

      base <> question_text <> rationale_text
    end)
    |> Enum.join("\n")
  end

  defp engagement_to_guidance(level, config) do
    guidance_config = config[:engagement_guidance] || %{}
    Map.get(guidance_config, level) || Map.get(guidance_config, :default) || default_engagement_guidance(level)
  end

  defp default_engagement_guidance(:high), do: "User is highly engaged - lean in! Ask deeper, more probing questions."
  defp default_engagement_guidance(:medium), do: "User engagement is moderate - balance depth with accessibility."
  defp default_engagement_guidance(:low), do: "User engagement is lower - keep it lighter."
  defp default_engagement_guidance(:critical), do: "User seems ready to wrap up - respect their energy."
  defp default_engagement_guidance(_), do: "Adjust your approach based on the conversation flow."

  defp frustration_to_guidance(level, config) do
    guidance_config = config[:frustration_guidance] || %{}
    Map.get(guidance_config, level) || Map.get(guidance_config, :default) || default_frustration_guidance(level)
  end

  defp default_frustration_guidance(:high), do: "CRITICAL: User is frustrated. Ask about something COMPLETELY DIFFERENT."
  defp default_frustration_guidance(:moderate), do: "User seems a bit irritated. Pivot to a fresh topic."
  defp default_frustration_guidance(:mild), do: "User may be getting impatient. Keep your question short."
  defp default_frustration_guidance(_), do: "Sentiment is neutral - proceed normally."

  defp chronological_to_guidance(direction, config) do
    guidance_config = config[:chronological_guidance] || %{}
    Map.get(guidance_config, direction) || Map.get(guidance_config, :neutral) || default_chronological_guidance(direction)
  end

  defp default_chronological_guidance(:forward), do: "User is talking about future/current work - RESPECT THIS MOMENTUM."
  defp default_chronological_guidance(:backward), do: "User is discussing their past. Look for opportunities to bridge to the present/future."
  defp default_chronological_guidance(_), do: "No strong chronological preference - follow the natural flow of conversation."

  defp topic_to_description(topic, config) do
    descriptions = config[:topic_descriptions] || %{}
    Map.get(descriptions, topic) || default_topic_description(topic)
  end

  defp default_topic_description(:origin), do: "their PROFESSIONAL JOURNEY - how they got into this field, what led them to their current career path (NOT childhood or personal history - focus on career beginnings)"
  defp default_topic_description(:passion), do: "their PASSION - what drives them, what they care deeply about"
  defp default_topic_description(:differentiation), do: "what makes them UNIQUE - their distinctive approach or perspective"
  defp default_topic_description(:moments), do: "PIVOTAL MOMENTS - turning points that shaped who they became"
  defp default_topic_description(:vision), do: "their VISION - where they're headed, what they're working toward"
  defp default_topic_description(topic), do: "#{topic}"

  defp format_recent_history(history, count) do
    history
    |> Enum.take(count)
    |> Enum.reverse()
    |> Enum.map(fn msg ->
      role = if msg.role == :user, do: "User", else: "Interviewer"
      "#{role}: #{msg.content}"
    end)
    |> Enum.join("\n")
  end

  defp format_questions_asked(nil), do: "None yet."
  defp format_questions_asked([]), do: "None yet."
  defp format_questions_asked(questions) do
    questions
    |> Enum.take(10)
    |> Enum.with_index(1)
    |> Enum.map(fn {q, i} -> "#{i}. #{String.slice(q, 0, 100)}..." end)
    |> Enum.join("\n")
  end

  defp get_interview_memory(session_id) do
    alias InterviewStudio.Agents.Scribe
    try do
      case Scribe.get_interview_context(session_id) do
        %{formatted_text: text} -> text
        _ -> ""
      end
    rescue
      _ -> ""
    catch
      :exit, _ -> ""
    end
  end

  # ---- LLM call ----

  defp call_llm(system_prompt, user_prompt, config) do
    try do
      model_name = config[:model] || "meta-llama/llama-4-scout-17b-16e-instruct"

      case Jido.Exec.run(Jido.AI.Actions.LLM.Chat, %{
        model: "groq:#{model_name}",
        prompt: user_prompt,
        system_prompt: system_prompt,
        temperature: config[:temperature] || 0.7,
        max_tokens: config[:max_tokens] || 1000
      }) do
        {:ok, %{text: content}} -> {:ok, content}
        {:ok, result} when is_map(result) -> {:ok, Map.get(result, :text, inspect(result))}
        {:error, reason} -> {:error, reason}
      end
    rescue
      e ->
        Logger.error("[Director] LLM call failed: #{inspect(e)}")
        {:error, "LLM call failed"}
    end
  end
end
