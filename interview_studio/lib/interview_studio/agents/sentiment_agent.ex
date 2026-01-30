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
  """

  use GenServer
  require Logger

  alias InterviewStudio.InterviewBus
  alias InterviewStudio.PromptLoader
  alias InterviewStudio.DomainLoader

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
    :llm_config,             # LLM configuration for semantic analysis
    :domain,                 # PHASE 4: Domain configuration
    :heuristics,             # PHASE 4: Agent-specific heuristics from YAML
    :last_question           # Track last question asked for context
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

    # PHASE 4: Get domain from opts (passed by AgentSupervisor)
    domain = Keyword.get(opts, :domain)

    # PHASE 4: Load heuristics from domain config
    heuristics = if domain do
      DomainLoader.get_heuristics(domain, :sentiment_agent)
    else
      %{}
    end

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
      llm_config: llm_config,
      domain: domain,
      heuristics: heuristics
    }

    # PHASE 4: Subscribe based on domain config or use defaults
    subscribe_to_signals(domain)

    Logger.info("[SentimentAgent] Started for session #{session_id} (domain: #{domain && domain.name || "default"})")
    {:ok, state}
  end

  # PHASE 4: Subscribe to signals based on domain config or use defaults
  defp subscribe_to_signals(nil) do
    InterviewBus.subscribe("interview.utterance.user")
    InterviewBus.subscribe("observer.status.engagement")
    InterviewBus.subscribe("interview.phase.**")
  end

  defp subscribe_to_signals(domain) do
    subscriptions = DomainLoader.get_subscriptions(domain, :sentiment_agent)

    if subscriptions == [] do
      subscribe_to_signals(nil)
    else
      Enum.each(subscriptions, fn pattern ->
        InterviewBus.subscribe(pattern)
      end)
    end
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

  # Track interviewer questions for context in temporal analysis
  @impl true
  def handle_info({:signal, %{type: "interview.utterance.host"} = signal}, state) do
    question = signal.data[:content] || ""
    Logger.debug("[SentimentAgent] Tracking last question for context: #{String.slice(question, 0, 50)}...")
    {:noreply, %{state | last_question: question}}
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
    # Start async LLM call with timeout - pass question context for semantic understanding
    last_question = state.last_question || "Tell me about yourself"
    task = Task.async(fn -> call_sentiment_llm(message, last_question, state.llm_config) end)

    case Task.yield(task, @llm_timeout_ms) do
      {:ok, {:ok, result}} ->
        Logger.debug("[SentimentAgent] LLM analysis: #{inspect(result)}")
        result

      {:ok, {:error, reason}} ->
        Logger.warning("[SentimentAgent] LLM failed: #{inspect(reason)}, using fallback")
        # PHASE 4: Pass heuristics for config-driven fallback
        fallback_sentiment_analysis(message, state.heuristics || %{})

      nil ->
        Task.shutdown(task, :brutal_kill)
        Logger.warning("[SentimentAgent] LLM timeout, using fallback")
        # PHASE 4: Pass heuristics for config-driven fallback
        fallback_sentiment_analysis(message, state.heuristics || %{})
    end
  end

  # Call LLM for semantic sentiment analysis
  defp call_sentiment_llm(message, question, config) do
    system_prompt = PromptLoader.load!("interview", "sentiment_agent", "system",
      default_sentiment_system_prompt())

    variables = %{message: message, question: question}
    user_prompt = PromptLoader.load_with_vars!("interview", "sentiment_agent", "analyze", variables,
      default_sentiment_analyze_prompt(message, question))

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

  # Fallback system prompt
  defp default_sentiment_system_prompt do
    """
    You are a sentiment analyzer for interview conversations.
    Respond ONLY with valid JSON: {"frustration_level": "none", "user_intent": "continue", "chronological_direction": "neutral"}
    """
  end

  # Fallback analyze prompt
  defp default_sentiment_analyze_prompt(message, question) do
    """
    Analyze this interview exchange for sentiment, intent, and temporal direction.

    INTERVIEWER ASKED: "#{question}"
    USER RESPONDED: "#{message}"

    For chronological_direction, consider: Did the user stay at the life stage the question asked about, move forward in their story (e.g., origin/background question but they pivoted to college/career), or move backward (e.g., career question but they went back to early influences)?

    Respond with ONLY JSON: {"frustration_level": "none|mild|moderate|high", "user_intent": "continue|change_topic|end_interview", "chronological_direction": "forward|backward|neutral"}
    """
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

  # PHASE 4: Fallback heuristic analysis using config-driven phrases
  defp fallback_sentiment_analysis(message, heuristics) do
    downcased = String.downcase(message)
    word_count = message |> String.split() |> length()

    # Get config-driven phrases or use defaults
    intent_config = heuristics[:intent_detection] || default_intent_detection()
    frustration_config = heuristics[:frustration_phrases] || default_frustration_phrases()
    chrono_config = heuristics[:chronological_keywords] || default_chronological_keywords()
    thresholds = heuristics[:thresholds] || %{}
    short_answer_words = thresholds[:short_answer_words] || 5

    # Detect user intent from config phrases
    user_intent = detect_user_intent(downcased, intent_config)

    # Detect frustration from config phrases
    frustration_level = detect_frustration(downcased, frustration_config)

    # Detect chronological direction from config
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


  # PHASE 4: Helper functions for config-driven detection

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

  # Default configs for fallback
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
