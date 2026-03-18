defmodule InterviewStudio.Agents.SentimentAgent do
  @moduledoc """
  Sentiment Agent - monitors user messages for frustration, intent, and emotional cues.

  Phase 4: Domain-Agnostic Architecture
  - Loads heuristics from domain config (heuristics/sentiment.yaml)
  - Intent detection phrases come from config
  - Frustration detection phrases come from config

  Responsibilities:
  - Detect frustration signals in user messages using LLM understanding
  - Identify user intent: continue, change_topic, or end_interview
  - Track chronological direction preference (forward/backward/neutral)
  - Alert Director with semantic signals for decision-making
  - Track sentiment trends over the conversation

  Implemented as a Jido.Agent with signal_routes and Actions.
  """

  use Jido.Agent,
    name: "sentiment_agent",
    description: "Monitors user frustration, intent, and emotional cues",
    schema: [
      session_id: [type: :any, default: nil],
      frustration_level: [type: :atom, default: :none],
      user_intent: [type: :atom, default: :continue],
      chronological_direction: [type: :atom, default: :neutral],
      frustration_history: [type: :any, default: []],
      last_analysis: [type: :any, default: nil],
      consecutive_short_answers: [type: :integer, default: 0],
      engagement_level: [type: :atom, default: :high],
      current_phase: [type: :atom, default: :opening],
      llm_config: [type: :any, default: %{}],
      domain: [type: :any, default: nil],
      heuristics: [type: :any, default: %{}],
      last_question: [type: :any, default: nil]
    ],
    signal_routes: [
      {"interview.utterance.user", InterviewStudio.Agents.SentimentAgent.Actions.AnalyzeUserMessage},
      {"interview.utterance.host", InterviewStudio.Agents.SentimentAgent.Actions.TrackHostQuestion},
      {"observer.status.engagement", InterviewStudio.Agents.SentimentAgent.Actions.HandleEngagement},
      {"interview.phase.entered", InterviewStudio.Agents.SentimentAgent.Actions.HandlePhaseChange},
      {"interview.phase.changed", InterviewStudio.Agents.SentimentAgent.Actions.HandlePhaseChange}
    ]

  require Logger

  alias InterviewStudio.InterviewBus
  alias InterviewStudio.DomainLoader

  # Client API

  def start_link(opts \\ []) do
    session_id = Keyword.fetch!(opts, :session_id)
    llm_config = Keyword.get(opts, :llm_config, default_llm_config())

    # PHASE 4: Get domain from opts
    domain = Keyword.get(opts, :domain)

    # PHASE 4: Load heuristics from domain config
    heuristics = if domain do
      DomainLoader.get_heuristics(domain, :sentiment_agent)
    else
      %{}
    end

    {:ok, pid} = Jido.AgentServer.start_link(
      agent: __MODULE__,
      name: via_tuple(session_id),
      id: "sentiment_agent_#{session_id}",
      register_global: false,
      initial_state: %{
        session_id: session_id,
        llm_config: llm_config,
        domain: domain,
        heuristics: heuristics
      }
    )

    # Subscribe to InterviewBus signals
    InterviewBus.subscribe_pid("interview.utterance.user", pid)
    InterviewBus.subscribe_pid("interview.utterance.host", pid)
    InterviewBus.subscribe_pid("observer.status.engagement", pid)
    InterviewBus.subscribe_pid("interview.phase.**", pid)

    Logger.info("[SentimentAgent] Started for session #{session_id} (domain: #{domain && domain.name || "default"})")
    {:ok, pid}
  end

  def analyze_message(session_id, message) do
    signal = %Jido.Signal{
      type: "interview.utterance.user",
      source: "session",
      id: Jido.Util.generate_id(),
      data: %{content: message},
      time: DateTime.utc_now()
    }
    GenServer.cast(via_tuple(session_id), {:signal, signal})
  end

  def get_frustration_level(session_id) do
    state = get_agent_state(session_id)
    state.frustration_level
  end

  def get_state(session_id) do
    get_agent_state(session_id)
  end

  @doc """
  Vote on phase transition based on sentiment.
  """
  def vote_transition(session_id, target_phase) do
    state = get_agent_state(session_id)
    evaluate_vote(target_phase, state)
  end

  # Private helpers

  defp get_agent_state(session_id) do
    {:ok, server_state} = Jido.AgentServer.state(via_tuple(session_id))
    server_state.agent.state
  end

  defp via_tuple(session_id) do
    {:via, Registry, {InterviewStudio.SessionRegistry, {:sentiment_agent, session_id}}}
  end

  defp default_llm_config do
    %{
      provider: :openrouter,
      model: "meta-llama/llama-4-scout-17b-16e-instruct",
      temperature: 0.3
    }
  end

  defp evaluate_vote(target_phase, state) do
    case {target_phase, state.frustration_level} do
      {:closing, :high} ->
        {:ready, "User shows high frustration - recommend wrapping up"}
      {:closing, :moderate} ->
        {:ready, "User shows frustration - closing would be appropriate"}
      {:synthesis, level} when level in [:moderate, :high] ->
        {:ready, "User frustration suggests moving toward synthesis"}
      _ ->
        {:abstain, "No sentiment concerns for this transition"}
    end
  end
