defmodule InterviewStudio.Agents.EngagementMonitor do
  @moduledoc """
  The Engagement Monitor Agent - reads the room using heuristics.

  Monitors:
  - Response length and enthusiasm
  - Signs of discomfort or resistance
  - Energy levels throughout interview
  - When to ease off vs. lean in

  No LLM required - pure heuristic-based analysis.
  """

  use GenServer
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

  defstruct [
    :session_id,
    :level,
    :trend,
    :history,
    :indicators,
    :last_emission,
    :config
  ]

  # Client API

  def start_link(opts \\ []) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(session_id))
  end

  def get_state(session_id) do
    GenServer.call(via_tuple(session_id), :get_state)
  end

  def get_level(session_id) do
    GenServer.call(via_tuple(session_id), :get_level)
  end

  @doc """
  Vote on readiness for a phase transition.
  Used by Director.poll_transition_readiness/2 for consensus-based phase transitions.
  Engagement Monitor has HIGH WEIGHT for closing decisions.
  Returns {:ready | :not_ready | :abstain, rationale}
  """
  def vote_transition(session_id, target_phase) do
    GenServer.call(via_tuple(session_id), {:vote_transition, target_phase}, 5_000)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    # Load config from YAML, falling back to defaults
    config = ConfigLoader.load_with_defaults(:engagement, @default_config)

    state = %__MODULE__{
      session_id: session_id,
      level: :high,
      trend: :stable,
      history: [],
      indicators: %{},
      last_emission: nil,
      config: config
    }

    subscribe_to_signals()

    Logger.info("[EngagementMonitor] Started for session #{session_id}")
    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call(:get_level, _from, state) do
    {:reply, state.level, state}
  end

  @impl true
  def handle_call({:vote_transition, target_phase}, _from, state) do
    # CONSENSUS MECHANISM: Vote on phase transition readiness
    # Engagement Monitor has HIGH WEIGHT for closing/wrap-up decisions
    vote = evaluate_transition_readiness(target_phase, state)
    Logger.debug("[EngagementMonitor] Voting on transition to #{target_phase}: #{elem(vote, 0)}")
    {:reply, vote, state}
  end

  @impl true
  def handle_info({:signal, signal}, state) do
    new_state = handle_signal(signal, state)
    {:noreply, new_state}
  end

  # Signal handlers

  defp handle_signal(%{type: "interview.utterance.user"} = signal, state) do
    content = signal.data.content

    # Analyze the response using config
    indicators = analyze_response(content, state.config)

    # Calculate new level using config
    {new_level, new_trend} = calculate_engagement(indicators, state)

    # Record in history
    history_entry = %{
      timestamp: DateTime.utc_now(),
      level: new_level,
      indicators: indicators
    }

    new_state = %{state |
      level: new_level,
      trend: new_trend,
      indicators: indicators,
      history: [history_entry | state.history] |> Enum.take(20)
    }

    # Emit signal if level changed significantly
    maybe_emit_status(new_state, state.level)
  end

  defp handle_signal(_signal, state), do: state

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
    enthusiasm_markers = config[:enthusiasm_markers] || ["!", "love", "excited", "amazing", "great", "absolutely", "definitely", "really"]
    downcased = String.downcase(text)
    Enum.any?(enthusiasm_markers, fn marker -> String.contains?(downcased, marker) end)
  end

  defp has_resistance?(text, config) do
    resistance_markers = config[:resistance_markers] || ["i don't know", "not sure", "maybe", "i guess", "whatever", "fine", "ok", "sure"]
    thresholds = config[:thresholds] || %{}
    min_count = thresholds[:resistance_min_count] || 2
    short_length = thresholds[:resistance_short_length] || 30

    downcased = String.downcase(text)
    # Count how many resistance markers appear
    count = Enum.count(resistance_markers, fn marker -> String.contains?(downcased, marker) end)
    # Only flag if multiple markers or response is short
    count >= min_count or (count >= 1 and String.length(text) < short_length)
  end

  defp wants_to_wrap_up?(text, config) do
    wrap_up_markers = config[:wrap_up_markers] || [
      "wrap up", "let's wrap", "wrapping up", "finish", "let's finish",
      "move on", "let's move on", "already explained", "already said",
      "end the interview", "that's enough", "i'm done", "let's end",
      "can we finish", "ready to finish", "time to wrap"
    ]
    downcased = String.downcase(text)
    Enum.any?(wrap_up_markers, fn marker -> String.contains?(downcased, marker) end)
  end

  defp has_elaboration?(text, config) do
    # Signs of elaboration: examples, stories, details
    elaboration_markers = config[:elaboration_markers] || ["for example", "like when", "i remember", "one time", "because", "the reason", "actually"]
    downcased = String.downcase(text)
    Enum.any?(elaboration_markers, fn marker -> String.contains?(downcased, marker) end)
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
    # If user explicitly wants to wrap up, immediately go to critical
    if indicators.wants_wrap_up do
      new_trend = calculate_trend(:critical, state.history)
      {:critical, new_trend}
    else
      scoring = state.config[:scoring] || %{}
      thresholds = state.config[:thresholds] || %{}
      level_thresholds = state.config[:level_thresholds] || %{}

      medium_min = thresholds[:medium_min] || 20
      short_max = thresholds[:short_max] || 10

      # Score components from config
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

      # Map to level using config thresholds
      high_threshold = level_thresholds[:high] || 2
      medium_threshold = level_thresholds[:medium] || 0
      low_threshold = level_thresholds[:low] || -2

      new_level = cond do
        total_score >= high_threshold -> :high
        total_score >= medium_threshold -> :medium
        total_score >= low_threshold -> :low
        true -> :critical
      end

      # Calculate trend based on history
      new_trend = calculate_trend(new_level, state.history)

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

  # Signal emission

  defp maybe_emit_status(state, previous_level) do
    should_emit = state.level != previous_level or
                  (state.level == :critical and time_since_last_emission(state) > 30) or
                  (state.level == :low and time_since_last_emission(state) > 60)

    if should_emit do
      emit_status(state)
      %{state | last_emission: DateTime.utc_now()}
    else
      state
    end
  end

  defp time_since_last_emission(%{last_emission: nil}), do: 9999
  defp time_since_last_emission(%{last_emission: last}) do
    DateTime.diff(DateTime.utc_now(), last)
  end

  defp emit_status(state) do
    recommendations = state.config[:recommendations] || %{}

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

    # AGENT-TO-AGENT: Broadcast critical/low engagement to all agents
    # This allows agents to adjust their behavior based on user energy
    if state.level in [:critical, :low] do
      broadcast_engagement_alert(state)
    end
  end

  # Broadcast engagement alerts to influence all agents
  defp broadcast_engagement_alert(state) do
    alerts = state.config[:alerts] || %{}

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

  defp subscribe_to_signals do
    InterviewBus.subscribe("interview.utterance.user")
  end

  defp via_tuple(session_id) do
    {:via, Registry, {InterviewStudio.SessionRegistry, {:engagement_monitor, session_id}}}
  end

  # CONSENSUS MECHANISM: Evaluate readiness for phase transition
  # Engagement Monitor has HIGH WEIGHT for closing/wrap-up decisions
  # Returns {:ready | :not_ready | :abstain, rationale}
  defp evaluate_transition_readiness(target_phase, state) do
    case target_phase do
      :closing ->
        # HIGH WEIGHT: Engagement Monitor is the authority on whether to close
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
        # For synthesis, engagement level matters
        case state.level do
          :critical ->
            {:ready, "Critical engagement - move to synthesis quickly"}
          :low ->
            {:ready, "Low engagement - synthesis could help re-engage"}
          _ ->
            {:abstain, "Engagement is fine - neutral on synthesis timing"}
        end

      :probing ->
        # Probing requires decent engagement
        case state.level do
          :critical ->
            {:not_ready, "Engagement too low for probing - skip to closing"}
          :low ->
            {:not_ready, "Low engagement - probing may frustrate user"}
          _ ->
            {:ready, "Engagement supports deeper probing"}
        end

      :core_questions ->
        # Starting core questions - engagement should be reasonable
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
