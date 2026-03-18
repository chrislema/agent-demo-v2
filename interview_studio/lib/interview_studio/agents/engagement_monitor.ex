defmodule InterviewStudio.Agents.EngagementMonitor do
  @moduledoc """
  The Engagement Monitor Agent - reads the room using heuristics.

  Monitors:
  - Response length and enthusiasm
  - Signs of discomfort or resistance
  - Energy levels throughout interview
  - When to ease off vs. lean in

  No LLM required - pure heuristic-based analysis.

  Implemented as a Jido.Agent with signal_routes and Actions.
  Runs inside a Jido.AgentServer that receives signals from InterviewBus.
  """

  use Jido.Agent,
    name: "engagement_monitor",
    description: "Monitors interviewee engagement via heuristics",
    schema: [
      session_id: [type: :any, default: nil],
      level: [type: :atom, default: :high],
      trend: [type: :atom, default: :stable],
      history: [type: :any, default: []],
      indicators: [type: :any, default: %{}],
      last_emission: [type: :any, default: nil],
      config: [type: :any, default: %{}]
    ],
    signal_routes: [
      {"interview.utterance.user",
       InterviewStudio.Agents.EngagementMonitor.Actions.AnalyzeEngagement}
    ]

  require Logger

  alias InterviewStudio.InterviewBus
  alias InterviewStudio.ConfigLoader

  # Default config (used if YAML file not found)
  @default_config %{
    wrap_up_markers: [
      "wrap up", "let's wrap", "wrapping up", "finish", "let's finish",
      "move on", "let's move on", "already explained", "already said",
      "end the interview", "that's enough", "i'm done", "let's end",
      "can we finish", "ready to finish", "time to wrap"
    ],
    enthusiasm_markers: ["!", "love", "excited", "amazing", "great", "absolutely", "definitely", "really"],
    resistance_markers: ["i don't know", "not sure", "maybe", "i guess", "whatever", "fine", "ok", "sure"],
    elaboration_markers: ["for example", "like when", "i remember", "one time", "because", "the reason", "actually"],
    sentiment: %{
      positive_words: ~w(love great amazing wonderful happy excited good best),
      negative_words: ~w(hate bad terrible awful frustrated annoyed difficult hard)
    },
    scoring: %{
      terse_response: -2,
      verbose_response: 1,
      medium_response: 1,
      short_response: -1,
      enthusiasm_detected: 1,
      resistance_detected: -2,
      elaboration: 1,
      positive_sentiment: 1,
      negative_sentiment: -1
    },
    thresholds: %{
      terse_max: 5,
      short_max: 10,
      medium_min: 20,
      verbose_min: 100,
      resistance_min_count: 2,
      resistance_short_length: 30
    },
    level_thresholds: %{
      high: 2,
      medium: 0,
      low: -2
    },
    recommendations: %{
      critical: "Consider wrapping up or changing topic",
      low_declining: "Try a different approach or easier question",
      low: "Keep questions light and build rapport",
      medium_declining: "Engagement dropping, consider a more engaging topic",
      high: "Good engagement, continue current approach",
      default: "Monitor and adjust as needed"
    },
    alerts: %{
      critical: "CRITICAL: User wants to wrap up. All agents should facilitate closing.",
      low_declining: "LOW & DECLINING: User energy dropping. Reduce complexity, pause deep analysis.",
      low: "LOW: User energy is low. Keep interactions light.",
      default: "Monitor engagement."
    }
  }

  # Client API

  def start_link(opts \\ []) do
    session_id = Keyword.fetch!(opts, :session_id)
    config = ConfigLoader.load_with_defaults(:engagement, @default_config)

    {:ok, pid} = Jido.AgentServer.start_link(
      agent: __MODULE__,
      name: via_tuple(session_id),
      id: "engagement_monitor_#{session_id}",
      register_global: false,
      initial_state: %{
        session_id: session_id,
        config: config
      }
    )

    # Subscribe the AgentServer to InterviewBus signal patterns
    InterviewBus.subscribe_pid("interview.utterance.user", pid)

    Logger.info("[EngagementMonitor] Started for session #{session_id}")
    {:ok, pid}
  end

  def get_state(session_id) do
    {:ok, server_state} = Jido.AgentServer.state(via_tuple(session_id))
    server_state.agent.state
  end

  def get_level(session_id) do
    {:ok, server_state} = Jido.AgentServer.state(via_tuple(session_id))
    server_state.agent.state.level
  end

  @doc """
  Vote on readiness for a phase transition.
  Pure function — reads current state and computes vote.
  """
  def vote_transition(session_id, target_phase) do
    {:ok, server_state} = Jido.AgentServer.state(via_tuple(session_id))
    evaluate_transition_readiness(target_phase, server_state.agent.state)
  end

  defp via_tuple(session_id) do
    {:via, Registry, {InterviewStudio.SessionRegistry, {:engagement_monitor, session_id}}}
  end

  # CONSENSUS MECHANISM: Evaluate readiness for phase transition
  defp evaluate_transition_readiness(target_phase, state) do
    case target_phase do
      :closing ->
        case state.level do
          :critical ->
            {:ready, "CRITICAL engagement - strongly recommend closing immediately"}
          :low ->
            case state.trend do
              :declining ->
                {:ready, "Low and declining engagement - recommend closing"}
              _ ->
                {:ready, "Low engagement - support closing if others agree"}
            end
          :medium ->
            {:abstain, "Moderate engagement - deferring to other factors"}
          :high ->
            {:not_ready, "High engagement - user is still invested, no need to rush"}
        end

      :synthesis ->
        case state.level do
          :critical ->
            {:ready, "Critical engagement - move to synthesis quickly"}
          :low ->
            {:ready, "Low engagement - synthesis could help re-engage"}
          _ ->
            {:abstain, "Engagement is fine - neutral on synthesis timing"}
        end

      :probing ->
        case state.level do
          :critical ->
            {:not_ready, "Engagement too low for probing - skip to closing"}
          :low ->
            {:not_ready, "Low engagement - probing may frustrate user"}
          _ ->
            {:ready, "Engagement supports deeper probing"}
        end

      :core_questions ->
        if state.level in [:high, :medium] do
          {:ready, "Engagement level supports core questions"}
        else
          {:abstain, "Engagement is low but deferring to flow"}
        end

      _ ->
        {:abstain, "No specific engagement criteria for #{target_phase}"}
    end
  end
