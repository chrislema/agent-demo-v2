defmodule InterviewStudio.Agents.SentimentAgent do
  @moduledoc """
  Sentiment Agent - monitors user messages for frustration and emotional cues.

  Responsibilities:
  - Detect frustration signals in user messages
  - Identify when user is being curt or dismissive
  - Alert Director when sentiment needs attention
  - Track sentiment trends over the conversation
  """

  use GenServer
  require Logger

  alias InterviewStudio.InterviewBus

  defstruct [
    :session_id,
    :frustration_level,      # :none, :mild, :moderate, :high
    :frustration_history,    # Track recent frustration indicators
    :last_analysis,
    :consecutive_short_answers
  ]

  # Frustration indicators
  @frustration_phrases [
    "i already", "already said", "already answered", "already told you",
    "i just said", "just answered", "just told you",
    "didn't i just", "didn't i already",
    "you already asked", "you asked that", "same question",
    "that's the", "third time", "second time",
    "nope", "no.", "not really", "whatever",
    "i don't know what else", "what else do you want",
    "can we move on", "next question", "different topic",
    "this is repetitive", "stop asking"
  ]

  @dismissive_patterns [
    ~r/^no\.?$/i,
    ~r/^nope\.?$/i,
    ~r/^not really\.?$/i,
    ~r/^i guess\.?$/i,
    ~r/^whatever\.?$/i,
    ~r/^sure\.?$/i,
    ~r/^fine\.?$/i,
    ~r/^ok\.?$/i,
    ~r/^yeah\.?$/i
  ]

  # Client API

  def start_link(opts \\ []) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(session_id))
  end

  def analyze_message(session_id, message) do
    GenServer.cast(via_tuple(session_id), {:analyze, message})
  end

  def get_frustration_level(session_id) do
    GenServer.call(via_tuple(session_id), :get_level)
  end

  def get_state(session_id) do
    GenServer.call(via_tuple(session_id), :get_state)
  end

  @doc """
  Vote on phase transition based on sentiment.
  """
  def vote_transition(session_id, target_phase) do
    GenServer.call(via_tuple(session_id), {:vote_transition, target_phase})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    state = %__MODULE__{
      session_id: session_id,
      frustration_level: :none,
      frustration_history: [],
      last_analysis: nil,
      consecutive_short_answers: 0
    }

    # Subscribe to user messages
    InterviewBus.subscribe("interview.utterance.user")

    Logger.info("[SentimentAgent] Started for session #{session_id}")
    {:ok, state}
  end

  @impl true
  def handle_call(:get_level, _from, state) do
    {:reply, state.frustration_level, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:vote_transition, target_phase}, _from, state) do
    vote = case {target_phase, state.frustration_level} do
      # High frustration - support moving toward closing
      {:closing, :high} ->
        {:ready, "User shows high frustration - recommend wrapping up"}
      {:closing, :moderate} ->
        {:ready, "User shows frustration - closing would be appropriate"}

      # Support synthesis if frustrated
      {:synthesis, level} when level in [:moderate, :high] ->
        {:ready, "User frustration suggests moving toward synthesis"}

      # General case
      _ ->
        {:abstain, "No sentiment concerns for this transition"}
    end

    {:reply, vote, state}
  end

  @impl true
  def handle_cast({:analyze, message}, state) do
    new_state = analyze_and_update(message, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:signal, %{type: "interview.utterance.user"} = signal}, state) do
    message = signal.data[:content] || ""
    new_state = analyze_and_update(message, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:signal, _}, state), do: {:noreply, state}

  # Private functions

  defp analyze_and_update(message, state) do
    # Skip empty messages
    if message == "" or message == nil do
      state
    else
      analysis = analyze_message_sentiment(message)

      # Update consecutive short answer count
      consecutive_short = if analysis.is_short_answer do
        state.consecutive_short_answers + 1
      else
        0
      end

      # Calculate new frustration level
      new_level = calculate_frustration_level(analysis, consecutive_short, state)

      # Add to history
      history_entry = %{
        message: String.slice(message, 0, 50),
        indicators: analysis.indicators,
        timestamp: DateTime.utc_now()
      }
      new_history = [history_entry | state.frustration_history] |> Enum.take(10)

      new_state = %{state |
        frustration_level: new_level,
        frustration_history: new_history,
        last_analysis: analysis,
        consecutive_short_answers: consecutive_short
      }

      # Emit signal if frustration level changed or is elevated
      if new_level != state.frustration_level or new_level in [:moderate, :high] do
        emit_frustration_signal(new_level, analysis.indicators, state.session_id)
      end

      new_state
    end
  end

  defp analyze_message_sentiment(message) do
    downcased = String.downcase(message)
    word_count = message |> String.split() |> length()

    # Check for explicit frustration phrases
    frustration_matches = Enum.filter(@frustration_phrases, fn phrase ->
      String.contains?(downcased, phrase)
    end)

    # Check for dismissive patterns
    is_dismissive = Enum.any?(@dismissive_patterns, fn pattern ->
      Regex.match?(pattern, String.trim(message))
    end)

    # Check for short answers (less than 5 words)
    is_short_answer = word_count < 5

    # Check for punctuation patterns indicating frustration
    _has_ellipsis = String.contains?(message, "...")
    has_caps = message == String.upcase(message) and String.length(message) > 3
    ends_abruptly = String.ends_with?(String.trim(message), ".") and word_count < 3

    indicators = []
    indicators = if frustration_matches != [], do: [:explicit_frustration | indicators], else: indicators
    indicators = if is_dismissive, do: [:dismissive | indicators], else: indicators
    indicators = if is_short_answer, do: [:short_answer | indicators], else: indicators
    indicators = if has_caps, do: [:caps_emphasis | indicators], else: indicators
    indicators = if ends_abruptly, do: [:abrupt | indicators], else: indicators

    %{
      indicators: indicators,
      frustration_phrases: frustration_matches,
      is_dismissive: is_dismissive,
      is_short_answer: is_short_answer,
      word_count: word_count
    }
  end

  defp calculate_frustration_level(analysis, consecutive_short, state) do
    # Score based on current message
    score = 0
    score = if :explicit_frustration in analysis.indicators, do: score + 3, else: score
    score = if :dismissive in analysis.indicators, do: score + 2, else: score
    score = if :short_answer in analysis.indicators, do: score + 1, else: score
    score = if :caps_emphasis in analysis.indicators, do: score + 1, else: score
    score = if :abrupt in analysis.indicators, do: score + 1, else: score

    # Boost for consecutive short answers
    score = score + min(consecutive_short, 3)

    # Consider recent history
    recent_frustration = state.frustration_history
    |> Enum.take(3)
    |> Enum.count(fn h -> :explicit_frustration in h.indicators or :dismissive in h.indicators end)

    score = score + recent_frustration

    # Map score to level
    cond do
      score >= 5 -> :high
      score >= 3 -> :moderate
      score >= 1 -> :mild
      true -> :none
    end
  end

  defp emit_frustration_signal(level, indicators, _session_id) do
    recommendation = case level do
      :high -> "User is frustrated - apologize briefly and change topic immediately"
      :moderate -> "User seems irritated - accept their answer and move on"
      :mild -> "User may be getting impatient - keep responses concise"
      :none -> "Sentiment is neutral"
    end

    signal = %Jido.Signal{
      type: "observer.status.frustration",
      source: "sentiment_agent",
      id: Jido.Util.generate_id(),
      data: %{
        level: level,
        indicators: indicators,
        recommendation: recommendation,
        timestamp: DateTime.utc_now()
      }
    }

    InterviewBus.publish(signal)
    Logger.info("[SentimentAgent] Frustration level: #{level}, indicators: #{inspect(indicators)}")
  end

  defp via_tuple(session_id) do
    {:via, Registry, {InterviewStudio.SessionRegistry, {:sentiment_agent, session_id}}}
  end
end