end

# =============================================================================
# Action: AnalyzeUserMessage
# =============================================================================

defmodule InterviewStudio.Agents.SentimentAgent.Actions.AnalyzeUserMessage do
  @moduledoc "Analyzes user messages for frustration, intent, and temporal direction."

  use Jido.Action,
    name: "sentiment_analyze_user_message",
    description: "Analyze user message for sentiment and intent",
    schema: [
      content: [type: :any],
      timestamp: [type: :any]
    ]

  require Logger

  alias InterviewStudio.InterviewBus
  alias InterviewStudio.PromptLoader

  # LLM timeout for graceful degradation
  @llm_timeout_ms 2000

  @impl true
  def run(params, context) do
    state = context.state
    message = params[:content] || ""

    if message == "" do
      {:ok, %{}}
    else
      analysis = analyze_message_sentiment_llm(message, state)

      word_count = message |> String.split() |> length()
      consecutive_short = if word_count < 5 do
        (state.consecutive_short_answers || 0) + 1
      else
        0
      end

      history_entry = %{
        message: String.slice(message, 0, 50),
        indicators: analysis.indicators,
        user_intent: analysis.user_intent,
        timestamp: DateTime.utc_now()
      }
      new_history = [history_entry | (state.frustration_history || [])] |> Enum.take(10)

      # Always emit semantic signal so Director has current intent
      emit_sentiment_signal(analysis, state.session_id)

      # Also emit frustration signal for backward compatibility
      if analysis.frustration_level != state.frustration_level or
         analysis.frustration_level in [:moderate, :high] do
        emit_frustration_signal(analysis.frustration_level, analysis.indicators, state.session_id)
      end

      {:ok, %{
        frustration_level: analysis.frustration_level,
        user_intent: analysis.user_intent,
        chronological_direction: analysis.chronological_direction,
        frustration_history: new_history,
        last_analysis: analysis,
        consecutive_short_answers: consecutive_short
      }}
    end
  end

  # LLM-based sentiment analysis with timeout and fallback
  defp analyze_message_sentiment_llm(message, state) do
    last_question = state.last_question || "Tell me about yourself"
    task = Task.async(fn -> call_sentiment_llm(message, last_question, state.llm_config || %{}) end)

    case Task.yield(task, @llm_timeout_ms) do
      {:ok, {:ok, result}} ->
        Logger.debug("[SentimentAgent] LLM analysis: #{inspect(result)}")
        result

      {:ok, {:error, reason}} ->
        Logger.warning("[SentimentAgent] LLM failed: #{inspect(reason)}, using fallback")
        fallback_sentiment_analysis(message, state.heuristics || %{})

      nil ->
        Task.shutdown(task, :brutal_kill)
        Logger.warning("[SentimentAgent] LLM timeout, using fallback")
        fallback_sentiment_analysis(message, state.heuristics || %{})
    end
  end

  defp call_sentiment_llm(message, question, config) do
    system_prompt = PromptLoader.load!("interview", "sentiment_agent", "system",
      default_sentiment_system_prompt())

    variables = %{message: message, question: question}
    user_prompt = PromptLoader.load_with_vars!("interview", "sentiment_agent", "analyze", variables,
      default_sentiment_analyze_prompt(message, question))

    try do
      model_name = config[:model] || "meta-llama/llama-4-scout-17b-16e-instruct"

      case Jido.Exec.run(Jido.AI.Actions.LLM.Chat, %{
        model: "groq:#{model_name}",
        prompt: user_prompt,
        system_prompt: system_prompt,
        temperature: 0.3,
        max_tokens: 100
      }) do
        {:ok, %{text: content}} ->
          parse_sentiment_json(content)

        {:ok, result} when is_map(result) ->
          parse_sentiment_json(Map.get(result, :text, "{}"))

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      e ->
        Logger.error("[SentimentAgent] LLM call failed: #{inspect(e)}")
        {:error, "LLM call failed"}
    end
  end

  defp default_sentiment_system_prompt do
    """
    You are a sentiment analyzer for interview conversations.
    Respond ONLY with valid JSON: {"frustration_level": "none", "user_intent": "continue", "chronological_direction": "neutral"}
    """
  end

  defp default_sentiment_analyze_prompt(message, question) do
    """
    Analyze this interview exchange for sentiment, intent, and temporal direction.

    INTERVIEWER ASKED: "#{question}"
    USER RESPONDED: "#{message}"

    For chronological_direction, consider: Did the user stay at the life stage the question asked about, move forward in their story (e.g., origin/background question but they pivoted to college/career), or move backward (e.g., career question but they went back to early influences)?

    Respond with ONLY JSON: {"frustration_level": "none|mild|moderate|high", "user_intent": "continue|change_topic|end_interview", "chronological_direction": "forward|backward|neutral"}
    """
  end

  defp parse_sentiment_json(content) do
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

  # PHASE 4: Fallback heuristic analysis using config-driven phrases
  defp fallback_sentiment_analysis(message, heuristics) do
    downcased = String.downcase(message)
    word_count = message |> String.split() |> length()

    intent_config = heuristics[:intent_detection] || default_intent_detection()
    frustration_config = heuristics[:frustration_phrases] || default_frustration_phrases()
    chrono_config = heuristics[:chronological_keywords] || default_chronological_keywords()
    thresholds = heuristics[:thresholds] || %{}
    short_answer_words = thresholds[:short_answer_words] || 5

    user_intent = detect_user_intent(downcased, intent_config)
    frustration_level = detect_frustration(downcased, frustration_config)
    chronological_direction = detect_chronological(downcased, chrono_config)

    indicators = []
    indicators = if frustration_level in [:moderate, :high], do: [:frustration_detected | indicators], else: indicators
    indicators = if user_intent == :change_topic, do: [:topic_change_requested | indicators], else: indicators
    indicators = if user_intent == :end_interview, do: [:end_requested | indicators], else: indicators
    indicators = if word_count < short_answer_words, do: [:short_answer | indicators], else: indicators

    %{
      frustration_level: frustration_level,
      user_intent: user_intent,
      chronological_direction: chronological_direction,
      indicators: indicators
    }
  end

  defp detect_user_intent(text, config) do
    cond do
      matches_any?(text, config[:end_interview] || []) -> :end_interview
      matches_any?(text, config[:change_topic] || []) -> :change_topic
      true -> :continue
    end
  end

  defp detect_frustration(text, config) do
    cond do
      matches_any?(text, config[:high] || []) -> :high
      matches_any?(text, config[:moderate] || []) -> :moderate
      matches_any?(text, config[:mild] || []) -> :mild
      true -> :none
    end
  end

  defp detect_chronological(text, config) do
    cond do
      matches_any?(text, config[:forward] || []) -> :forward
      matches_any?(text, config[:backward] || []) -> :backward
      true -> :neutral
    end
  end

  defp matches_any?(text, phrases) do
    Enum.any?(phrases, &String.contains?(text, &1))
  end

  defp default_intent_detection do
    %{
      end_interview: ["let's wrap", "i'm done", "let's end", "that's enough"],
      change_topic: ["move on", "different topic", "something else", "don't want to talk about"]
    }
  end

  defp default_frustration_phrases do
    %{
      high: ["stop asking", "this is ridiculous", "i told you", "how many times"],
      moderate: ["already told", "already said", "this is repetitive"],
      mild: ["i already", "you already asked"]
    }
  end

  defp default_chronological_keywords do
    %{
      forward: ["future", "goal", "vision", "career", "working toward"],
      backward: ["grew up", "when i was younger", "early years", "back then"]
    }
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
end

