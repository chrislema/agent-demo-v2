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

  defstruct [
    :session_id,
    :level,
    :trend,
    :history,
    :indicators,
    :last_emission
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

  # Server Callbacks

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    state = %__MODULE__{
      session_id: session_id,
      level: :high,
      trend: :stable,
      history: [],
      indicators: %{},
      last_emission: nil
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
  def handle_info({:signal, signal}, state) do
    new_state = handle_signal(signal, state)
    {:noreply, new_state}
  end

  # Signal handlers

  defp handle_signal(%{type: "interview.utterance.user"} = signal, state) do
    content = signal.data.content

    # Analyze the response
    indicators = analyze_response(content)

    # Calculate new level
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

  defp analyze_response(content) do
    word_count = content |> String.split() |> length()
    char_count = String.length(content)

    %{
      word_count: word_count,
      char_count: char_count,
      has_enthusiasm: has_enthusiasm?(content),
      has_resistance: has_resistance?(content),
      has_elaboration: has_elaboration?(content),
      is_terse: word_count < 5,
      is_verbose: word_count > 100,
      sentiment: estimate_sentiment(content)
    }
  end

  defp has_enthusiasm?(text) do
    enthusiasm_markers = ["!", "love", "excited", "amazing", "great", "absolutely", "definitely", "really"]
    downcased = String.downcase(text)
    Enum.any?(enthusiasm_markers, fn marker -> String.contains?(downcased, marker) end)
  end

  defp has_resistance?(text) do
    resistance_markers = ["i don't know", "not sure", "maybe", "i guess", "whatever", "fine", "ok", "sure"]
    downcased = String.downcase(text)
    # Count how many resistance markers appear
    count = Enum.count(resistance_markers, fn marker -> String.contains?(downcased, marker) end)
    # Only flag if multiple markers or response is short
    count >= 2 or (count >= 1 and String.length(text) < 30)
  end

  defp has_elaboration?(text) do
    # Signs of elaboration: examples, stories, details
    elaboration_markers = ["for example", "like when", "i remember", "one time", "because", "the reason", "actually"]
    downcased = String.downcase(text)
    Enum.any?(elaboration_markers, fn marker -> String.contains?(downcased, marker) end)
  end

  defp estimate_sentiment(text) do
    positive_words = ~w(love great amazing wonderful happy excited good best)
    negative_words = ~w(hate bad terrible awful frustrated annoyed difficult hard)

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
    # Score components
    length_score = cond do
      indicators.is_terse -> -2
      indicators.is_verbose -> 1
      indicators.word_count > 20 -> 1
      indicators.word_count > 10 -> 0
      true -> -1
    end

    enthusiasm_score = if indicators.has_enthusiasm, do: 1, else: 0
    resistance_score = if indicators.has_resistance, do: -2, else: 0
    elaboration_score = if indicators.has_elaboration, do: 1, else: 0

    sentiment_score = case indicators.sentiment do
      :positive -> 1
      :negative -> -1
      :neutral -> 0
    end

    total_score = length_score + enthusiasm_score + resistance_score + elaboration_score + sentiment_score

    # Map to level
    new_level = cond do
      total_score >= 2 -> :high
      total_score >= 0 -> :medium
      total_score >= -2 -> :low
      true -> :critical
    end

    # Calculate trend based on history
    new_trend = calculate_trend(new_level, state.history)

    {new_level, new_trend}
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
    recommendation = case {state.level, state.trend} do
      {:critical, _} -> "Consider wrapping up or changing topic"
      {:low, :declining} -> "Try a different approach or easier question"
      {:low, _} -> "Keep questions light and build rapport"
      {:medium, :declining} -> "Engagement dropping, consider a more engaging topic"
      {:high, _} -> "Good engagement, continue current approach"
      _ -> "Monitor and adjust as needed"
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

  defp subscribe_to_signals do
    InterviewBus.subscribe("interview.utterance.user")
  end

  defp via_tuple(session_id) do
    {:via, Registry, {InterviewStudio.SessionRegistry, {:engagement_monitor, session_id}}}
  end
end