end

# =============================================================================
# Action: AnalyzeEngagement
# =============================================================================

defmodule InterviewStudio.Agents.EngagementMonitor.Actions.AnalyzeEngagement do
  @moduledoc """
  Analyzes a user utterance for engagement indicators.
  Updates engagement level, trend, and history.
  Emits status signals via InterviewBus when engagement changes.
  """

  use Jido.Action,
    name: "engagement_analyze",
    description: "Analyze user response for engagement indicators",
    schema: [
      content: [type: :string, required: true],
      timestamp: [type: :any]
    ]

  require Logger

  alias InterviewStudio.InterviewBus

  @impl true
  def run(params, context) do
    state = context.state
    config = state.config
    content = params.content || params[:content] || ""

    # Analyze the response
    indicators = analyze_response(content, config)

    # Calculate new level
    {new_level, new_trend} = calculate_engagement(indicators, state)

    # Record in history
    history_entry = %{
      timestamp: DateTime.utc_now(),
      level: new_level,
      indicators: indicators
    }

    new_history = [history_entry | (state.history || [])] |> Enum.take(20)
    previous_level = state.level

    # Build updated state
    new_state = %{
      level: new_level,
      trend: new_trend,
      indicators: indicators,
      history: new_history
    }

    # Determine if we should emit status signals
    last_emission = state.last_emission
    new_state = maybe_emit_and_update(new_state, previous_level, last_emission, config)

    {:ok, new_state}
  end

  # Signal emission (side effect — publishes to InterviewBus)
  defp maybe_emit_and_update(state, previous_level, last_emission, config) do
    should_emit = state.level != previous_level or
                  (state.level == :critical and time_since(last_emission) > 30) or
                  (state.level == :low and time_since(last_emission) > 60)

    if should_emit do
      emit_status(state, config)

      if state.level in [:critical, :low] do
        broadcast_engagement_alert(state, config)
      end

      Map.put(state, :last_emission, DateTime.utc_now())
    else
      state
    end
  end

  defp time_since(nil), do: 9999
  defp time_since(last) do
    DateTime.diff(DateTime.utc_now(), last)
  end

  defp emit_status(state, config) do
    recommendations = config[:recommendations] || %{}

    recommendation = case {state.level, state.trend} do
      {:critical, _} -> recommendations[:critical] || "Consider wrapping up or changing topic"
      {:low, :declining} -> recommendations[:low_declining] || "Try a different approach or easier question"
      {:low, _} -> recommendations[:low] || "Keep questions light and build rapport"
      {:medium, :declining} -> recommendations[:medium_declining] || "Engagement dropping, consider a more engaging topic"
      {:high, _} -> recommendations[:high] || "Good engagement, continue current approach"
      _ -> recommendations[:default] || "Monitor and adjust as needed"
    end

    signal = %Jido.Signal{
      type: "observer.status.engagement",
      source: "engagement_monitor",
      id: Jido.Util.generate_id(),
      data: %{
        level: state.level,
        trend: state.trend,
        indicators: state.indicators,
        recommendation: recommendation,
        timestamp: DateTime.utc_now()
      }
    }

    InterviewBus.publish(signal)
    Logger.debug("[EngagementMonitor] Emitted status: #{state.level} (#{state.trend})")
  end

  defp broadcast_engagement_alert(state, config) do
    alerts = config[:alerts] || %{}

    alert = %Jido.Signal{
      type: "engagement.alert.broadcast",
      source: "engagement_monitor",
      id: Jido.Util.generate_id(),
      data: %{
        level: state.level,
        trend: state.trend,
        action_required: state.level == :critical,
        message: engagement_alert_message(state.level, state.trend, alerts),
        timestamp: DateTime.utc_now()
      }
    }

    InterviewBus.publish(alert)
    Logger.info("[EngagementMonitor] BROADCAST: Engagement alert - #{state.level}")
  end

  defp engagement_alert_message(:critical, _, alerts) do
    alerts[:critical] || "CRITICAL: User wants to wrap up. All agents should facilitate closing."
  end
  defp engagement_alert_message(:low, :declining, alerts) do
    alerts[:low_declining] || "LOW & DECLINING: User energy dropping. Reduce complexity, pause deep analysis."
  end
  defp engagement_alert_message(:low, _, alerts) do
    alerts[:low] || "LOW: User energy is low. Keep interactions light."
  end
  defp engagement_alert_message(_, _, alerts) do
    alerts[:default] || "Monitor engagement."
  end

  # Analysis functions

  defp analyze_response(content, config) do
    word_count = content |> String.split() |> length()
    char_count = String.length(content)
    thresholds = config[:thresholds] || %{}

    terse_max = thresholds[:terse_max] || 5
    verbose_min = thresholds[:verbose_min] || 100

    %{
      word_count: word_count,
      char_count: char_count,
      has_enthusiasm: has_enthusiasm?(content, config),
      has_resistance: has_resistance?(content, config),
      has_elaboration: has_elaboration?(content, config),
      wants_wrap_up: wants_to_wrap_up?(content, config),
      is_terse: word_count < terse_max,
      is_verbose: word_count > verbose_min,
      sentiment: estimate_sentiment(content, config)
    }
  end

  defp has_enthusiasm?(text, config) do
    markers = config[:enthusiasm_markers] || ["!", "love", "excited", "amazing", "great", "absolutely", "definitely", "really"]
    downcased = String.downcase(text)
    Enum.any?(markers, fn marker -> String.contains?(downcased, marker) end)
  end

  defp has_resistance?(text, config) do
    markers = config[:resistance_markers] || ["i don't know", "not sure", "maybe", "i guess", "whatever", "fine", "ok", "sure"]
    thresholds = config[:thresholds] || %{}
    min_count = thresholds[:resistance_min_count] || 2
    short_length = thresholds[:resistance_short_length] || 30

    downcased = String.downcase(text)
    count = Enum.count(markers, fn marker -> String.contains?(downcased, marker) end)
    count >= min_count or (count >= 1 and String.length(text) < short_length)
  end

  defp wants_to_wrap_up?(text, config) do
    markers = config[:wrap_up_markers] || [
      "wrap up", "let's wrap", "wrapping up", "finish", "let's finish",
      "move on", "let's move on", "already explained", "already said",
      "end the interview", "that's enough", "i'm done", "let's end",
      "can we finish", "ready to finish", "time to wrap"
    ]
    downcased = String.downcase(text)
    Enum.any?(markers, fn marker -> String.contains?(downcased, marker) end)
  end

  defp has_elaboration?(text, config) do
    markers = config[:elaboration_markers] || ["for example", "like when", "i remember", "one time", "because", "the reason", "actually"]
    downcased = String.downcase(text)
    Enum.any?(markers, fn marker -> String.contains?(downcased, marker) end)
  end

  defp estimate_sentiment(text, config) do
    sentiment_config = config[:sentiment] || %{}
    positive_words = sentiment_config[:positive_words] || ~w(love great amazing wonderful happy excited good best)
    negative_words = sentiment_config[:negative_words] || ~w(hate bad terrible awful frustrated annoyed difficult hard)

    downcased = String.downcase(text)

    positive_count = Enum.count(positive_words, fn w -> String.contains?(downcased, w) end)
    negative_count = Enum.count(negative_words, fn w -> String.contains?(downcased, w) end)

    cond do
      positive_count > negative_count + 1 -> :positive
      negative_count > positive_count + 1 -> :negative
      true -> :neutral
    end
  end

  # Engagement calculation

  defp calculate_engagement(indicators, state) do
    if indicators.wants_wrap_up do
      new_trend = calculate_trend(:critical, state.history || [])
      {:critical, new_trend}
    else
      config = state.config || %{}
      scoring = config[:scoring] || %{}
      thresholds = config[:thresholds] || %{}
      level_thresholds = config[:level_thresholds] || %{}

      medium_min = thresholds[:medium_min] || 20
      short_max = thresholds[:short_max] || 10

      length_score = cond do
        indicators.is_terse -> scoring[:terse_response] || -2
        indicators.is_verbose -> scoring[:verbose_response] || 1
        indicators.word_count > medium_min -> scoring[:medium_response] || 1
        indicators.word_count > short_max -> 0
        true -> scoring[:short_response] || -1
      end

      enthusiasm_score = if indicators.has_enthusiasm, do: scoring[:enthusiasm_detected] || 1, else: 0
      resistance_score = if indicators.has_resistance, do: scoring[:resistance_detected] || -2, else: 0
      elaboration_score = if indicators.has_elaboration, do: scoring[:elaboration] || 1, else: 0

      sentiment_score = case indicators.sentiment do
        :positive -> scoring[:positive_sentiment] || 1
        :negative -> scoring[:negative_sentiment] || -1
        :neutral -> 0
      end

      total_score = length_score + enthusiasm_score + resistance_score + elaboration_score + sentiment_score

      high_threshold = level_thresholds[:high] || 2
      medium_threshold = level_thresholds[:medium] || 0
      low_threshold = level_thresholds[:low] || -2

      new_level = cond do
        total_score >= high_threshold -> :high
        total_score >= medium_threshold -> :medium
        total_score >= low_threshold -> :low
        true -> :critical
      end

      new_trend = calculate_trend(new_level, state.history || [])

      {new_level, new_trend}
    end
  end

  defp calculate_trend(_current_level, history) when length(history) < 3, do: :stable

  defp calculate_trend(current_level, history) do
    recent = history |> Enum.take(3) |> Enum.map(fn h -> level_to_number(h.level) end)
    current_num = level_to_number(current_level)

    avg_recent = Enum.sum(recent) / length(recent)

    cond do
      current_num > avg_recent + 0.5 -> :improving
      current_num < avg_recent - 0.5 -> :declining
      true -> :stable
    end
  end

  defp level_to_number(:high), do: 3
  defp level_to_number(:medium), do: 2
  defp level_to_number(:low), do: 1
  defp level_to_number(:critical), do: 0
end
