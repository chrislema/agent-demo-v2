defmodule InterviewStudio.Agents.ProbeCoach do
  @moduledoc """
  The Probe Coach Agent - identifies opportunities to go deeper.

  Looks for:
  - Emotional language worth exploring
  - Vague statements that need specifics
  - Unexplored tangents with potential
  - Contradictions or tensions

  LLM-powered for nuanced detection.
  """

  use GenServer
  require Logger

  alias InterviewStudio.InterviewBus

  defstruct [
    :session_id,
    :pending_probes,
    :used_probes,
    :last_user_message,
    :received_themes,      # Themes received from Story Analyst
    :engagement_level,     # Current engagement from Engagement Monitor
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

  def get_pending_probes(session_id) do
    GenServer.call(via_tuple(session_id), :get_pending_probes)
  end

  @doc """
  Request immediate synchronous analysis.
  Used by Session.gather_insights/2 for parallel analysis with synchronization barrier.
  Returns {:ok, probes} or {:error, reason}
  """
  def analyze_now(session_id) do
    GenServer.call(via_tuple(session_id), :analyze_now, 10_000)
  end

  @doc """
  Vote on readiness for a phase transition.
  Used by Director.poll_transition_readiness/2 for consensus-based phase transitions.
  Returns {:ready | :not_ready | :abstain, rationale}
  """
  def vote_transition(session_id, target_phase) do
    GenServer.call(via_tuple(session_id), {:vote_transition, target_phase}, 5_000)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    llm_config = Keyword.get(opts, :llm_config, default_llm_config())

    state = %__MODULE__{
      session_id: session_id,
      pending_probes: [],
      used_probes: [],
      last_user_message: nil,
      received_themes: [],
      engagement_level: :high,
      llm_config: llm_config
    }

    subscribe_to_signals()

    Logger.info("[ProbeCoach] Started for session #{session_id}")
    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call(:get_pending_probes, _from, state) do
    {:reply, state.pending_probes, state}
  end

  @impl true
  def handle_call({:vote_transition, target_phase}, _from, state) do
    # CONSENSUS MECHANISM: Vote on phase transition readiness
    # Probe Coach considers whether pending probes have been addressed
    vote = evaluate_transition_readiness(target_phase, state)
    Logger.debug("[ProbeCoach] Voting on transition to #{target_phase}: #{elem(vote, 0)}")
    {:reply, vote, state}
  end

  @impl true
  def handle_call(:analyze_now, _from, state) do
    # Synchronous analysis for parallel gathering
    # Used by Session.gather_insights/2 synchronization barrier
    Logger.debug("[ProbeCoach] Synchronous analysis requested")

    if state.last_user_message == nil or not worth_analyzing?(state.last_user_message) do
      # No message or not worth analyzing - return existing probes
      {:reply, {:ok, state.pending_probes}, state}
    else
      case generate_probes(state.last_user_message, state) do
        {:ok, new_probes} when new_probes != [] ->
          # Update state with new probes
          updated_probes = (new_probes ++ state.pending_probes)
            |> Enum.sort_by(fn p ->
              case p.priority do
                :high -> 0
                :medium -> 1
                :low -> 2
              end
            end)
            |> Enum.take(5)

          new_state = %{state | pending_probes: updated_probes}

          # Also emit signals for UI visibility
          emit_probes(new_probes, state)

          {:reply, {:ok, updated_probes}, new_state}

        {:ok, []} ->
          # No new probes found
          {:reply, {:ok, state.pending_probes}, state}

        {:error, reason} ->
          Logger.warning("[ProbeCoach] Sync analysis failed: #{inspect(reason)}")
          # Return existing probes on failure
          {:reply, {:ok, state.pending_probes}, state}
      end
    end
  end

  @impl true
  def handle_info({:signal, signal}, state) do
    new_state = handle_signal(signal, state)
    {:noreply, new_state}
  end

  # Signal handlers

  defp handle_signal(%{type: "interview.utterance.user"} = signal, state) do
    content = signal.data.content

    new_state = %{state | last_user_message: content}

    # Check if this response is worth probing
    if worth_analyzing?(content) do
      analyze_async(content, new_state)
    end

    new_state
  end

  # AGENT-TO-AGENT: Receive theme notifications from Story Analyst
  defp handle_signal(%{type: "analyst.theme.discovered"} = signal, state) do
    theme = signal.data.theme
    evidence = signal.data[:evidence] || ""
    confidence = signal.data[:confidence] || 0.7

    Logger.debug("[ProbeCoach] <- [StoryAnalyst] Received theme: #{theme}")

    # Store the theme
    theme_entry = %{theme: theme, evidence: evidence, confidence: confidence}
    updated_themes = [theme_entry | state.received_themes] |> Enum.take(10)
    new_state = %{state | received_themes: updated_themes}

    # Generate a theme-aware probe if engagement is good
    if state.engagement_level in [:high, :medium] do
      generate_theme_probe_async(theme_entry, new_state)
    end

    new_state
  end

  # AGENT-TO-AGENT: Receive engagement updates from Engagement Monitor
  defp handle_signal(%{type: "observer.status.engagement"} = signal, state) do
    level = signal.data.level
    Logger.debug("[ProbeCoach] <- [EngagementMonitor] Engagement: #{level}")

    # If engagement is critical, clear low-priority probes
    new_probes = if level == :critical do
      Logger.debug("[ProbeCoach] Critical engagement - clearing non-urgent probes")
      Enum.filter(state.pending_probes, fn p -> p.priority in [:high, :urgent] end)
    else
      state.pending_probes
    end

    %{state | engagement_level: level, pending_probes: new_probes}
  end

  defp handle_signal(_signal, state), do: state

  # Generate a probe specifically about a discovered theme
  defp generate_theme_probe_async(theme_entry, state) do
    Task.start(fn ->
      case generate_theme_probe(theme_entry, state) do
        {:ok, probe} when probe != nil ->
          emit_probes([probe], state)
          Logger.debug("[ProbeCoach] Generated theme-aware probe for: #{theme_entry.theme}")
        _ ->
          :ok
      end
    end)
  end

  defp generate_theme_probe(theme_entry, state) do
    prompt = """
    A theme has been identified in an interview: "#{theme_entry.theme}"
    Evidence: #{theme_entry.evidence}

    Generate ONE follow-up question that explores this theme more deeply.
    The question should:
    1. Connect to the theme naturally
    2. Invite the person to share more about how this theme shows up in their life
    3. Be specific, not generic

    Respond in JSON:
    {
      "topic": "theme exploration: #{theme_entry.theme}",
      "rationale": "why this theme deserves deeper exploration",
      "question": "the follow-up question",
      "priority": "medium"
    }
    """

    case call_llm(prompt, state.llm_config) do
      {:ok, response} ->
        case extract_json(response) do
          {:ok, parsed} ->
            probe = %{
              topic: parsed["topic"] || "theme: #{theme_entry.theme}",
              rationale: "Theme-aware probe from Story Analyst: #{parsed["rationale"] || theme_entry.theme}",
              suggested_question: parsed["question"],
              priority: :medium,
              source: :story_analyst_theme
            }
            {:ok, probe}
          _ -> {:ok, nil}
        end
      {:error, _} -> {:ok, nil}
    end
  end

  # Quick heuristic check before calling LLM

  defp worth_analyzing?(content) do
    word_count = String.split(content) |> length()

    # Analyze if response has any substance
    word_count > 5 and (
      # Has emotional content or probe indicators
      has_probe_indicators?(content) or
      # Is long enough to contain depth
      word_count > 15
    )
  end

  defp has_probe_indicators?(text) do
    indicators = [
      # Vagueness
      "kind of", "sort of", "i guess", "maybe", "something like",
      # Emotional hints
      "felt", "feeling", "hard", "difficult", "exciting", "scary",
      # Incomplete thoughts
      "...", "but", "although", "however",
      # Self-reflection
      "i realized", "i learned", "changed",
      # Story cues
      "one time", "there was", "i remember"
    ]

    downcased = String.downcase(text)
    Enum.any?(indicators, fn ind -> String.contains?(downcased, ind) end)
  end

  # Analysis

  defp analyze_async(content, state) do
    # Emit signal that we're starting analysis (so debug panel shows activity)
    emit_analyzing_signal(state)

    Task.start(fn ->
      case generate_probes(content, state) do
        {:ok, probes} when probes != [] ->
          emit_probes(probes, state)
        {:ok, []} ->
          emit_no_probes_signal(state)
        {:error, reason} ->
          Logger.warning("[ProbeCoach] Analysis failed: #{inspect(reason)}")
          emit_error_signal(reason, state)
      end
    end)
  end

  defp emit_analyzing_signal(_state) do
    signal = %Jido.Signal{
      type: "observer.status.analyzing",
      source: "probe_coach",
      id: Jido.Util.generate_id(),
      data: %{
        status: :analyzing,
        message: "Looking for probe opportunities",
        timestamp: DateTime.utc_now()
      }
    }
    InterviewBus.publish(signal)
    Logger.debug("[ProbeCoach] Starting probe analysis")
  end

  defp emit_no_probes_signal(_state) do
    signal = %Jido.Signal{
      type: "observer.status.complete",
      source: "probe_coach",
      id: Jido.Util.generate_id(),
      data: %{
        status: :complete,
        message: "No probe opportunities found",
        timestamp: DateTime.utc_now()
      }
    }
    InterviewBus.publish(signal)
  end

  defp emit_error_signal(reason, _state) do
    signal = %Jido.Signal{
      type: "observer.status.error",
      source: "probe_coach",
      id: Jido.Util.generate_id(),
      data: %{
        status: :error,
        reason: inspect(reason),
        timestamp: DateTime.utc_now()
      }
    }
    InterviewBus.publish(signal)
  end

  defp generate_probes(content, state) do
    prompt = """
    Analyze this interview response and suggest follow-up probes.

    User said: "#{content}"

    Look for:
    1. Emotional language that deserves exploration
    2. Vague statements needing specifics
    3. Interesting tangents worth pursuing
    4. Contradictions or tensions

    Respond in this exact JSON format:
    {
      "probes": [
        {
          "topic": "what the probe is about",
          "rationale": "why this is worth exploring",
          "question": "the suggested follow-up question",
          "priority": "high|medium|low"
        }
      ]
    }

    Only suggest 1-2 probes maximum. Only suggest if there's genuine depth to explore.
    Return empty probes array if nothing stands out.
    """

    case call_llm(prompt, state.llm_config) do
      {:ok, response} -> parse_probes(response)
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_probes(response) do
    case extract_json(response) do
      {:ok, parsed} ->
        probes = Map.get(parsed, "probes", [])
        |> Enum.map(fn p ->
          %{
            topic: p["topic"],
            rationale: p["rationale"],
            suggested_question: p["question"],
            priority: parse_priority(p["priority"])
          }
        end)
        |> Enum.filter(fn p -> p.topic != nil and p.suggested_question != nil end)

        {:ok, probes}

      {:error, _} ->
        Logger.warning("[ProbeCoach] Failed to parse LLM response")
        {:ok, []}
    end
  end

  defp parse_priority("high"), do: :high
  defp parse_priority("medium"), do: :medium
  defp parse_priority("low"), do: :low
  defp parse_priority(_), do: :medium

  defp extract_json(text) do
    case Regex.run(~r/\{[\s\S]*\}/, text) do
      [json_str] ->
        case Jason.decode(json_str) do
          {:ok, parsed} -> {:ok, parsed}
          {:error, _} -> {:error, :invalid_json}
        end
      nil ->
        {:error, :no_json_found}
    end
  end

  defp emit_probes(probes, state) do
    Enum.each(probes, fn probe ->
      signal = %Jido.Signal{
        type: "observer.suggestion.probe",
        source: "probe_coach",
        id: Jido.Util.generate_id(),
        data: %{
          topic: probe.topic,
          rationale: probe.rationale,
          suggested_question: probe.suggested_question,
          priority: probe.priority,
          timestamp: DateTime.utc_now()
        }
      }
      InterviewBus.publish(signal)
      Logger.debug("[ProbeCoach] Suggested probe: #{probe.topic} (#{probe.priority})")
    end)

    # Emit completion signal
    completion_signal = %Jido.Signal{
      type: "observer.status.complete",
      source: "probe_coach",
      id: Jido.Util.generate_id(),
      data: %{
        status: :complete,
        probes_found: length(probes),
        message: "Found #{length(probes)} probe opportunities",
        timestamp: DateTime.utc_now()
      }
    }
    InterviewBus.publish(completion_signal)

    # Update state via message
    GenServer.cast(via_tuple(state.session_id), {:add_probes, probes})
  end

  @impl true
  def handle_cast({:add_probes, new_probes}, state) do
    # Add new probes, sorted by priority
    updated = (new_probes ++ state.pending_probes)
    |> Enum.sort_by(fn p ->
      case p.priority do
        :high -> 0
        :medium -> 1
        :low -> 2
      end
    end)
    |> Enum.take(5)

    {:noreply, %{state | pending_probes: updated}}
  end

  # LLM call

  defp call_llm(prompt, config) do
    try do
      api_key = System.get_env("AgentDemo_Groq_API_Key") || ""

      model = %Jido.AI.Model{
        provider: :openrouter,
        base_url: "https://api.groq.com/openai/v1/chat/completions",
        model: config[:model] || "meta-llama/llama-4-scout-17b-16e-instruct",
        api_key: api_key,
        temperature: config[:temperature] || 0.4,
        max_tokens: config[:max_tokens] || 400
      }

      jido_prompt = Jido.AI.Prompt.new(%{
        messages: [
          %{role: :user, content: prompt}
        ]
      })

      case Jido.AI.Actions.Langchain.run(%{model: model, prompt: jido_prompt}, %{}) do
        {:ok, %{content: content}} -> {:ok, content}
        {:ok, result} when is_map(result) -> {:ok, Map.get(result, :content, inspect(result))}
        {:error, reason} -> {:error, reason}
      end
    rescue
      e ->
        Logger.error("[ProbeCoach] LLM call failed: #{inspect(e)}")
        {:error, "LLM call failed"}
    end
  end

  defp subscribe_to_signals do
    InterviewBus.subscribe("interview.utterance.user")
    # AGENT-TO-AGENT: Subscribe to direct messages from other agents
    InterviewBus.subscribe_direct("probe_coach")
    # Subscribe to theme discoveries from Story Analyst
    InterviewBus.subscribe("analyst.theme.discovered")
    # Subscribe to engagement updates from Engagement Monitor
    InterviewBus.subscribe("observer.status.engagement")
  end

  defp via_tuple(session_id) do
    {:via, Registry, {InterviewStudio.SessionRegistry, {:probe_coach, session_id}}}
  end

  defp default_llm_config do
    %{
      provider: :openrouter,
      model: "meta-llama/llama-4-scout-17b-16e-instruct",
      temperature: 0.4
    }
  end

  # CONSENSUS MECHANISM: Evaluate readiness for phase transition
  # Returns {:ready | :not_ready | :abstain, rationale}
  defp evaluate_transition_readiness(target_phase, state) do
    pending_count = length(state.pending_probes)
    used_count = length(state.used_probes)
    high_priority_probes = Enum.filter(state.pending_probes, fn p -> p.priority in [:high, :urgent] end)

    case target_phase do
      :synthesis ->
        # For synthesis, consider whether important probes have been explored
        cond do
          high_priority_probes != [] ->
            {:not_ready, "#{length(high_priority_probes)} high-priority probes still pending"}
          pending_count > 3 ->
            {:not_ready, "Many probes (#{pending_count}) still unexplored"}
          used_count >= 2 or pending_count == 0 ->
            {:ready, "Probing complete - #{used_count} probes explored"}
          pending_count <= 2 ->
            {:ready, "Only #{pending_count} low-priority probes remaining - okay to proceed"}
          true ->
            {:abstain, "Neutral on synthesis timing"}
        end

      :closing ->
        # For closing, if engagement is critical, defer to that signal
        if state.engagement_level == :critical do
          {:ready, "Engagement is critical - support closing"}
        else
          if high_priority_probes != [] do
            {:not_ready, "Would prefer to explore high-priority probes before closing"}
          else
            {:ready, "No critical probes remaining - ready to close"}
          end
        end

      :probing ->
        # We should have probes to explore before entering probing phase
        if pending_count > 0 do
          {:ready, "Have #{pending_count} probes ready to explore"}
        else
          {:not_ready, "No probes to explore - skip probing phase"}
        end

      :core_questions ->
        {:ready, "Ready to identify probe opportunities during core questions"}

      _ ->
        {:abstain, "No specific readiness criteria for #{target_phase}"}
    end
  end
end
