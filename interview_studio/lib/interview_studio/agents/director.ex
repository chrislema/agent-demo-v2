defmodule InterviewStudio.Agents.Director do
  @moduledoc """
  The Director Agent - the orchestrator and user-facing voice.

  Responsibilities:
  - Formulate natural, warm questions
  - Decide whether to follow script, probe deeper, or transition
  - Synthesize swarm input into conversational decisions
  - Maintain interview flow and pacing

  The Director subscribes to:
  - interview.utterance.user (user messages)
  - interview.phase.* (phase changes)
  - observer.insight.* (themes, patterns)
  - observer.suggestion.* (probes)
  - observer.status.* (engagement)
  """

  use GenServer
  require Logger

  alias InterviewStudio.InterviewBus
  alias InterviewStudio.Pipeline.Phases

  defstruct [
    :session_id,
    :current_phase,
    :questions_asked,
    :questions_remaining,
    :active_themes,
    :pending_probes,
    :engagement_level,
    :conversation_history,
    :last_user_message,
    :llm_config
  ]

  # Client API

  def start_link(opts \\ []) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(session_id))
  end

  def get_state(session_id) do
    GenServer.call(via_tuple(session_id), :get_state)
  end

  def process_user_message(session_id, message) do
    GenServer.call(via_tuple(session_id), {:user_message, message}, 30_000)
  end

  def get_next_action(session_id) do
    GenServer.call(via_tuple(session_id), :get_next_action, 30_000)
  end

  def generate_response(session_id, action_type, context) do
    GenServer.call(via_tuple(session_id), {:generate_response, action_type, context}, 60_000)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    llm_config = Keyword.get(opts, :llm_config, default_llm_config())

    state = %__MODULE__{
      session_id: session_id,
      current_phase: :preparation,
      questions_asked: [],
      questions_remaining: Phases.questions(:core_questions),
      active_themes: [],
      pending_probes: [],
      engagement_level: :high,
      conversation_history: [],
      last_user_message: nil,
      llm_config: llm_config
    }

    # Subscribe to relevant signals
    subscribe_to_signals()

    Logger.info("[Director] Started for session #{session_id}")
    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:user_message, message}, _from, state) do
    Logger.debug("[Director] Processing user message: #{String.slice(message, 0, 50)}...")

    # Record the message
    timestamp = DateTime.utc_now()

    new_history = [
      %{role: :user, content: message, timestamp: timestamp}
      | state.conversation_history
    ]

    # Publish user utterance signal
    publish_user_utterance(message, state.current_phase)

    new_state = %{state |
      conversation_history: new_history,
      last_user_message: message
    }

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:get_next_action, _from, state) do
    action = decide_next_action(state)
    {:reply, action, state}
  end

  @impl true
  def handle_call({:generate_response, action_type, context}, _from, state) do
    response = do_generate_response(action_type, context, state)
    {:reply, response, state}
  end

  @impl true
  def handle_info({:signal, signal}, state) do
    new_state = handle_signal(signal, state)
    {:noreply, new_state}
  end

  # Signal handlers

  defp handle_signal(%{type: "interview.phase.entered"} = signal, state) do
    phase = signal.data.phase_name
    Logger.debug("[Director] Phase entered: #{phase}")
    %{state | current_phase: phase}
  end

  defp handle_signal(%{type: "observer.insight.theme"} = signal, state) do
    theme = %{
      theme: signal.data.theme,
      evidence: signal.data.evidence,
      confidence: signal.data.confidence
    }
    Logger.debug("[Director] Theme received: #{theme.theme}")
    %{state | active_themes: [theme | state.active_themes] |> Enum.take(10)}
  end

  defp handle_signal(%{type: "observer.suggestion.probe"} = signal, state) do
    probe = %{
      topic: signal.data.topic,
      question: signal.data.suggested_question,
      rationale: signal.data.rationale,
      priority: signal.data.priority
    }
    Logger.debug("[Director] Probe suggested: #{probe.topic}")

    # Sort by priority
    probes = [probe | state.pending_probes]
    |> Enum.sort_by(fn p ->
      case p.priority do
        :high -> 0
        :medium -> 1
        :low -> 2
      end
    end)
    |> Enum.take(5)

    %{state | pending_probes: probes}
  end

  defp handle_signal(%{type: "observer.status.engagement"} = signal, state) do
    level = signal.data.level
    Logger.debug("[Director] Engagement status: #{level}")
    %{state | engagement_level: level}
  end

  defp handle_signal(_signal, state), do: state

  # Decision logic

  defp decide_next_action(state) do
    cond do
      # Critical engagement - wrap up
      state.engagement_level == :critical ->
        %{
          type: :transition,
          to_phase: :closing,
          reason: "Engagement dropped to critical level"
        }

      # In preparation - auto-advance to opening
      state.current_phase == :preparation ->
        %{
          type: :transition,
          to_phase: :opening,
          reason: "Preparation complete"
        }

      # In opening - greet the user
      state.current_phase == :opening ->
        question = get_opening_question()
        %{
          type: :ask,
          question: question,
          source: :question_bank
        }

      # In core questions - either probe or ask next question
      state.current_phase == :core_questions ->
        decide_core_questions_action(state)

      # In probing - ask probe questions
      state.current_phase == :probing ->
        decide_probing_action(state)

      # In synthesis - summarize themes
      state.current_phase == :synthesis ->
        %{
          type: :synthesize,
          themes: state.active_themes
        }

      # In closing - thank and wrap up
      state.current_phase == :closing ->
        %{
          type: :close,
          themes: state.active_themes
        }

      true ->
        %{type: :wait}
    end
  end

  defp decide_core_questions_action(state) do
    # Check if we have high-priority probes
    high_probe = Enum.find(state.pending_probes, fn p -> p.priority == :high end)

    cond do
      # High-priority probe - insert it
      high_probe != nil ->
        %{
          type: :probe,
          question: high_probe.question,
          topic: high_probe.topic
        }

      # More questions remaining
      state.questions_remaining != [] ->
        [next | _rest] = state.questions_remaining
        %{
          type: :ask,
          question: next.text,
          question_id: next.id,
          source: :question_bank
        }

      # All questions done - transition to probing or synthesis
      state.pending_probes != [] ->
        %{
          type: :transition,
          to_phase: :probing,
          reason: "Core questions complete, probes pending"
        }

      true ->
        %{
          type: :transition,
          to_phase: :synthesis,
          reason: "Core questions complete"
        }
    end
  end

  defp decide_probing_action(state) do
    cond do
      # More probes to ask
      state.pending_probes != [] ->
        [probe | _rest] = state.pending_probes
        %{
          type: :probe,
          question: probe.question,
          topic: probe.topic
        }

      # Done probing
      true ->
        %{
          type: :transition,
          to_phase: :synthesis,
          reason: "Probing complete"
        }
    end
  end

  defp get_opening_question do
    case Phases.questions(:opening) do
      [first | _] -> first.text
      [] -> "Hi! I'm excited to learn more about you and your story. Ready to dive in?"
    end
  end

  # Signal publishing

  defp publish_user_utterance(content, phase) do
    signal = %Jido.Signal{
      type: "interview.utterance.user",
      source: "director",
      id: Jido.Util.generate_id(),
      data: %{
        content: content,
        timestamp: DateTime.utc_now(),
        phase_context: phase
      }
    }
    InterviewBus.publish(signal)
  end

  defp subscribe_to_signals do
    InterviewBus.subscribe("interview.utterance.user")
    InterviewBus.subscribe("interview.phase.**")
    InterviewBus.subscribe("observer.insight.**")
    InterviewBus.subscribe("observer.suggestion.**")
    InterviewBus.subscribe("observer.status.**")
  end

  # LLM Response Generation

  defp do_generate_response(action_type, context, state) do
    system_prompt = build_system_prompt(state)
    user_prompt = build_user_prompt(action_type, context, state)

    case call_llm(system_prompt, user_prompt, state.llm_config) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_system_prompt(state) do
    themes_text = case state.active_themes do
      [] -> "No themes identified yet."
      themes ->
        themes
        |> Enum.map(fn t -> "- #{t.theme}" end)
        |> Enum.join("\n")
    end

    """
    You are a warm, skilled interviewer conducting a "Story of You" interview.
    Your goal is to discover what makes this person unique and amazing, to create a compelling article about them.

    Interview Style:
    - Be genuinely curious and engaged
    - Ask follow-up questions naturally
    - Acknowledge and validate what they share
    - Keep responses concise (2-3 sentences max)
    - Be conversational, not formal

    Current phase: #{state.current_phase}
    Questions asked: #{length(state.questions_asked)}
    Themes discovered:
    #{themes_text}

    Always respond in first person as the interviewer. Never break character.
    """
  end

  defp build_user_prompt(:ask, %{question: question}, state) do
    history = format_recent_history(state.conversation_history, 3)

    """
    Recent conversation:
    #{history}

    Ask this question naturally, adapting it to flow from the conversation:
    "#{question}"

    Respond with just the question, naturally phrased.
    """
  end

  defp build_user_prompt(:probe, %{question: question, topic: topic}, state) do
    history = format_recent_history(state.conversation_history, 3)

    """
    Recent conversation:
    #{history}

    The user said something interesting about: #{topic}
    Ask this follow-up question naturally:
    "#{question}"

    Respond with just the question, naturally phrased.
    """
  end

  defp build_user_prompt(:synthesize, %{themes: themes}, state) do
    history = format_recent_history(state.conversation_history, 5)
    theme_list = themes |> Enum.map(fn t -> t.theme end) |> Enum.join(", ")

    """
    Recent conversation:
    #{history}

    Key themes discovered: #{theme_list}

    Summarize what you've learned about this person in 2-3 sentences.
    Ask if this captures their story well, or if they'd add anything.
    """
  end

  defp build_user_prompt(:close, _context, state) do
    history = format_recent_history(state.conversation_history, 3)

    """
    Recent conversation:
    #{history}

    Thank them warmly for sharing their story.
    Let them know you have everything you need.
    Ask if there's anything else they'd like to add.
    Keep it brief and genuine.
    """
  end

  defp build_user_prompt(_action_type, _context, _state) do
    "Respond naturally to continue the conversation."
  end

  defp format_recent_history(history, count) do
    history
    |> Enum.take(count)
    |> Enum.reverse()
    |> Enum.map(fn msg ->
      role = if msg.role == :user, do: "User", else: "Interviewer"
      "#{role}: #{msg.content}"
    end)
    |> Enum.join("\n")
  end

  defp call_llm(system_prompt, user_prompt, config) do
    try do
      # Build Model struct with API key from environment (Groq)
      api_key = System.get_env("AgentDemo_Groq_API_Key") || ""

      model = %Jido.AI.Model{
        provider: config[:provider] || :groq,
        model: config[:model] || "meta-llama/llama-4-scout-17b-16e-instruct",
        api_key: api_key,
        temperature: config[:temperature] || 0.7,
        max_tokens: config[:max_tokens] || 1000
      }

      # Build Prompt with system and user messages
      prompt = Jido.AI.Prompt.new(%{
        messages: [
          %{role: :system, content: system_prompt},
          %{role: :user, content: user_prompt}
        ]
      })

      # Call Langchain action
      case Jido.AI.Actions.Langchain.run(%{model: model, prompt: prompt}, %{}) do
        {:ok, %{content: content}} -> {:ok, content}
        {:ok, result} when is_map(result) -> {:ok, Map.get(result, :content, inspect(result))}
        {:error, reason} -> {:error, reason}
      end
    rescue
      e ->
        Logger.error("[Director] LLM call failed: #{inspect(e)}")
        {:error, "LLM call failed"}
    end
  end

  defp via_tuple(session_id) do
    {:via, Registry, {InterviewStudio.SessionRegistry, {:director, session_id}}}
  end

  defp default_llm_config do
    %{
      provider: :groq,
      model: "meta-llama/llama-4-scout-17b-16e-instruct",
      temperature: 0.7
    }
  end
end
