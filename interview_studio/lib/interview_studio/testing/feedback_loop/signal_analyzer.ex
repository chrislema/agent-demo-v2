defmodule InterviewStudio.Testing.FeedbackLoop.SignalAnalyzer do
  @moduledoc """
  Analyzes signals from InterviewBus to extract metrics and detect patterns.

  Provides detailed signal analysis for evaluating agent behavior and collaboration.
  """

  @doc """
  Performs comprehensive analysis of signals from a conversation.
  """
  @spec analyze([map()]) :: map()
  def analyze(signals) when is_list(signals) do
    %{
      signal_counts: count_by_type(signals),
      agent_activity: analyze_agent_activity(signals),
      theme_discoveries: count_type(signals, "observer.insight.theme"),
      probe_suggestions: count_type(signals, "observer.suggestion.probe"),
      consensus_events: analyze_consensus(signals),
      phase_transitions: analyze_phase_transitions(signals),
      engagement_signals: analyze_engagement(signals),
      errors: filter_errors(signals),
      timing: calculate_timing(signals),
      signal_flow: analyze_signal_flow(signals)
    }
  end

  @doc """
  Counts signals by their type prefix.
  """
  @spec count_by_type([map()]) :: map()
  def count_by_type(signals) do
    signals
    |> Enum.group_by(&extract_type_prefix/1)
    |> Enum.map(fn {prefix, sigs} -> {prefix, length(sigs)} end)
    |> Enum.into(%{})
  end

  @doc """
  Analyzes activity per agent.
  """
  @spec analyze_agent_activity([map()]) :: map()
  def analyze_agent_activity(signals) do
    agents = ["story_analyst", "probe_coach", "engagement_monitor", "sentiment_agent", "director", "scribe"]

    Enum.map(agents, fn agent ->
      agent_signals = Enum.filter(signals, &matches_source?(&1, agent))

      {agent,
       %{
         total_signals: length(agent_signals),
         signal_types: count_by_type(agent_signals),
         first_signal_at: first_timestamp(agent_signals),
         last_signal_at: last_timestamp(agent_signals)
       }}
    end)
    |> Enum.into(%{})
  end

  @doc """
  Counts signals matching a specific type pattern.
  """
  @spec count_type([map()], String.t()) :: non_neg_integer()
  def count_type(signals, type_pattern) do
    signals
    |> Enum.filter(&matches_type?(&1, type_pattern))
    |> length()
  end

  @doc """
  Filters signals matching a type pattern.
  """
  @spec filter_type([map()], String.t()) :: [map()]
  def filter_type(signals, type_pattern) do
    Enum.filter(signals, &matches_type?(&1, type_pattern))
  end

  @doc """
  Analyzes consensus-related signals.
  """
  @spec analyze_consensus([map()]) :: map()
  def analyze_consensus(signals) do
    consensus_signals = filter_type(signals, "director.consensus.*")

    %{
      total: length(consensus_signals),
      agreements: count_type(signals, "director.consensus.agreement"),
      disagreements: count_type(signals, "director.consensus.disagreement"),
      votes: extract_consensus_votes(consensus_signals)
    }
  end

  @doc """
  Analyzes phase transition signals.
  """
  @spec analyze_phase_transitions([map()]) :: map()
  def analyze_phase_transitions(signals) do
    entered = filter_type(signals, "interview.phase.entered")
    completed = filter_type(signals, "interview.phase.completed")

    transitions =
      Enum.map(entered, fn sig ->
        data = get_signal_data(sig)

        %{
          phase: data["phase"] || data[:phase],
          reason: data["reason"] || data[:reason],
          timestamp: get_timestamp(sig)
        }
      end)

    %{
      transitions: transitions,
      phases_entered: length(entered),
      phases_completed: length(completed),
      sequence: extract_phase_sequence(entered)
    }
  end

  @doc """
  Analyzes engagement-related signals.
  """
  @spec analyze_engagement([map()]) :: map()
  def analyze_engagement(signals) do
    engagement_signals = filter_type(signals, "observer.status.engagement")
    sentiment_signals = filter_type(signals, "observer.status.sentiment")
    alerts = filter_type(signals, "engagement.alert.*")

    %{
      engagement_updates: length(engagement_signals),
      sentiment_updates: length(sentiment_signals),
      alerts: length(alerts),
      frustration_detected: has_frustration_signal?(signals),
      end_intent_detected: has_end_intent_signal?(signals),
      engagement_levels: extract_engagement_levels(engagement_signals)
    }
  end

  @doc """
  Filters for error signals.
  """
  @spec filter_errors([map()]) :: [map()]
  def filter_errors(signals) do
    error_patterns = [
      "observer.status.error",
      "*.error",
      "*.failed"
    ]

    Enum.filter(signals, fn sig ->
      Enum.any?(error_patterns, &matches_type?(sig, &1))
    end)
  end

  @doc """
  Calculates timing metrics from signals.
  """
  @spec calculate_timing([map()]) :: map()
  def calculate_timing(signals) do
    timestamps =
      signals
      |> Enum.map(&get_timestamp/1)
      |> Enum.filter(&(not is_nil(&1)))
      |> Enum.sort()

    if length(timestamps) < 2 do
      %{
        total_duration_ms: 0,
        avg_signal_interval_ms: 0,
        signals_per_second: 0
      }
    else
      first = List.first(timestamps)
      last = List.last(timestamps)
      duration_ms = DateTime.diff(last, first, :millisecond)

      intervals =
        timestamps
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [a, b] -> DateTime.diff(b, a, :millisecond) end)

      avg_interval = if Enum.empty?(intervals), do: 0, else: Enum.sum(intervals) / length(intervals)

      %{
        total_duration_ms: duration_ms,
        avg_signal_interval_ms: Float.round(avg_interval, 1),
        signals_per_second: if(duration_ms > 0, do: Float.round(length(signals) / (duration_ms / 1000), 2), else: 0),
        first_signal: first,
        last_signal: last
      }
    end
  end

  @doc """
  Analyzes the flow of signals between agents.
  """
  @spec analyze_signal_flow([map()]) :: map()
  def analyze_signal_flow(signals) do
    # Group signals by exchange (rough grouping by time proximity)
    exchanges = group_into_exchanges(signals)

    %{
      exchange_count: length(exchanges),
      signals_per_exchange:
        if Enum.empty?(exchanges) do
          0
        else
          Float.round(length(signals) / length(exchanges), 1)
        end,
      exchange_breakdown:
        Enum.map(exchanges, fn exchange_signals ->
          %{
            signal_count: length(exchange_signals),
            agents_active: exchange_signals |> Enum.map(&get_source/1) |> Enum.uniq() |> length(),
            types: count_by_type(exchange_signals)
          }
        end)
    }
  end

  @doc """
  Extracts themes discovered during the conversation.
  """
  @spec extract_themes([map()]) :: [map()]
  def extract_themes(signals) do
    signals
    |> filter_type("observer.insight.theme")
    |> Enum.map(fn sig ->
      data = get_signal_data(sig)

      %{
        themes: data["themes"] || data[:themes] || [],
        confidence: data["confidence"] || data[:confidence],
        timestamp: get_timestamp(sig)
      }
    end)
  end

  @doc """
  Extracts probe suggestions from signals.
  """
  @spec extract_probes([map()]) :: [map()]
  def extract_probes(signals) do
    signals
    |> filter_type("observer.suggestion.probe")
    |> Enum.map(fn sig ->
      data = get_signal_data(sig)

      %{
        probes: data["probes"] || data[:probes] || [],
        context: data["context"] || data[:context],
        timestamp: get_timestamp(sig)
      }
    end)
  end

  # Private helpers

  defp extract_type_prefix(signal) do
    type = get_type(signal)

    case String.split(type, ".") do
      [prefix | _] -> prefix
      _ -> "unknown"
    end
  end

  defp matches_type?(signal, pattern) do
    type = get_type(signal)

    pattern_regex =
      pattern
      |> String.replace(".", "\\.")
      |> String.replace("**", ".+")
      |> String.replace("*", "[^.]+")

    Regex.match?(~r/^#{pattern_regex}$/, type)
  end

  defp matches_source?(signal, source) do
    get_source(signal) == source
  end

  defp get_type(%{type: type}), do: type
  defp get_type(%{"type" => type}), do: type
  defp get_type(_), do: "unknown"

  defp get_source(%{source: source}), do: source
  defp get_source(%{"source" => source}), do: source
  defp get_source(_), do: "unknown"

  defp get_signal_data(%{data: data}), do: data || %{}
  defp get_signal_data(%{"data" => data}), do: data || %{}
  defp get_signal_data(_), do: %{}

  defp get_timestamp(%{data: %{timestamp: ts}}), do: parse_timestamp(ts)
  defp get_timestamp(%{data: %{"timestamp" => ts}}), do: parse_timestamp(ts)
  defp get_timestamp(%{"data" => %{"timestamp" => ts}}), do: parse_timestamp(ts)
  defp get_timestamp(_), do: nil

  defp parse_timestamp(%DateTime{} = dt), do: dt
  defp parse_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
  defp parse_timestamp(_), do: nil

  defp first_timestamp(signals) do
    signals
    |> Enum.map(&get_timestamp/1)
    |> Enum.filter(&(not is_nil(&1)))
    |> Enum.min(DateTime, fn -> nil end)
  end

  defp last_timestamp(signals) do
    signals
    |> Enum.map(&get_timestamp/1)
    |> Enum.filter(&(not is_nil(&1)))
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp extract_consensus_votes(consensus_signals) do
    Enum.flat_map(consensus_signals, fn sig ->
      data = get_signal_data(sig)
      votes = data["votes"] || data[:votes] || []
      votes
    end)
  end

  defp extract_phase_sequence(entered_signals) do
    entered_signals
    |> Enum.sort_by(&get_timestamp/1, DateTime)
    |> Enum.map(fn sig ->
      data = get_signal_data(sig)
      data["phase"] || data[:phase] || "unknown"
    end)
  end

  defp has_frustration_signal?(signals) do
    Enum.any?(signals, fn sig ->
      data = get_signal_data(sig)
      frustration = data["frustration_level"] || data[:frustration_level] || 0
      frustration > 0.5
    end)
  end

  defp has_end_intent_signal?(signals) do
    Enum.any?(signals, fn sig ->
      data = get_signal_data(sig)
      intent = data["user_intent"] || data[:user_intent]
      intent == "end_interview" or intent == :end_interview
    end)
  end

  defp extract_engagement_levels(engagement_signals) do
    engagement_signals
    |> Enum.map(fn sig ->
      data = get_signal_data(sig)
      data["level"] || data[:level]
    end)
    |> Enum.filter(&(not is_nil(&1)))
  end

  defp group_into_exchanges(signals) do
    # Group signals that are within 500ms of each other as one exchange
    signals
    |> Enum.sort_by(&get_timestamp/1, DateTime)
    |> Enum.reduce([], fn signal, acc ->
      case acc do
        [] ->
          [[signal]]

        [current_group | rest] ->
          last_signal = List.last(current_group)
          last_ts = get_timestamp(last_signal)
          current_ts = get_timestamp(signal)

          if last_ts && current_ts && DateTime.diff(current_ts, last_ts, :millisecond) < 500 do
            [current_group ++ [signal] | rest]
          else
            [[signal] | acc]
          end
      end
    end)
    |> Enum.reverse()
  end
end