# =============================================================================
# Action: TrackHostQuestion
# =============================================================================

defmodule InterviewStudio.Agents.SentimentAgent.Actions.TrackHostQuestion do
  @moduledoc "Tracks interviewer questions for context in temporal analysis."

  use Jido.Action,
    name: "sentiment_track_host_question",
    description: "Track last interviewer question for context",
    schema: [
      content: [type: :any],
      timestamp: [type: :any]
    ]

  require Logger

  @impl true
  def run(params, _context) do
    question = params[:content] || ""
    Logger.debug("[SentimentAgent] Tracking last question for context: #{String.slice(question, 0, 50)}...")
    {:ok, %{last_question: question}}
  end
end

# =============================================================================
# Action: HandleEngagement
# =============================================================================

defmodule InterviewStudio.Agents.SentimentAgent.Actions.HandleEngagement do
  @moduledoc "Handles engagement updates; escalates frustration when engagement is critical."

  use Jido.Action,
    name: "sentiment_handle_engagement",
    description: "Handle engagement update and maybe escalate frustration",
    schema: [
      level: [type: :any]
    ]

  require Logger

  alias InterviewStudio.InterviewBus

  @impl true
  def run(params, context) do
    state = context.state
    level = params[:level] || :high
    Logger.debug("[SentimentAgent] <- [EngagementMonitor] Engagement: #{level}")

    new_state = %{engagement_level: level}

    # If engagement is critical and we have any frustration, escalate it
    if level == :critical and state.frustration_level not in [:none] do
      escalated = escalate_frustration(state.frustration_level)
      Logger.info("[SentimentAgent] Escalating frustration from #{state.frustration_level} to #{escalated} due to critical engagement")
      emit_frustration_signal(escalated, [:engagement_critical], state.session_id)
      {:ok, Map.put(new_state, :frustration_level, escalated)}
    else
      {:ok, new_state}
    end
  end

  defp escalate_frustration(:mild), do: :moderate
  defp escalate_frustration(:moderate), do: :high
  defp escalate_frustration(level), do: level

  defp emit_frustration_signal(level, indicators, _session_id) do
    recommendation = case level do
      :high -> "User is frustrated - apologize briefly and change topic immediately"
      :moderate -> "User seems irritated - accept their answer and move on"
      _ -> "Monitor frustration"
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
  end
end

# =============================================================================
# Action: HandlePhaseChange
# =============================================================================

defmodule InterviewStudio.Agents.SentimentAgent.Actions.HandlePhaseChange do
  @moduledoc "Updates current phase on phase transitions."

  use Jido.Action,
    name: "sentiment_handle_phase_change",
    description: "Track phase changes for frustration tolerance",
    schema: [
      phase: [type: :any],
      phase_name: [type: :any],
      to_phase: [type: :any]
    ]

  require Logger

  @impl true
  def run(params, _context) do
    phase = params[:phase] || params[:phase_name] || params[:to_phase]
    if phase do
      Logger.debug("[SentimentAgent] <- [Director] Phase change: #{phase}")
      {:ok, %{current_phase: phase}}
    else
      {:ok, %{}}
    end
  end
end
