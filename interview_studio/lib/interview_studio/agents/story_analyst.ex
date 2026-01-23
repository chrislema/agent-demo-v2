defmodule InterviewStudio.Agents.StoryAnalyst do
  @moduledoc """
  The Story Analyst Agent - extracts narrative themes and patterns.

  Looks for:
  - Recurring themes (resilience, creativity, community, etc.)
  - Story arcs (struggle → breakthrough, passion → profession)
  - Unique angles that differentiate this person
  - Quotable moments and key phrases

  LLM-powered for deep analysis.
  """

  use GenServer
  require Logger

  alias InterviewStudio.InterviewBus

  defstruct [
    :session_id,
    :themes,
    :patterns,
    :conversation_buffer,
    :analysis_count,
    :engagement_level,     # Current engagement from Engagement Monitor
    :llm_config
  ]

  @analysis_threshold 2  # Analyze every N user messages

  # Client API

  def start_link(opts \\ []) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(session_id))
  end

  def get_state(session_id) do
    GenServer.call(via_tuple(session_id), :get_state)
  end

  def get_themes(session_id) do
    GenServer.call(via_tuple(session_id), :get_themes)
  end

  @doc """
  Request immediate synchronous analysis.
  Used by Session.gather_insights/2 for parallel analysis with synchronization barrier.
  Returns {:ok, themes} or {:error, reason}
  """
  def analyze_now(session_id) do
    GenServer.call(via_tuple(session_id), :analyze_now, 10_000)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    llm_config = Keyword.get(opts, :llm_config, default_llm_config())

    state = %__MODULE__{
      session_id: session_id,
      themes: [],
      patterns: [],
      conversation_buffer: [],
      analysis_count: 0,
      engagement_level: :high,
      llm_config: llm_config
    }

    subscribe_to_signals()

    Logger.info("[StoryAnalyst] Started for session #{session_id}")
    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call(:get_themes, _from, state) do
    {:reply, state.themes, state}
  end

  @impl true
  def handle_call(:analyze_now, _from, state) do
    # Synchronous analysis for parallel gathering
    # Used by Session.gather_insights/2 synchronization barrier
    Logger.debug("[StoryAnalyst] Synchronous analysis requested")

    if Enum.empty?(state.conversation_buffer) do
      # No conversation yet - return existing themes
      {:reply, {:ok, state.themes}, state}
    else
      case analyze_themes(state) do
        {:ok, new_themes, new_patterns} ->
          # Update state with new insights
          updated_themes = (new_themes ++ state.themes)
            |> Enum.uniq_by(fn t -> t.theme end)
            |> Enum.take(10)
          updated_patterns = (new_patterns ++ state.patterns)
            |> Enum.uniq_by(fn p -> p.pattern end)
            |> Enum.take(5)

          new_state = %{state | themes: updated_themes, patterns: updated_patterns}

          # Also emit signals for UI visibility
          emit_insights(new_themes, new_patterns, state)

          {:reply, {:ok, updated_themes}, new_state}

        {:error, reason} ->
          Logger.warning("[StoryAnalyst] Sync analysis failed: #{inspect(reason)}")
          # Return existing themes on failure
          {:reply, {:ok, state.themes}, state}
      end
    end
  end

  @impl true
  def handle_info({:signal, signal}, state) do
    new_state = handle_signal(signal, state)
    {:noreply, new_state}
  end

  # Signal handlers

  defp handle_signal(%{type: "interview.utterance." <> _} = signal, state) do
    role = if String.ends_with?(signal.type, "user"), do: :user, else: :host
    content = signal.data.content

    entry = %{role: role, content: content, timestamp: DateTime.utc_now()}
    buffer = [entry | state.conversation_buffer] |> Enum.take(10)

    new_count = if role == :user, do: state.analysis_count + 1, else: state.analysis_count

    new_state = %{state | conversation_buffer: buffer, analysis_count: new_count}

    # Trigger analysis periodically, or on first substantive user message
    # BUT respect engagement level - don't do deep analysis when user is disengaged
    should_analyze = role == :user and
      state.engagement_level not in [:critical] and
      (rem(new_count, @analysis_threshold) == 0 or
       (new_count == 1 and String.length(content) > 50))

    if should_analyze do
      analyze_async(new_state)
    end

    new_state
  end

  # AGENT-TO-AGENT: Receive engagement alerts from Engagement Monitor
  defp handle_signal(%{type: "engagement.alert.broadcast"} = signal, state) do
    level = signal.data.level
    Logger.debug("[StoryAnalyst] <- [EngagementMonitor] Engagement alert: #{level}")

    new_state = %{state | engagement_level: level}

    # If engagement is critical, log that we're pausing deep analysis
    if level == :critical do
      Logger.info("[StoryAnalyst] Pausing deep analysis due to critical engagement")
    end

    new_state
  end

  # Also handle regular engagement status updates
  defp handle_signal(%{type: "observer.status.engagement"} = signal, state) do
    level = signal.data.level
    %{state | engagement_level: level}
  end

  defp handle_signal(_signal, state), do: state

  # Analysis

  defp analyze_async(state) do
    # Emit signal that we're starting analysis (so debug panel shows activity)
    emit_analyzing_signal(state)

    # Run analysis in background to not block
    Task.start(fn ->
      case analyze_themes(state) do
        {:ok, new_themes, new_patterns} ->
          emit_insights(new_themes, new_patterns, state)
        {:error, reason} ->
          Logger.warning("[StoryAnalyst] Analysis failed: #{inspect(reason)}")
          emit_error_signal(reason, state)
      end
    end)
  end

  defp emit_analyzing_signal(_state) do
    signal = %Jido.Signal{
      type: "observer.status.analyzing",
      source: "story_analyst",
      id: Jido.Util.generate_id(),
      data: %{
        status: :analyzing,
        message: "Analyzing conversation for themes and patterns",
        timestamp: DateTime.utc_now()
      }
    }
    InterviewBus.publish(signal)
    Logger.debug("[StoryAnalyst] Starting theme analysis")
  end

  defp emit_error_signal(reason, _state) do
    signal = %Jido.Signal{
      type: "observer.status.error",
      source: "story_analyst",
      id: Jido.Util.generate_id(),
      data: %{
        status: :error,
        reason: inspect(reason),
        timestamp: DateTime.utc_now()
      }
    }
    InterviewBus.publish(signal)
  end

  defp analyze_themes(state) do
    conversation = state.conversation_buffer
    |> Enum.reverse()
    |> Enum.map(fn e -> "#{e.role}: #{e.content}" end)
    |> Enum.join("\n")

    existing_themes = state.themes
    |> Enum.map(fn t -> t.theme end)
    |> Enum.join(", ")

    prompt = """
    Analyze this interview conversation for narrative themes and patterns.

    Conversation:
    #{conversation}

    Already identified themes: #{if existing_themes == "", do: "none yet", else: existing_themes}

    Identify:
    1. NEW themes (don't repeat existing ones) - core values, motivations, defining characteristics
    2. Story patterns - arcs like struggle→growth, passion→profession

    Respond in this exact format (JSON):
    {
      "themes": [
        {"theme": "theme name", "evidence": "quote or observation", "confidence": 0.8}
      ],
      "patterns": [
        {"pattern": "pattern description", "instances": ["example1", "example2"]}
      ]
    }

    Only include genuinely new insights. Return empty arrays if nothing new.
    """

    case call_llm(prompt, state.llm_config) do
      {:ok, response} -> parse_analysis(response)
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_analysis(response) do
    # Try to extract JSON from response
    case extract_json(response) do
      {:ok, parsed} ->
        themes = Map.get(parsed, "themes", [])
        |> Enum.map(fn t ->
          %{
            theme: t["theme"],
            evidence: t["evidence"],
            confidence: t["confidence"] || 0.7
          }
        end)

        patterns = Map.get(parsed, "patterns", [])
        |> Enum.map(fn p ->
          %{
            pattern: p["pattern"],
            instances: p["instances"] || []
          }
        end)

        {:ok, themes, patterns}

      {:error, _} ->
        Logger.warning("[StoryAnalyst] Failed to parse LLM response")
        {:ok, [], []}
    end
  end

  defp extract_json(text) do
    # Try to find JSON in the response
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

  defp emit_insights(themes, patterns, state) do
    # Emit theme signals (broadcast for UI/debug)
    Enum.each(themes, fn theme ->
      signal = %Jido.Signal{
        type: "observer.insight.theme",
        source: "story_analyst",
        id: Jido.Util.generate_id(),
        data: %{
          theme: theme.theme,
          evidence: theme.evidence,
          confidence: theme.confidence,
          timestamp: DateTime.utc_now()
        }
      }
      InterviewBus.publish(signal)
      Logger.debug("[StoryAnalyst] Identified theme: #{theme.theme}")

      # AGENT-TO-AGENT: Send theme directly to Probe Coach
      # This enables the Probe Coach to generate theme-aware probes
      notify_probe_coach(theme, state)
    end)

    # Emit pattern signals
    Enum.each(patterns, fn pattern ->
      signal = %Jido.Signal{
        type: "observer.insight.pattern",
        source: "story_analyst",
        id: Jido.Util.generate_id(),
        data: %{
          pattern_type: pattern.pattern,
          instances: pattern.instances,
          timestamp: DateTime.utc_now()
        }
      }
      InterviewBus.publish(signal)
      Logger.debug("[StoryAnalyst] Identified pattern: #{pattern.pattern}")
    end)

    # Always emit a completion signal so debug panel shows activity
    completion_signal = %Jido.Signal{
      type: "observer.status.complete",
      source: "story_analyst",
      id: Jido.Util.generate_id(),
      data: %{
        status: :complete,
        themes_found: length(themes),
        patterns_found: length(patterns),
        message: if(themes == [] and patterns == [], do: "No new insights found", else: "Analysis complete"),
        timestamp: DateTime.utc_now()
      }
    }
    InterviewBus.publish(completion_signal)

    # Update state via message (since we're in a Task)
    GenServer.cast(via_tuple(state.session_id), {:update_insights, themes, patterns})
  end

  @impl true
  def handle_cast({:update_insights, new_themes, new_patterns}, state) do
    updated_themes = (new_themes ++ state.themes) |> Enum.uniq_by(fn t -> t.theme end) |> Enum.take(10)
    updated_patterns = (new_patterns ++ state.patterns) |> Enum.uniq_by(fn p -> p.pattern end) |> Enum.take(5)

    {:noreply, %{state | themes: updated_themes, patterns: updated_patterns}}
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
        temperature: config[:temperature] || 0.3,
        max_tokens: config[:max_tokens] || 500
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
        Logger.error("[StoryAnalyst] LLM call failed: #{inspect(e)}")
        {:error, "LLM call failed"}
    end
  end

  # AGENT-TO-AGENT COMMUNICATION
  # Send discovered themes directly to Probe Coach so it can generate
  # theme-aware probe suggestions (not just utterance-based)
  defp notify_probe_coach(theme, _state) do
    signal = %Jido.Signal{
      type: "analyst.theme.discovered",
      source: "story_analyst",
      id: Jido.Util.generate_id(),
      data: %{
        target: "probe_coach",  # Direct message to Probe Coach
        theme: theme.theme,
        evidence: theme.evidence,
        confidence: theme.confidence,
        timestamp: DateTime.utc_now(),
        suggestion: "Consider probing how this theme connects to other areas of their story"
      }
    }
    InterviewBus.publish(signal)
    Logger.debug("[StoryAnalyst] -> [ProbeCoach] Theme notification: #{theme.theme}")
  end

  defp subscribe_to_signals do
    InterviewBus.subscribe("interview.utterance.**")
    # AGENT-TO-AGENT: Subscribe to engagement alerts from Engagement Monitor
    InterviewBus.subscribe("engagement.alert.broadcast")
    InterviewBus.subscribe("observer.status.engagement")
  end

  defp via_tuple(session_id) do
    {:via, Registry, {InterviewStudio.SessionRegistry, {:story_analyst, session_id}}}
  end

  defp default_llm_config do
    %{
      provider: :openrouter,
      model: "meta-llama/llama-4-scout-17b-16e-instruct",
      temperature: 0.3
    }
  end
end
