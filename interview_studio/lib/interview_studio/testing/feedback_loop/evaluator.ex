defmodule InterviewStudio.Testing.FeedbackLoop.Evaluator do
  @moduledoc """
  Comprehensive conversation evaluation for automated testing.

  Evaluates conversations across multiple dimensions:
  - Phase transition quality
  - Response quality (repetition, contextual questions)
  - Agent collaboration (theme usage, probe adoption)
  - Engagement handling (frustration, end-intent detection)
  """

  alias InterviewStudio.Testing.FeedbackLoop.SignalAnalyzer
  alias InterviewStudio.Testing.FeedbackLoop.ConfigManager
  alias InterviewStudio.Agents.Scribe
  alias InterviewStudio.InterviewBus

  @doc """
  Performs comprehensive evaluation of a conversation session.
  """
  @spec evaluate(String.t()) :: map()
  def evaluate(session_id) do
    # Get transcript from Scribe
    transcript = get_transcript_safe(session_id)

    # Get signals from InterviewBus
    signals = InterviewBus.history(limit: 500)

    # Load metrics configuration
    {:ok, metrics_config} = ConfigManager.load_metrics()

    # Analyze signals
    signal_analysis = SignalAnalyzer.analyze(signals)

    # Calculate metrics
    metrics = calculate_metrics(transcript, signals, signal_analysis, metrics_config)

    # Detect issues
    issues = detect_issues(transcript, signals, signal_analysis, metrics_config)

    # Calculate overall score
    score = calculate_overall_score(metrics, issues, metrics_config)

    %{
      session_id: session_id,
      metrics: metrics,
      issues: issues,
      score: score,
      signal_analysis: signal_analysis,
      transcript_length: length(transcript),
      evaluated_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @doc """
  Evaluates a conversation with custom transcript and signals (for testing).
  """
  @spec evaluate_with_data([map()], [map()]) :: map()
  def evaluate_with_data(transcript, signals) do
    {:ok, metrics_config} = ConfigManager.load_metrics()
    signal_analysis = SignalAnalyzer.analyze(signals)

    metrics = calculate_metrics(transcript, signals, signal_analysis, metrics_config)
    issues = detect_issues(transcript, signals, signal_analysis, metrics_config)
    score = calculate_overall_score(metrics, issues, metrics_config)

    %{
      metrics: metrics,
      issues: issues,
      score: score,
      signal_analysis: signal_analysis,
      transcript_length: length(transcript)
    }
  end

  @doc """
  Calculates all metrics for a conversation.
  """
  @spec calculate_metrics([map()], [map()], map(), map()) :: map()
  def calculate_metrics(transcript, signals, signal_analysis, _config) do
    %{
      phase_transitions: evaluate_phase_transitions(signal_analysis),
      response_quality: evaluate_response_quality(transcript, signals),
      agent_collaboration: evaluate_agent_collaboration(signals, signal_analysis),
      engagement_handling: evaluate_engagement_handling(transcript, signals, signal_analysis)
    }
  end

  @doc """
  Detects issues in a conversation.
  """
  @spec detect_issues([map()], [map()], map(), map()) :: [map()]
  def detect_issues(transcript, signals, signal_analysis, _config) do
    issues = []

    # Check for repeated/generic questions
    issues = issues ++ detect_repeated_questions(transcript)
    issues = issues ++ detect_generic_questions(transcript)

    # Check for missed emotional cues
    issues = issues ++ detect_missed_emotional_cues(transcript, signals, signal_analysis)

    # Check for poor phase transitions
    issues = issues ++ detect_poor_phase_transitions(signal_analysis)

    # Check for weak collaboration
    issues = issues ++ detect_weak_collaboration(transcript, signals, signal_analysis)

    # Check for slow responses and errors
    issues = issues ++ detect_performance_issues(signals, signal_analysis)

    issues
  end

  @doc """
  Calculates overall score from metrics and issues.
  """
  @spec calculate_overall_score(map(), [map()], map()) :: map()
  def calculate_overall_score(metrics, issues, config) do
    scoring_config = config["scoring"] || %{}

    # Base score starts at 100
    base_score = 100

    # Subtract for issues based on severity
    issue_penalty =
      Enum.reduce(issues, 0, fn issue, acc ->
        penalty =
          case issue.severity do
            :high -> 10
            :medium -> 5
            :low -> 2
            _ -> 3
          end

        acc + penalty
      end)

    # Add bonuses for positive metrics
    bonuses = calculate_bonuses(metrics)

    raw_score = base_score - issue_penalty + bonuses
    final_score = max(0, min(100, raw_score))

    rating =
      cond do
        final_score >= (scoring_config["excellent"] || %{})["min_score"] || 85 -> :excellent
        final_score >= (scoring_config["good"] || %{})["min_score"] || 70 -> :good
        final_score >= (scoring_config["needs_improvement"] || %{})["min_score"] || 50 -> :needs_improvement
        true -> :poor
      end

    %{
      raw_score: raw_score,
      final_score: final_score,
      rating: rating,
      issue_penalty: issue_penalty,
      bonuses: bonuses
    }
  end

  # Evaluation sub-functions

  defp evaluate_phase_transitions(signal_analysis) do
    transitions = signal_analysis.phase_transitions

    valid_sequence = validate_phase_sequence(transitions.sequence)
    appropriate_timing = evaluate_timing(transitions.transitions)

    %{
      valid_sequence: valid_sequence,
      sequence: transitions.sequence,
      transitions_count: transitions.phases_entered,
      timing: appropriate_timing
    }
  end

  defp evaluate_response_quality(transcript, _signals) do
    host_messages = Enum.filter(transcript, &host_message?/1)

    repetition_score = calculate_repetition_score(host_messages)
    contextual_score = calculate_contextual_score(transcript)

    %{
      host_message_count: length(host_messages),
      repetition_score: repetition_score,
      contextual_score: contextual_score,
      avg_response_length: calculate_avg_length(host_messages)
    }
  end

  defp evaluate_agent_collaboration(signals, signal_analysis) do
    themes = SignalAnalyzer.extract_themes(signals)
    probes = SignalAnalyzer.extract_probes(signals)

    %{
      themes_discovered: length(themes),
      probes_suggested: length(probes),
      agent_activity: signal_analysis.agent_activity,
      signal_flow_health: evaluate_signal_flow(signal_analysis.signal_flow)
    }
  end

  defp evaluate_engagement_handling(_transcript, _signals, signal_analysis) do
    engagement = signal_analysis.engagement_signals

    %{
      engagement_updates: engagement.engagement_updates,
      frustration_detected: engagement.frustration_detected,
      end_intent_detected: engagement.end_intent_detected,
      alerts_raised: engagement.alerts
    }
  end

  # Issue detection functions

  defp detect_repeated_questions(transcript) do
    host_questions =
      transcript
      |> Enum.filter(&host_message?/1)
      |> Enum.map(&normalize_question/1)

    duplicates = find_similar_pairs(host_questions, 0.7)

    Enum.map(duplicates, fn {q1, q2, similarity} ->
      %{
        category: :repeated_questions,
        severity: :high,
        description: "Similar questions detected (#{Float.round(similarity * 100, 1)}% similar)",
        details: %{question_1: q1, question_2: q2, similarity: similarity}
      }
    end)
  end

  defp detect_generic_questions(transcript) do
    generic_patterns = [
      ~r/tell me more/i,
      ~r/can you elaborate/i,
      ~r/interesting.*what else/i,
      ~r/^(so|and|okay)\s*,?\s*(what|how|tell)/i
    ]

    transcript
    |> Enum.with_index()
    |> Enum.filter(fn {msg, _idx} -> host_message?(msg) end)
    |> Enum.flat_map(fn {msg, idx} ->
      content = get_content(msg)

      # Check if it's generic AND doesn't reference previous content
      is_generic = Enum.any?(generic_patterns, &Regex.match?(&1, content))

      # Get previous user message to check for context
      prev_user_content = get_previous_user_content(transcript, idx)

      references_context =
        prev_user_content &&
          contains_reference?(content, prev_user_content)

      if is_generic and not references_context do
        [
          %{
            category: :generic_questions,
            severity: :medium,
            description: "Generic follow-up without specific context",
            details: %{question: content, position: idx}
          }
        ]
      else
        []
      end
    end)
  end

  defp detect_missed_emotional_cues(transcript, _signals, signal_analysis) do
    issues = []

    # Check if frustration was in transcript but not detected
    user_messages = Enum.filter(transcript, &user_message?/1)

    frustration_indicators = [
      ~r/i don't (know|understand|want)/i,
      ~r/this is (frustrating|annoying|confusing)/i,
      ~r/can we (stop|end|wrap up|finish)/i,
      ~r/i('m| am) (tired|done|over it)/i,
      ~r/why (do|are) you (asking|keep)/i
    ]

    has_frustration_cues =
      Enum.any?(user_messages, fn msg ->
        content = get_content(msg)
        Enum.any?(frustration_indicators, &Regex.match?(&1, content))
      end)

    issues =
      if has_frustration_cues and not signal_analysis.engagement_signals.frustration_detected do
        [
          %{
            category: :missed_emotional_cues,
            severity: :high,
            description: "User showed frustration cues but engagement system didn't detect it",
            details: %{cue_type: :frustration}
          }
          | issues
        ]
      else
        issues
      end

    # Check for end intent
    end_intent_patterns = [
      ~r/i (need|have) to go/i,
      ~r/can we (wrap|finish|end)/i,
      ~r/i think (we're done|that's all)/i,
      ~r/i don't have (more|much) time/i
    ]

    has_end_intent =
      Enum.any?(user_messages, fn msg ->
        content = get_content(msg)
        Enum.any?(end_intent_patterns, &Regex.match?(&1, content))
      end)

    issues =
      if has_end_intent and not signal_analysis.engagement_signals.end_intent_detected do
        [
          %{
            category: :missed_emotional_cues,
            severity: :high,
            description: "User expressed desire to end but system didn't detect end-intent",
            details: %{cue_type: :end_intent}
          }
          | issues
        ]
      else
        issues
      end

    issues
  end

  defp detect_poor_phase_transitions(signal_analysis) do
    transitions = signal_analysis.phase_transitions
    issues = []

    # Check for invalid sequence
    valid_transitions = %{
      "preparation" => ["opening"],
      "opening" => ["core_questions"],
      "core_questions" => ["probing", "synthesis", "closing"],
      "probing" => ["core_questions", "synthesis", "closing"],
      "synthesis" => ["closing"],
      "closing" => []
    }

    sequence = transitions.sequence

    invalid_transitions =
      sequence
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.filter(fn [from, to] ->
        allowed = Map.get(valid_transitions, from, [])
        to not in allowed
      end)

    issues =
      Enum.reduce(invalid_transitions, issues, fn [from, to], acc ->
        [
          %{
            category: :poor_phase_transitions,
            severity: :medium,
            description: "Invalid phase transition: #{from} -> #{to}",
            details: %{from: from, to: to}
          }
          | acc
        ]
      end)

    # Check for skipped synthesis
    has_synthesis = "synthesis" in sequence
    has_closing = "closing" in sequence

    issues =
      if has_closing and not has_synthesis do
        [
          %{
            category: :poor_phase_transitions,
            severity: :medium,
            description: "Closing phase reached without synthesis",
            details: %{sequence: sequence}
          }
          | issues
        ]
      else
        issues
      end

    issues
  end

  defp detect_weak_collaboration(transcript, signals, signal_analysis) do
    issues = []

    # Check if themes were discovered but not used in questions
    themes = SignalAnalyzer.extract_themes(signals)
    host_questions = Enum.filter(transcript, &host_message?/1) |> Enum.map(&get_content/1)

    all_theme_words =
      themes
      |> Enum.flat_map(fn t -> t.themes end)
      |> Enum.flat_map(fn theme ->
        cond do
          is_map(theme) -> [theme["name"] || theme[:name] || ""]
          is_binary(theme) -> [theme]
          true -> []
        end
      end)
      |> Enum.map(&String.downcase/1)

    theme_usage =
      all_theme_words
      |> Enum.count(fn theme ->
        Enum.any?(host_questions, fn q ->
          String.downcase(q) |> String.contains?(theme)
        end)
      end)

    issues =
      if length(all_theme_words) > 0 and theme_usage == 0 do
        [
          %{
            category: :weak_collaboration,
            severity: :medium,
            description: "Themes were discovered but none appeared in follow-up questions",
            details: %{themes_discovered: length(all_theme_words), themes_used: 0}
          }
          | issues
        ]
      else
        issues
      end

    # Check for low agent activity
    agent_activity = signal_analysis.agent_activity

    inactive_agents =
      Enum.filter(agent_activity, fn {_agent, data} ->
        data.total_signals == 0
      end)
      |> Enum.map(fn {agent, _} -> agent end)

    issues =
      if length(inactive_agents) > 2 do
        [
          %{
            category: :weak_collaboration,
            severity: :low,
            description: "Multiple agents showed no activity",
            details: %{inactive_agents: inactive_agents}
          }
          | issues
        ]
      else
        issues
      end

    issues
  end

  defp detect_performance_issues(_signals, signal_analysis) do
    issues = []

    # Check for errors
    errors = signal_analysis.errors

    issues =
      Enum.reduce(errors, issues, fn error, acc ->
        [
          %{
            category: :performance_issues,
            severity: :high,
            description: "Agent error detected",
            details: %{error: error}
          }
          | acc
        ]
      end)

    # Check for slow response times (if timing data available)
    timing = signal_analysis.timing

    issues =
      if timing.avg_signal_interval_ms > 5000 do
        [
          %{
            category: :performance_issues,
            severity: :medium,
            description: "Slow average response time (#{timing.avg_signal_interval_ms}ms)",
            details: %{avg_interval: timing.avg_signal_interval_ms}
          }
          | issues
        ]
      else
        issues
      end

    issues
  end

  # Helper functions

  defp get_transcript_safe(session_id) do
    case Scribe.get_transcript(session_id) do
      {:ok, transcript} -> transcript
      _ -> []
    end
  rescue
    _ -> []
  end

  defp host_message?(%{role: role}), do: role in [:host, "host"]
  defp host_message?(%{"role" => role}), do: role in [:host, "host"]
  defp host_message?(_), do: false

  defp user_message?(%{role: role}), do: role in [:user, "user", :interviewee, "interviewee"]
  defp user_message?(%{"role" => role}), do: role in [:user, "user", :interviewee, "interviewee"]
  defp user_message?(_), do: false

  defp get_content(%{content: content}), do: content || ""
  defp get_content(%{"content" => content}), do: content || ""
  defp get_content(_), do: ""

  defp normalize_question(msg) do
    get_content(msg)
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, "")
    |> String.trim()
  end

  defp find_similar_pairs(questions, threshold) do
    questions
    |> Enum.with_index()
    |> Enum.flat_map(fn {q1, i} ->
      questions
      |> Enum.with_index()
      |> Enum.filter(fn {_q2, j} -> j > i end)
      |> Enum.map(fn {q2, _j} -> {q1, q2, jaccard_similarity(q1, q2)} end)
      |> Enum.filter(fn {_q1, _q2, sim} -> sim >= threshold end)
    end)
  end

  defp jaccard_similarity(s1, s2) do
    words1 = String.split(s1) |> MapSet.new()
    words2 = String.split(s2) |> MapSet.new()

    intersection = MapSet.intersection(words1, words2) |> MapSet.size()
    union = MapSet.union(words1, words2) |> MapSet.size()

    if union == 0, do: 0.0, else: intersection / union
  end

  defp get_previous_user_content(transcript, current_idx) do
    transcript
    |> Enum.take(current_idx)
    |> Enum.reverse()
    |> Enum.find(&user_message?/1)
    |> case do
      nil -> nil
      msg -> get_content(msg)
    end
  end

  defp contains_reference?(question, previous_content) do
    # Extract significant words from previous content
    significant_words =
      previous_content
      |> String.downcase()
      |> String.split()
      |> Enum.filter(&(String.length(&1) > 4))
      |> Enum.take(10)

    question_lower = String.downcase(question)

    # Check if any significant words appear in the question
    Enum.any?(significant_words, &String.contains?(question_lower, &1))
  end

  defp validate_phase_sequence(sequence) do
    # Check that it starts correctly
    starts_correctly =
      case sequence do
        [first | _] when first in ["preparation", "opening"] -> true
        _ -> false
      end

    # Check no backwards jumps to preparation/opening
    no_backwards_jumps =
      sequence
      |> Enum.with_index()
      |> Enum.all?(fn {phase, idx} ->
        case phase do
          "preparation" -> idx == 0
          "opening" -> idx <= 1
          _ -> true
        end
      end)

    starts_correctly and no_backwards_jumps
  end

  defp evaluate_timing(transitions) do
    # Simple timing evaluation - could be expanded
    %{
      transition_count: length(transitions),
      has_transitions: length(transitions) > 0
    }
  end

  defp calculate_repetition_score(host_messages) do
    if length(host_messages) <= 1 do
      100.0
    else
      questions = Enum.map(host_messages, &normalize_question/1)
      duplicates = find_similar_pairs(questions, 0.7)
      penalty = length(duplicates) * 10
      max(0, 100.0 - penalty)
    end
  end

  defp calculate_contextual_score(transcript) do
    # Measure how well host questions reference previous user content
    host_indices =
      transcript
      |> Enum.with_index()
      |> Enum.filter(fn {msg, _} -> host_message?(msg) end)
      |> Enum.map(fn {_, idx} -> idx end)

    if length(host_indices) == 0 do
      0.0
    else
      contextual_count =
        Enum.count(host_indices, fn idx ->
          question = Enum.at(transcript, idx) |> get_content()
          prev_content = get_previous_user_content(transcript, idx)
          prev_content && contains_reference?(question, prev_content)
        end)

      contextual_count / length(host_indices) * 100
    end
  end

  defp calculate_avg_length(messages) do
    if Enum.empty?(messages) do
      0.0
    else
      total = Enum.sum(Enum.map(messages, fn m -> String.length(get_content(m)) end))
      total / length(messages)
    end
  end

  defp evaluate_signal_flow(signal_flow) do
    cond do
      signal_flow.signals_per_exchange >= 3 -> :healthy
      signal_flow.signals_per_exchange >= 1 -> :adequate
      true -> :low
    end
  end

  defp calculate_bonuses(metrics) do
    bonuses = 0

    # Bonus for good contextual score
    bonuses =
      if metrics.response_quality.contextual_score > 60,
        do: bonuses + 5,
        else: bonuses

    # Bonus for theme discovery
    bonuses =
      if metrics.agent_collaboration.themes_discovered > 2,
        do: bonuses + 3,
        else: bonuses

    # Bonus for valid phase sequence
    bonuses =
      if metrics.phase_transitions.valid_sequence,
        do: bonuses + 2,
        else: bonuses

    bonuses
  end
end
