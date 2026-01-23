defmodule InterviewStudio.Agents.SentimentAgent do
  @moduledoc """
  Sentiment Agent - monitors user messages for frustration, intent, and emotional cues.

  Responsibilities:
  - Detect frustration signals in user messages using LLM understanding
  - Identify user intent: continue, change_topic, or end_interview
  - Track chronological direction preference (forward/backward/neutral)
  - Alert Director with semantic signals for decision-making
  - Track sentiment trends over the conversation
  """

  use GenServer
  require Logger

  alias InterviewStudio.InterviewBus

  defstruct [
    :session_id,
    :frustration_level,      # :none, :mild, :moderate, :high
    :user_intent,            # :continue, :change_topic, :end_interview
    :chronological_direction, # :forward, :backward, :neutral
    :frustration_history,    # Track recent frustration indicators
    :last_analysis,
    :consecutive_short_answers,
    :engagement_level,       # From Engagement Monitor - affects frustration escalation
    :current_phase,          # From phase changes - affects frustration tolerance
    :llm_config              # LLM configuration for semantic analysis
  ]

  # LLM timeout for graceful degradation
  @llm_timeout_ms 2000

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
    llm_config = Keyword.get(opts, :llm_config, default_llm_config())

    state = %__MODULE__{
      session_id: session_id,
      frustration_level: :none,
      user_intent: :continue,
      chronological_direction: :neutral,
      frustration_history: [],
      last_analysis: nil,
      consecutive_short_answers: 0,
      engagement_level: :high,
      current_phase: :opening,
      llm_config: llm_config
    }

    # Subscribe to user messages
    InterviewBus.subscribe("interview.utterance.user")
    # CROSS-AGENT: Subscribe to engagement updates - when engagement drops, escalate frustration
    InterviewBus.subscribe("observer.status.engagement")
    # CROSS-AGENT: Subscribe to phase changes - be more lenient on frustration during closing
    InterviewBus.subscribe("interview.phase.**")

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

  # CROSS-AGENT: Receive engagement updates from Engagement Monitor
  @impl true
  def handle_info({:signal, %{type: "observer.status.engagement"} = signal}, state) do
    level = signal.data[:level] || :high
    Logger.debug("[SentimentAgent] <- [EngagementMonitor] Engagement: #{level}")
    new_state = %{state | engagement_level: level}

    # If engagement is critical and we have any frustration, escalate it
    new_state = if level == :critical and state.frustration_level not in [:none] do
      escalated = escalate_frustration(state.frustration_level)
      Logger.info("[SentimentAgent] Escalating frustration from #{state.frustration_level} to #{escalated} due to critical engagement")
      emit_frustration_signal(escalated, [:engagement_critical], state.session_id)
      %{new_state | frustration_level: escalated}
    else
      new_state
    end

    {:noreply, new_state}
  end

  # CROSS-AGENT: Receive phase changes - adjust frustration tolerance
  @impl true
  def handle_info({:signal, %{type: "interview.phase." <> _} = signal}, state) do
    phase = signal.data[:phase] || signal.data[:to_phase]
    if phase do
      Logger.debug("[SentimentAgent] <- [Director] Phase change: #{phase}")
      {:noreply, %{state | current_phase: phase}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:signal, _}, state), do: {:noreply, state}

  # Private functions

  defp analyze_and_update(message, state) do
    # Skip empty messages
    if message == "" or message == nil do
      state
    else
      # Use LLM-based analysis with fallback to heuristics
      analysis = analyze_message_sentiment_llm(message, state)

      # Update consecutive short answer count
      word_count = message |> String.split() |> length()
      consecutive_short = if word_count < 5 do
        state.consecutive_short_answers + 1
      else
        0
      end

      # Add to history
      history_entry = %{
        message: String.slice(message, 0, 50),
        indicators: analysis.indicators,
        user_intent: analysis.user_intent,
        timestamp: DateTime.utc_now()
      }
      new_history = [history_entry | state.frustration_history] |> Enum.take(10)

      new_state = %{state |
        frustration_level: analysis.frustration_level,
        user_intent: analysis.user_intent,
        chronological_direction: analysis.chronological_direction,
        frustration_history: new_history,
        last_analysis: analysis,
        consecutive_short_answers: consecutive_short
      }

      # Always emit semantic signal so Director has current intent
      emit_sentiment_signal(analysis, state.session_id)

      # Also emit legacy frustration signal for backward compatibility
      if analysis.frustration_level != state.frustration_level or
         analysis.frustration_level in [:moderate, :high] do
        emit_frustration_signal(analysis.frustration_level, analysis.indicators, state.session_id)
      end

      new_state
    end
  end

  # LLM-based sentiment analysis with timeout and fallback
  defp analyze_message_sentiment_llm(message, state) do
    # Start async LLM call with timeout
    task = Task.async(fn -> call_sentiment_llm(message, state.llm_config) end)

    case Task.yield(task, @llm_timeout_ms) do
      {:ok, {:ok, result}} ->
        Logger.debug("[SentimentAgent] LLM analysis: #{inspect(result)}")
        result

      {:ok, {:error, reason}} ->
        Logger.warning("[SentimentAgent] LLM failed: #{inspect(reason)}, using fallback")
        fallback_sentiment_analysis(message)

      nil ->
        Task.shutdown(task, :brutal_kill)
        Logger.warning("[SentimentAgent] LLM timeout, using fallback")
        fallback_sentiment_analysis(message)
    end
  end

  # Call LLM for semantic sentiment analysis
  defp call_sentiment_llm(message, config) do
    system_prompt = """
    You are a sentiment analyzer for interview conversations. Analyze the user's message and determine their emotional state and intent.

    Respond ONLY with valid JSON in this exact format:
    {"frustration_level": "none", "user_intent": "continue", "chronological_direction": "neutral"}

    Valid values:
    - frustration_level: "none", "mild", "moderate", "high"
    - user_intent: "continue", "change_topic", "end_interview"
    - chronological_direction: "forward", "backward", "neutral"
    """

    user_prompt = """
    Analyze this interview response for sentiment and intent.

    User said: "#{message}"

    Determine:
    1. frustration_level: none | mild | moderate | high
    2. user_intent: continue | change_topic | end_interview
    3. chronological_direction: forward | backward | neutral

    Guidelines:
    - "Can we move on" or "let's move on" = change_topic (NOT end_interview, NOT frustration)
    - "I don't want to talk about X" = change_topic (NOT end_interview)
    - "Let's wrap up" or "I'm done" or "let's end" = end_interview
    - Short answers alone are NOT frustration - only explicit irritation is frustration
    - "already told you" or "I already said" = mild/moderate frustration
    - Talking about future/career/goals/vision = forward
    - Talking about childhood/early years/growing up = backward
    - Most responses are neutral chronologically

    Respond with ONLY the JSON, no other text.
    """

    try do
      api_key = System.get_env("AgentDemo_Groq_API_Key") || ""

      model = %Jido.AI.Model{
        provider: :openrouter,
        base_url: "https://api.groq.com/openai/v1/chat/completions",
        model: config[:model] || "meta-llama/llama-4-scout-17b-16e-instruct",
        api_key: api_key,
        temperature: 0.3,
        max_tokens: 100
      }

      prompt = Jido.AI.Prompt.new(%{
        messages: [
          %{role: :system, content: system_prompt},
          %{role: :user, content: user_prompt}
        ]
      })

      case Jido.AI.Actions.Langchain.run(%{model: model, prompt: prompt}, %{}) do
        {:ok, %{content: content}} ->
          parse_sentiment_json(content)

        {:ok, result} when is_map(result) ->
          parse_sentiment_json(Map.get(result, :content, "{}"))

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      e ->
        Logger.error("[SentimentAgent] LLM call failed: #{inspect(e)}")
        {:error, "LLM call failed"}
    end
  end

  # Parse JSON response from LLM
  defp parse_sentiment_json(content) do
    # Extract JSON from response (LLM might include extra text)
    json_str = case Regex.run(~r/\{[^}]+\}/, content) do
      [match] -> match
      _ -> content
    end

    case Jason.decode(json_str) do
      {:ok, data} ->
        {:ok, %{
          frustration_level: parse_frustration_level(data["frustration_level"]),
          user_intent: parse_user_intent(data["user_intent"]),
          chronological_direction: parse_chronological_direction(data["chronological_direction"]),
          indicators: build_indicators_from_analysis(data)
        }}

      {:error, _} ->
        Logger.warning("[SentimentAgent] Failed to parse JSON: #{content}")
        {:error, "JSON parse failed"}
    end
  end

  defp parse_frustration_level("high"), do: :high
  defp parse_frustration_level("moderate"), do: :moderate
  defp parse_frustration_level("mild"), do: :mild
  defp parse_frustration_level(_), do: :none

  defp parse_user_intent("end_interview"), do: :end_interview
  defp parse_user_intent("change_topic"), do: :change_topic
  defp parse_user_intent(_), do: :continue

  defp parse_chronological_direction("forward"), do: :forward
  defp parse_chronological_direction("backward"), do: :backward
  defp parse_chronological_direction(_), do: :neutral

  defp build_indicators_from_analysis(data) do
    indicators = []
    indicators = if data["frustration_level"] in ["moderate", "high"], do: [:frustration_detected | indicators], else: indicators
    indicators = if data["user_intent"] == "change_topic", do: [:topic_change_requested | indicators], else: indicators
    indicators = if data["user_intent"] == "end_interview", do: [:end_requested | indicators], else: indicators
    indicators
  end

  # Fallback heuristic analysis when LLM is unavailable
  defp fallback_sentiment_analysis(message) do
    downcased = String.downcase(message)
    word_count = message |> String.split() |> length()

    # Detect user intent from common phrases
    user_intent = cond do
      String.contains?(downcased, "let's wrap") or
      String.contains?(downcased, "i'm done") or
      String.contains?(downcased, "let's end") or
      String.contains?(downcased, "that's enough") ->
        :end_interview

      String.contains?(downcased, "move on") or
      String.contains?(downcased, "different topic") or
      String.contains?(downcased, "something else") or
      String.contains?(downcased, "don't want to talk about") ->
        :change_topic

      true ->
        :continue
    end

    # Detect frustration (more conservative than before)
    frustration_level = cond do
      # High frustration - explicit anger/exasperation
      String.contains?(downcased, "stop asking") or
      String.contains?(downcased, "this is ridiculous") or
      String.contains?(downcased, "i told you") or
      String.contains?(downcased, "how many times") ->
        :high

      # Moderate frustration - repetition frustration
      String.contains?(downcased, "already told") or
      String.contains?(downcased, "already said") or
      String.contains?(downcased, "this is repetitive") ->
        :moderate

      # Mild frustration - impatience signals
      String.contains?(downcased, "i already") or
      String.contains?(downcased, "you already asked") ->
        :mild

      true ->
        :none
    end

    # Detect chronological direction
    chronological_direction = cond do
      String.contains?(downcased, "future") or
      String.contains?(downcased, "goal") or
      String.contains?(downcased, "vision") or
      String.contains?(downcased, "career") or
      String.contains?(downcased, "working toward") ->
        :forward

      String.contains?(downcased, "childhood") or
      String.contains?(downcased, "grew up") or
      String.contains?(downcased, "when i was young") or
      String.contains?(downcased, "early years") ->
        :backward

      true ->
        :neutral
    end

    indicators = []
    indicators = if frustration_level in [:moderate, :high], do: [:frustration_detected | indicators], else: indicators
    indicators = if user_intent == :change_topic, do: [:topic_change_requested | indicators], else: indicators
    indicators = if user_intent == :end_interview, do: [:end_requested | indicators], else: indicators
    indicators = if word_count < 5, do: [:short_answer | indicators], else: indicators

    %{
      frustration_level: frustration_level,
      user_intent: user_intent,
      chronological_direction: chronological_direction,
      indicators: indicators
    }
  end


  # Helper to escalate frustration level when engagement is critical
  defp escalate_frustration(:mild), do: :moderate
  defp escalate_frustration(:moderate), do: :high
  defp escalate_frustration(level), do: level

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

  # Emit comprehensive semantic signal for Director consumption
  defp emit_sentiment_signal(analysis, _session_id) do
    signal = %Jido.Signal{
      type: "observer.status.sentiment",
      source: "sentiment_agent",
      id: Jido.Util.generate_id(),
      data: %{
        frustration_level: analysis.frustration_level,
        user_intent: analysis.user_intent,
        chronological_direction: analysis.chronological_direction,
        indicators: analysis.indicators,
        timestamp: DateTime.utc_now()
      }
    }

    InterviewBus.publish(signal)
    Logger.info("[SentimentAgent] Semantic signal - intent: #{analysis.user_intent}, direction: #{analysis.chronological_direction}, frustration: #{analysis.frustration_level}")
  end

  defp default_llm_config do
    %{
      provider: :openrouter,
      model: "meta-llama/llama-4-scout-17b-16e-instruct",
      temperature: 0.3
    }
  end

  defp via_tuple(session_id) do
    {:via, Registry, {InterviewStudio.SessionRegistry, {:sentiment_agent, session_id}}}
  end
end
