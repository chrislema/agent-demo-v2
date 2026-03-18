defmodule InterviewStudio.Agents.ProbeCoach do
  @moduledoc """
  The Probe Coach Agent - identifies opportunities to go deeper.

  Phase 4: Domain-Agnostic Architecture
  - Loads heuristics from domain config (heuristics/probe_coach.yaml)
  - Probe indicators come from config
  - Thresholds come from config

  Looks for:
  - Emotional language worth exploring
  - Vague statements that need specifics
  - Unexplored tangents with potential
  - Contradictions or tensions

  LLM-powered for nuanced detection.

  Implemented as a Jido.Agent with signal_routes and Actions.
  """

  use Jido.Agent,
    name: "probe_coach",
    description: "Identifies opportunities for deeper interview probing",
    schema: [
      session_id: [type: :any, default: nil],
      pending_probes: [type: :any, default: []],
      used_probes: [type: :any, default: []],
      last_user_message: [type: :any, default: nil],
      received_themes: [type: :any, default: []],
      engagement_level: [type: :atom, default: :high],
      frustration_level: [type: :atom, default: :none],
      llm_config: [type: :any, default: %{}],
      domain: [type: :any, default: nil],
      heuristics: [type: :any, default: %{}]
    ],
    signal_routes: [
      {"interview.utterance.user", InterviewStudio.Agents.ProbeCoach.Actions.HandleUserUtterance},
      {"analyst.theme.discovered", InterviewStudio.Agents.ProbeCoach.Actions.HandleThemeDiscovered},
      {"observer.status.engagement", InterviewStudio.Agents.ProbeCoach.Actions.HandleEngagement},
      {"observer.status.frustration", InterviewStudio.Agents.ProbeCoach.Actions.HandleFrustration},
      {"probe_coach.internal.add_probes", InterviewStudio.Agents.ProbeCoach.Actions.AddProbes},
      {"probe_coach.cmd.analyze_now", InterviewStudio.Agents.ProbeCoach.Actions.AnalyzeNow}
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
      DomainLoader.get_heuristics(domain, :probe_coach)
    else
      %{}
    end

    {:ok, pid} = Jido.AgentServer.start_link(
      agent: __MODULE__,
      name: via_tuple(session_id),
      id: "probe_coach_#{session_id}",
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
    InterviewBus.subscribe_pid("analyst.theme.discovered", pid)
    InterviewBus.subscribe_pid("observer.status.engagement", pid)
    InterviewBus.subscribe_pid("observer.status.frustration", pid)

    Logger.info("[ProbeCoach] Started for session #{session_id} (domain: #{domain && domain.name || "default"})")
    {:ok, pid}
  end

  def get_state(session_id) do
    get_agent_state(session_id)
  end

  def get_pending_probes(session_id) do
    state = get_agent_state(session_id)
    state.pending_probes
  end

  @doc """
  Request immediate synchronous analysis.
  Used by Session.gather_insights/2.
  Returns {:ok, probes} or {:error, reason}
  """
  def analyze_now(session_id) do
    signal = %Jido.Signal{
      type: "probe_coach.cmd.analyze_now",
      source: "session",
      id: Jido.Util.generate_id(),
      data: %{},
      time: DateTime.utc_now()
    }

    case GenServer.call(via_tuple(session_id), {:signal, signal}, 10_000) do
      {:ok, agent} -> {:ok, agent.state.pending_probes}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Vote on readiness for a phase transition.
  Returns {:ready | :not_ready | :abstain, rationale}
  """
  def vote_transition(session_id, target_phase) do
    state = get_agent_state(session_id)
    evaluate_transition_readiness(target_phase, state)
  end

  # Private helpers

  defp get_agent_state(session_id) do
    {:ok, server_state} = Jido.AgentServer.state(via_tuple(session_id))
    server_state.agent.state
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
  defp evaluate_transition_readiness(target_phase, state) do
    pending_count = length(state.pending_probes || [])
    used_count = length(state.used_probes || [])
    high_priority_probes = Enum.filter(state.pending_probes || [], fn p -> p.priority in [:high, :urgent] end)

    case target_phase do
      :synthesis ->
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

# =============================================================================
# Action: HandleUserUtterance
# =============================================================================

defmodule InterviewStudio.Agents.ProbeCoach.Actions.HandleUserUtterance do
  @moduledoc "Analyzes user utterances for probe opportunities."

  use Jido.Action,
    name: "probe_coach_handle_user_utterance",
    description: "Analyze user response for probe opportunities",
    schema: [
      content: [type: :any],
      timestamp: [type: :any]
    ]

  require Logger

  alias InterviewStudio.InterviewBus
  alias InterviewStudio.PromptLoader

  @impl true
  def run(params, context) do
    state = context.state
    content = params[:content] || ""
    heuristics = state.heuristics || %{}

    new_state = %{last_user_message: content}

    # Check if this response is worth probing
    if worth_analyzing?(content, heuristics) do
      agent_server_pid = self()
      analyze_async(content, state, agent_server_pid)
    end

    {:ok, new_state}
  end

  defp worth_analyzing?(content, heuristics) do
    word_count = String.split(content) |> length()
    thresholds = heuristics[:thresholds] || %{}

    min_words = thresholds[:min_words_for_analysis] || 5
    auto_analyze = thresholds[:auto_analyze_word_count] || 15

    word_count > min_words and (
      has_probe_indicators?(content, heuristics) or
      word_count > auto_analyze
    )
  end

  defp has_probe_indicators?(text, heuristics) do
    config_indicators = heuristics[:probe_indicators] || %{}

    all_indicators = if map_size(config_indicators) > 0 do
      Enum.flat_map(config_indicators, fn {_category, phrases} -> phrases end)
    else
      default_probe_indicators()
    end

    downcased = String.downcase(text)
    Enum.any?(all_indicators, fn ind -> String.contains?(downcased, ind) end)
  end

  defp default_probe_indicators do
    [
      "kind of", "sort of", "i guess", "maybe", "something like",
      "felt", "feeling", "hard", "difficult", "exciting", "scary",
      "...", "but", "although", "however",
      "i realized", "i learned", "changed",
      "one time", "there was", "i remember"
    ]
  end

  defp analyze_async(content, state, agent_server_pid) do
    emit_analyzing_signal()

    Task.start(fn ->
      case generate_probes(content, state) do
        {:ok, probes} when probes != [] ->
          emit_probes(probes)

          update_signal = %Jido.Signal{
            type: "probe_coach.internal.add_probes",
            source: "probe_coach",
            id: Jido.Util.generate_id(),
            data: %{probes: probes},
            time: DateTime.utc_now()
          }
          GenServer.cast(agent_server_pid, {:signal, update_signal})

        {:ok, []} ->
          emit_no_probes_signal()

        {:error, reason} ->
          Logger.warning("[ProbeCoach] Analysis failed: #{inspect(reason)}")
          emit_error_signal(reason)
      end
    end)
  end

  defp emit_analyzing_signal do
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

  defp emit_no_probes_signal do
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

  defp emit_error_signal(reason) do
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

  def generate_probes(content, state) do
    variables = %{content: content}

    prompt = PromptLoader.load_with_vars!("interview", "probe_coach", "generate_probes", variables,
      default_generate_probes_prompt(content))

    case call_llm(prompt, state.llm_config || %{}) do
      {:ok, response} -> parse_probes(response)
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_generate_probes_prompt(content) do
    """
    Analyze this interview response and suggest follow-up probes.

    User said: "#{content}"

    Look for emotional language, vague statements, interesting tangents, or contradictions.

    Respond in JSON: {"probes": [{"topic": "topic", "rationale": "why", "question": "follow-up", "priority": "high|medium|low"}]}

    Only suggest 1-2 probes maximum.
    """
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

  defp emit_probes(probes) do
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
  end

  defp call_llm(prompt, config) do
    try do
      model_name = config[:model] || "meta-llama/llama-4-scout-17b-16e-instruct"

      case Jido.Exec.run(Jido.AI.Actions.LLM.Chat, %{
        model: "groq:#{model_name}",
        prompt: prompt,
        temperature: config[:temperature] || 0.4,
        max_tokens: config[:max_tokens] || 400
      }) do
        {:ok, %{text: content}} -> {:ok, content}
        {:ok, result} when is_map(result) -> {:ok, Map.get(result, :text, inspect(result))}
        {:error, reason} -> {:error, reason}
      end
    rescue
      e ->
        Logger.error("[ProbeCoach] LLM call failed: #{inspect(e)}")
        {:error, "LLM call failed"}
    end
  end
end

# =============================================================================
# Action: HandleThemeDiscovered
# =============================================================================

defmodule InterviewStudio.Agents.ProbeCoach.Actions.HandleThemeDiscovered do
  @moduledoc "Handles theme notifications from Story Analyst."

  use Jido.Action,
    name: "probe_coach_handle_theme",
    description: "Process theme from Story Analyst and maybe generate probe",
    schema: [
      theme: [type: :any],
      evidence: [type: :any],
      confidence: [type: :any],
      target: [type: :any],
      suggestion: [type: :any],
      timestamp: [type: :any]
    ]

  require Logger

  alias InterviewStudio.InterviewBus
  alias InterviewStudio.PromptLoader

  @impl true
  def run(params, context) do
    state = context.state
    theme = params[:theme]
    evidence = params[:evidence] || ""
    confidence = params[:confidence] || 0.7

    if theme do
      Logger.debug("[ProbeCoach] <- [StoryAnalyst] Received theme: #{theme}")

      theme_entry = %{theme: theme, evidence: evidence, confidence: confidence}
      updated_themes = [theme_entry | (state.received_themes || [])] |> Enum.take(10)

      # Generate a theme-aware probe if engagement is good and user isn't frustrated
      if state.engagement_level in [:high, :medium] and state.frustration_level in [:none, :mild] do
        agent_server_pid = self()
        generate_theme_probe_async(theme_entry, state, agent_server_pid)
      else
        Logger.debug("[ProbeCoach] Skipping theme probe - engagement: #{state.engagement_level}, frustration: #{state.frustration_level}")
      end

      {:ok, %{received_themes: updated_themes}}
    else
      {:ok, %{}}
    end
  end

  defp generate_theme_probe_async(theme_entry, state, agent_server_pid) do
    Task.start(fn ->
      case generate_theme_probe(theme_entry, state) do
        {:ok, probe} when probe != nil ->
          # Emit probe signal
          probe_signal = %Jido.Signal{
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
          InterviewBus.publish(probe_signal)
          Logger.debug("[ProbeCoach] Generated theme-aware probe for: #{theme_entry.theme}")

          update_signal = %Jido.Signal{
            type: "probe_coach.internal.add_probes",
            source: "probe_coach",
            id: Jido.Util.generate_id(),
            data: %{probes: [probe]},
            time: DateTime.utc_now()
          }
          GenServer.cast(agent_server_pid, {:signal, update_signal})
        _ ->
          :ok
      end
    end)
  end

  defp generate_theme_probe(theme_entry, state) do
    variables = %{
      theme: theme_entry.theme,
      evidence: theme_entry.evidence
    }

    prompt = PromptLoader.load_with_vars!("interview", "probe_coach", "theme_probe", variables,
      default_theme_probe_prompt(theme_entry))

    case call_llm(prompt, state.llm_config || %{}) do
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

  defp default_theme_probe_prompt(theme_entry) do
    """
    A theme has been identified: "#{theme_entry.theme}"
    Evidence: #{theme_entry.evidence}

    Generate ONE follow-up question exploring this theme.
    Respond in JSON: {"topic": "theme exploration", "rationale": "why", "question": "the question", "priority": "medium"}
    """
  end

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

  defp call_llm(prompt, config) do
    try do
      model_name = config[:model] || "meta-llama/llama-4-scout-17b-16e-instruct"

      case Jido.Exec.run(Jido.AI.Actions.LLM.Chat, %{
        model: "groq:#{model_name}",
        prompt: prompt,
        temperature: config[:temperature] || 0.4,
        max_tokens: config[:max_tokens] || 400
      }) do
        {:ok, %{text: content}} -> {:ok, content}
        {:ok, result} when is_map(result) -> {:ok, Map.get(result, :text, inspect(result))}
        {:error, reason} -> {:error, reason}
      end
    rescue
      e ->
        Logger.error("[ProbeCoach] LLM call failed: #{inspect(e)}")
        {:error, "LLM call failed"}
    end
  end
end

# =============================================================================
# Action: HandleEngagement
# =============================================================================

defmodule InterviewStudio.Agents.ProbeCoach.Actions.HandleEngagement do
  @moduledoc "Updates engagement level; clears low-priority probes on critical."

  use Jido.Action,
    name: "probe_coach_handle_engagement",
    description: "Update engagement level and filter probes",
    schema: [
      level: [type: :any]
    ]

  require Logger

  @impl true
  def run(params, context) do
    state = context.state
    level = params[:level] || state.engagement_level
    Logger.debug("[ProbeCoach] <- [EngagementMonitor] Engagement: #{level}")

    new_probes = if level == :critical do
      Logger.debug("[ProbeCoach] Critical engagement - clearing non-urgent probes")
      Enum.filter(state.pending_probes || [], fn p -> p.priority in [:high, :urgent] end)
    else
      state.pending_probes || []
    end

    {:ok, %{engagement_level: level, pending_probes: new_probes}}
  end
end

# =============================================================================
# Action: HandleFrustration
# =============================================================================

defmodule InterviewStudio.Agents.ProbeCoach.Actions.HandleFrustration do
  @moduledoc "Updates frustration level; clears non-urgent probes when frustrated."

  use Jido.Action,
    name: "probe_coach_handle_frustration",
    description: "Handle frustration signal and filter probes",
    schema: [
      level: [type: :any]
    ]

  require Logger

  @impl true
  def run(params, context) do
    state = context.state
    level = params[:level] || :none
    Logger.debug("[ProbeCoach] <- [SentimentAgent] Frustration: #{level}")

    new_probes = if level in [:moderate, :high] do
      Logger.info("[ProbeCoach] Frustration detected (#{level}) - clearing non-urgent probes")
      Enum.filter(state.pending_probes || [], fn p -> p.priority in [:high, :urgent] end)
    else
      state.pending_probes || []
    end

    {:ok, %{frustration_level: level, pending_probes: new_probes}}
  end
end

# =============================================================================
# Action: AddProbes
# =============================================================================

defmodule InterviewStudio.Agents.ProbeCoach.Actions.AddProbes do
  @moduledoc "Merges new probes from async analysis into state."

  use Jido.Action,
    name: "probe_coach_add_probes",
    description: "Add probes from async analysis to pending list",
    schema: [
      probes: [type: :any]
    ]

  @impl true
  def run(params, context) do
    state = context.state
    new_probes = params[:probes] || []

    updated = (new_probes ++ (state.pending_probes || []))
    |> Enum.sort_by(fn p ->
      case p.priority do
        :high -> 0
        :medium -> 1
        :low -> 2
        _ -> 3
      end
    end)
    |> Enum.take(5)

    {:ok, %{pending_probes: updated}}
  end
end

# =============================================================================
# Action: AnalyzeNow
# =============================================================================

defmodule InterviewStudio.Agents.ProbeCoach.Actions.AnalyzeNow do
  @moduledoc "Synchronous probe analysis for Session.gather_insights."

  use Jido.Action,
    name: "probe_coach_analyze_now",
    description: "Run synchronous probe analysis",
    schema: []

  require Logger

  alias InterviewStudio.Agents.ProbeCoach.Actions.HandleUserUtterance

  @impl true
  def run(_params, context) do
    state = context.state
    Logger.debug("[ProbeCoach] Synchronous analysis requested")

    heuristics = state.heuristics || %{}
    last_msg = state.last_user_message

    if last_msg == nil or not worth_analyzing?(last_msg, heuristics) do
      {:ok, %{}}
    else
      case HandleUserUtterance.generate_probes(last_msg, state) do
        {:ok, new_probes} when new_probes != [] ->
          updated_probes = (new_probes ++ (state.pending_probes || []))
            |> Enum.sort_by(fn p ->
              case p.priority do
                :high -> 0
                :medium -> 1
                :low -> 2
                _ -> 3
              end
            end)
            |> Enum.take(5)

          {:ok, %{pending_probes: updated_probes}}

        {:ok, []} ->
          {:ok, %{}}

        {:error, reason} ->
          Logger.warning("[ProbeCoach] Sync analysis failed: #{inspect(reason)}")
          {:ok, %{}}
      end
    end
  end

  defp worth_analyzing?(content, heuristics) do
    word_count = String.split(content) |> length()
    thresholds = heuristics[:thresholds] || %{}
    min_words = thresholds[:min_words_for_analysis] || 5
    word_count > min_words
  end
end
