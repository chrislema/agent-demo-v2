defmodule InterviewStudio.Agents.StoryAnalyst do
  @moduledoc """
  The Story Analyst Agent - extracts narrative themes and patterns.

  Phase 4: Domain-Agnostic Architecture
  - Loads heuristics from domain config (heuristics/story_analyst.yaml)
  - Analysis thresholds come from config
  - Transition readiness thresholds come from config

  Looks for:
  - Recurring themes (resilience, creativity, community, etc.)
  - Story arcs (struggle → breakthrough, passion → profession)
  - Unique angles that differentiate this person
  - Quotable moments and key phrases

  LLM-powered for deep analysis.

  Implemented as a Jido.Agent with signal_routes and Actions.
  """

  use Jido.Agent,
    name: "story_analyst",
    description: "Extracts narrative themes and patterns from interviews",
    schema: [
      session_id: [type: :any, default: nil],
      themes: [type: :any, default: []],
      patterns: [type: :any, default: []],
      conversation_buffer: [type: :any, default: []],
      analysis_count: [type: :integer, default: 0],
      engagement_level: [type: :atom, default: :high],
      llm_config: [type: :any, default: %{}],
      probe_suggestions: [type: :any, default: []],
      domain: [type: :any, default: nil],
      heuristics: [type: :any, default: %{}]
    ],
    signal_routes: [
      {"interview.utterance.*", InterviewStudio.Agents.StoryAnalyst.Actions.HandleUtterance},
      {"engagement.alert.broadcast", InterviewStudio.Agents.StoryAnalyst.Actions.HandleEngagement},
      {"observer.status.engagement", InterviewStudio.Agents.StoryAnalyst.Actions.HandleEngagement},
      {"observer.suggestion.probe", InterviewStudio.Agents.StoryAnalyst.Actions.HandleProbeSuggestion},
      {"story_analyst.internal.update", InterviewStudio.Agents.StoryAnalyst.Actions.UpdateInsights},
      {"story_analyst.cmd.analyze_now", InterviewStudio.Agents.StoryAnalyst.Actions.AnalyzeNow}
    ]

  require Logger

  alias InterviewStudio.InterviewBus
  alias InterviewStudio.DomainLoader

  # Client API

  def start_link(opts \\ []) do
    session_id = Keyword.fetch!(opts, :session_id)
    llm_config = Keyword.get(opts, :llm_config, default_llm_config())

    # PHASE 4: Get domain from opts (passed by AgentSupervisor)
    domain = Keyword.get(opts, :domain)

    # PHASE 4: Load heuristics from domain config
    heuristics = if domain do
      DomainLoader.get_heuristics(domain, :story_analyst)
    else
      %{}
    end

    {:ok, pid} = Jido.AgentServer.start_link(
      agent: __MODULE__,
      name: via_tuple(session_id),
      id: "story_analyst_#{session_id}",
      register_global: false,
      initial_state: %{
        session_id: session_id,
        llm_config: llm_config,
        domain: domain,
        heuristics: heuristics
      }
    )

    # Subscribe to InterviewBus signals
    InterviewBus.subscribe_pid("interview.utterance.**", pid)
    InterviewBus.subscribe_pid("engagement.alert.broadcast", pid)
    InterviewBus.subscribe_pid("observer.status.engagement", pid)
    InterviewBus.subscribe_pid("observer.suggestion.probe", pid)

    Logger.info("[StoryAnalyst] Started for session #{session_id} (domain: #{domain && domain.name || "default"})")
    {:ok, pid}
  end

  def get_state(session_id) do
    get_agent_state(session_id)
  end

  def get_themes(session_id) do
    state = get_agent_state(session_id)
    state.themes
  end

  @doc """
  Request immediate synchronous analysis.
  Used by Session.gather_insights/2 for parallel analysis with synchronization barrier.
  Returns {:ok, themes} or {:error, reason}
  """
  def analyze_now(session_id) do
    signal = %Jido.Signal{
      type: "story_analyst.cmd.analyze_now",
      source: "session",
      id: Jido.Util.generate_id(),
      data: %{},
      time: DateTime.utc_now()
    }

    case GenServer.call(via_tuple(session_id), {:signal, signal}, 10_000) do
      {:ok, agent} -> {:ok, agent.state.themes}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Vote on readiness for a phase transition.
  Used by Director.poll_transition_readiness/2 for consensus-based phase transitions.
  Returns {:ready | :not_ready | :abstain, rationale}
  """
  def vote_transition(session_id, target_phase) do
    state = get_agent_state(session_id)
    evaluate_transition_readiness(target_phase, state)
  end

  # Private helpers

  defp get_agent_state(session_id) do
    {:ok, server_state} = Jido.AgentServer.state(via_tuple(session_id))
    server_state.agent.state
  end

  defp via_tuple(session_id) do
    {:via, Registry, {InterviewStudio.SessionRegistry, {:story_analyst, session_id}}}
  end

  defp default_llm_config do
    %{
      provider: :openrouter,
      model: "meta-llama/llama-4-scout-17b-16e-instruct",
      temperature: 0.3
    }
  end

  # CONSENSUS MECHANISM: Evaluate readiness for phase transition
  defp evaluate_transition_readiness(target_phase, state) do
    theme_count = length(state.themes)
    pattern_count = length(state.patterns)
    has_conversation = length(state.conversation_buffer) > 0

    case target_phase do
      :synthesis ->
        cond do
          theme_count >= 3 ->
            {:ready, "Identified #{theme_count} themes - sufficient for synthesis"}
          theme_count >= 1 and pattern_count >= 1 ->
            {:ready, "Found #{theme_count} themes and #{pattern_count} patterns - ready for synthesis"}
          has_conversation and theme_count == 0 ->
            {:not_ready, "No themes discovered yet - need more analysis before synthesis"}
          true ->
            {:abstain, "Insufficient data to make a recommendation"}
        end

      :closing ->
        if theme_count >= 2 or (theme_count >= 1 and state.engagement_level == :critical) do
          {:ready, "Theme analysis complete (#{theme_count} themes) - ready to close"}
        else
          {:abstain, "Deferring to other agents on closing decision"}
        end

      :core_questions ->
        if has_conversation do
          {:ready, "Ready to analyze core question responses"}
        else
          {:ready, "Ready to begin analysis"}
        end

      :probing ->
        if theme_count >= 1 do
          {:ready, "Themes discovered that could benefit from probing"}
        else
          {:abstain, "No strong opinion on probing transition"}
        end

      _ ->
        {:abstain, "No specific readiness criteria for #{target_phase}"}
    end
  end
end

# =============================================================================
# Action: HandleUtterance
# =============================================================================

defmodule InterviewStudio.Agents.StoryAnalyst.Actions.HandleUtterance do
  @moduledoc "Buffers utterances and triggers async LLM analysis when appropriate."

  use Jido.Action,
    name: "story_analyst_handle_utterance",
    description: "Buffer utterance and maybe trigger analysis",
    schema: [
      content: [type: :any],
      timestamp: [type: :any]
    ]

  require Logger

  alias InterviewStudio.InterviewBus
  alias InterviewStudio.PromptLoader

  @default_analysis_threshold 2

  @impl true
  def run(params, context) do
    state = context.state
    content = params[:content] || ""
    signal_type = context[:signal_type] || ""

    role = if String.ends_with?(to_string(signal_type), "user"), do: :user, else: :host

    # PHASE 4: Get thresholds from heuristics config
    thresholds = (state.heuristics || %{})[:thresholds] || %{}
    max_buffer = thresholds[:max_conversation_buffer] || 10
    analysis_frequency = thresholds[:analysis_frequency] || @default_analysis_threshold
    first_msg_min_length = thresholds[:first_message_min_length] || 50
    skip_levels = thresholds[:skip_analysis_engagement_levels] || [:critical]

    entry = %{role: role, content: content, timestamp: DateTime.utc_now()}
    buffer = [entry | (state.conversation_buffer || [])] |> Enum.take(max_buffer)

    new_count = if role == :user, do: (state.analysis_count || 0) + 1, else: (state.analysis_count || 0)

    # Check if we should trigger async analysis
    should_analyze = role == :user and
      state.engagement_level not in skip_levels and
      (rem(new_count, analysis_frequency) == 0 or
       (new_count == 1 and String.length(content) > first_msg_min_length))

    Logger.info("[StoryAnalyst] Utterance received (role=#{role}, count=#{new_count}, should_analyze=#{should_analyze}, engagement=#{state.engagement_level})")

    if should_analyze do
      # Capture AgentServer pid (self() IS the AgentServer for async signals)
      agent_server_pid = self()
      session_id = state.session_id
      updated_state = Map.merge(state, %{conversation_buffer: buffer, analysis_count: new_count})

      analyze_async(updated_state, agent_server_pid, session_id)
    end

    {:ok, %{
      conversation_buffer: buffer,
      analysis_count: new_count
    }}
  end

  defp analyze_async(state, agent_server_pid, _session_id) do
    emit_analyzing_signal()

    Task.start(fn ->
      case analyze_themes(state) do
        {:ok, new_themes, new_patterns} ->
          Logger.info("[StoryAnalyst] Analysis complete: #{length(new_themes)} themes, #{length(new_patterns)} patterns found")
          emit_insights(new_themes, new_patterns, state)

          # Send state update back to AgentServer via signal
          update_signal = %Jido.Signal{
            type: "story_analyst.internal.update",
            source: "story_analyst",
            id: Jido.Util.generate_id(),
            data: %{themes: new_themes, patterns: new_patterns},
            time: DateTime.utc_now()
          }
          GenServer.cast(agent_server_pid, {:signal, update_signal})

        {:error, reason} ->
          Logger.warning("[StoryAnalyst] Analysis failed: #{inspect(reason)}")
          emit_error_signal(reason)
      end
    end)
  end

  defp emit_analyzing_signal do
    signal = %Jido.Signal{
      type: "observer.status.analyzing",
      source: "story_analyst",
      id: Jido.Util.generate_id(),
      data: %{
        status: :analyzing,
        message: "Analyzing conversation for themes and patterns",
        timestamp: DateTime.utc_now()
      }
    }
    InterviewBus.publish(signal)
    Logger.debug("[StoryAnalyst] Starting theme analysis")
  end

  defp emit_error_signal(reason) do
    signal = %Jido.Signal{
      type: "observer.status.error",
      source: "story_analyst",
      id: Jido.Util.generate_id(),
      data: %{
        status: :error,
        reason: inspect(reason),
        timestamp: DateTime.utc_now()
      }
    }
    InterviewBus.publish(signal)
  end

  def analyze_themes(state) do
    conversation = (state.conversation_buffer || [])
    |> Enum.reverse()
    |> Enum.map(fn e -> "#{e.role}: #{e.content}" end)
    |> Enum.join("\n")

    existing_themes = (state.themes || [])
    |> Enum.map(fn t -> t.theme end)
    |> Enum.join(", ")

    probe_topics = (state.probe_suggestions || [])
    |> Enum.map(fn s -> s.topic end)
    |> Enum.join(", ")

    probe_context = if probe_topics != "" do
      "\n\nAreas suggested for deeper exploration by Probe Coach: #{probe_topics}\n(Prioritize identifying themes related to these areas if present in the conversation)"
    else
      ""
    end

    variables = %{
      conversation: conversation,
      existing_themes: if(existing_themes == "", do: "none yet", else: existing_themes),
      probe_context: probe_context
    }

    prompt = PromptLoader.load_with_vars!("interview", "story_analyst", "analysis", variables,
      default_analysis_prompt(variables))

    case call_llm(prompt, state.llm_config || %{}) do
      {:ok, response} -> parse_analysis(response)
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_analysis_prompt(vars) do
    """
    Analyze this interview conversation for narrative themes and patterns.

    Conversation:
    #{vars.conversation}

    Already identified themes: #{vars.existing_themes}#{vars.probe_context}

    Identify:
    1. NEW themes (don't repeat existing ones) - core values, motivations, defining characteristics
    2. Story patterns - arcs like struggle→growth, passion→profession

    Respond in JSON format:
    {"themes": [{"theme": "name", "evidence": "quote", "confidence": 0.8}], "patterns": [{"pattern": "description", "instances": ["example"]}]}

    Only include genuinely new insights.
    """
  end

  defp parse_analysis(response) do
    case extract_json(response) do
      {:ok, parsed} ->
        themes = Map.get(parsed, "themes", [])
        |> Enum.map(fn t ->
          %{
            theme: t["theme"],
            evidence: t["evidence"],
            confidence: t["confidence"] || 0.7
          }
        end)

        patterns = Map.get(parsed, "patterns", [])
        |> Enum.map(fn p ->
          %{
            pattern: p["pattern"],
            instances: p["instances"] || []
          }
        end)

        {:ok, themes, patterns}

      {:error, reason} ->
        Logger.warning("[StoryAnalyst] Failed to parse LLM response: #{inspect(reason)}, raw: #{String.slice(response, 0, 200)}")
        {:ok, [], []}
    end
  end

  defp extract_json(text) do
    case Regex.run(~r/\{[\s\S]*\}/, text) do
      [json_str] ->
        case Jason.decode(json_str) do
          {:ok, parsed} -> {:ok, parsed}
          {:error, _} -> {:error, :invalid_json}
        end
      nil ->
        {:error, :no_json_found}
    end
  end

  defp emit_insights(themes, patterns, state) do
    Enum.each(themes, fn theme ->
      signal = %Jido.Signal{
        type: "observer.insight.theme",
        source: "story_analyst",
        id: Jido.Util.generate_id(),
        data: %{
          theme: theme.theme,
          evidence: theme.evidence,
          confidence: theme.confidence,
          timestamp: DateTime.utc_now()
        }
      }
      InterviewBus.publish(signal)
      Logger.debug("[StoryAnalyst] Identified theme: #{theme.theme}")

      notify_probe_coach(theme, state)
    end)

    Enum.each(patterns, fn pattern ->
      signal = %Jido.Signal{
        type: "observer.insight.pattern",
        source: "story_analyst",
        id: Jido.Util.generate_id(),
        data: %{
          pattern_type: pattern.pattern,
          instances: pattern.instances,
          timestamp: DateTime.utc_now()
        }
      }
      InterviewBus.publish(signal)
      Logger.debug("[StoryAnalyst] Identified pattern: #{pattern.pattern}")
    end)

    completion_signal = %Jido.Signal{
      type: "observer.status.complete",
      source: "story_analyst",
      id: Jido.Util.generate_id(),
      data: %{
        status: :complete,
        themes_found: length(themes),
        patterns_found: length(patterns),
        message: if(themes == [] and patterns == [], do: "No new insights found", else: "Analysis complete"),
        timestamp: DateTime.utc_now()
      }
    }
    InterviewBus.publish(completion_signal)
  end

  defp notify_probe_coach(theme, _state) do
    signal = %Jido.Signal{
      type: "analyst.theme.discovered",
      source: "story_analyst",
      id: Jido.Util.generate_id(),
      data: %{
        target: "probe_coach",
        theme: theme.theme,
        evidence: theme.evidence,
        confidence: theme.confidence,
        timestamp: DateTime.utc_now(),
        suggestion: "Consider probing how this theme connects to other areas of their story"
      }
    }
    InterviewBus.publish(signal)
    Logger.debug("[StoryAnalyst] -> [ProbeCoach] Theme notification: #{theme.theme}")
  end

  defp call_llm(prompt, config) do
    try do
      model_name = config[:model] || "meta-llama/llama-4-scout-17b-16e-instruct"

      case Jido.Exec.run(Jido.AI.Actions.LLM.Chat, %{
        model: "groq:#{model_name}",
        prompt: prompt,
        temperature: config[:temperature] || 0.3,
        max_tokens: config[:max_tokens] || 500
      }) do
        {:ok, %{text: content}} -> {:ok, content}
        {:ok, result} when is_map(result) -> {:ok, Map.get(result, :text, inspect(result))}
        {:error, reason} -> {:error, reason}
      end
    rescue
      e ->
        Logger.error("[StoryAnalyst] LLM call failed: #{inspect(e)}")
        {:error, "LLM call failed"}
    end
  end
end

# =============================================================================
# Action: HandleEngagement
# =============================================================================

defmodule InterviewStudio.Agents.StoryAnalyst.Actions.HandleEngagement do
  @moduledoc "Updates engagement level from Engagement Monitor signals."

  use Jido.Action,
    name: "story_analyst_handle_engagement",
    description: "Update engagement level from engagement signals",
    schema: [
      level: [type: :any]
    ]

  require Logger

  @impl true
  def run(params, context) do
    level = params[:level] || context.state.engagement_level
    Logger.debug("[StoryAnalyst] <- [EngagementMonitor] Engagement: #{level}")

    if level == :critical do
      Logger.info("[StoryAnalyst] Pausing deep analysis due to critical engagement")
    end

    {:ok, %{engagement_level: level}}
  end
end

# =============================================================================
# Action: HandleProbeSuggestion
# =============================================================================

defmodule InterviewStudio.Agents.StoryAnalyst.Actions.HandleProbeSuggestion do
  @moduledoc "Stores probe suggestions from Probe Coach for theme prioritization."

  use Jido.Action,
    name: "story_analyst_handle_probe_suggestion",
    description: "Store probe suggestion for theme prioritization",
    schema: [
      topic: [type: :any],
      rationale: [type: :any]
    ]

  require Logger

  @impl true
  def run(params, context) do
    state = context.state
    topic = params[:topic]

    if topic do
      Logger.debug("[StoryAnalyst] <- [ProbeCoach] Received probe suggestion: #{topic}")
      suggestion = %{
        topic: topic,
        rationale: params[:rationale],
        timestamp: DateTime.utc_now()
      }
      updated_suggestions = [suggestion | (state.probe_suggestions || [])] |> Enum.take(5)
      {:ok, %{probe_suggestions: updated_suggestions}}
    else
      {:ok, %{}}
    end
  end
end

# =============================================================================
# Action: UpdateInsights
# =============================================================================

defmodule InterviewStudio.Agents.StoryAnalyst.Actions.UpdateInsights do
  @moduledoc "Merges new themes/patterns from async analysis into agent state."

  use Jido.Action,
    name: "story_analyst_update_insights",
    description: "Merge async analysis results into state",
    schema: [
      themes: [type: :any],
      patterns: [type: :any]
    ]

  @impl true
  def run(params, context) do
    state = context.state
    new_themes = params[:themes] || []
    new_patterns = params[:patterns] || []

    updated_themes = (new_themes ++ (state.themes || []))
      |> Enum.uniq_by(fn t -> t.theme end)
      |> Enum.take(10)

    updated_patterns = (new_patterns ++ (state.patterns || []))
      |> Enum.uniq_by(fn p -> p.pattern end)
      |> Enum.take(5)

    {:ok, %{themes: updated_themes, patterns: updated_patterns}}
  end
end

# =============================================================================
# Action: AnalyzeNow
# =============================================================================

defmodule InterviewStudio.Agents.StoryAnalyst.Actions.AnalyzeNow do
  @moduledoc "Synchronous theme analysis for Session.gather_insights."

  use Jido.Action,
    name: "story_analyst_analyze_now",
    description: "Run synchronous theme analysis",
    schema: []

  require Logger

  alias InterviewStudio.Agents.StoryAnalyst.Actions.HandleUtterance

  @impl true
  def run(_params, context) do
    state = context.state
    Logger.debug("[StoryAnalyst] Synchronous analysis requested")

    if Enum.empty?(state.conversation_buffer || []) do
      # No conversation yet - return existing state unchanged
      {:ok, %{}}
    else
      case HandleUtterance.analyze_themes(state) do
        {:ok, new_themes, new_patterns} ->
          updated_themes = (new_themes ++ (state.themes || []))
            |> Enum.uniq_by(fn t -> t.theme end)
            |> Enum.take(10)
          updated_patterns = (new_patterns ++ (state.patterns || []))
            |> Enum.uniq_by(fn p -> p.pattern end)
            |> Enum.take(5)

          {:ok, %{themes: updated_themes, patterns: updated_patterns}}

        {:error, reason} ->
          Logger.warning("[StoryAnalyst] Sync analysis failed: #{inspect(reason)}")
          {:ok, %{}}
      end
    end
  end
end
