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
    :llm_config
  ]

  @analysis_threshold 3  # Analyze every N user messages

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

    # Trigger analysis periodically
    if role == :user and rem(new_count, @analysis_threshold) == 0 do
      analyze_async(new_state)
    end

    new_state
  end

  defp handle_signal(_signal, state), do: state

  # Analysis

  defp analyze_async(state) do
    # Run analysis in background to not block
    Task.start(fn ->
      case analyze_themes(state) do
        {:ok, new_themes, new_patterns} ->
          emit_insights(new_themes, new_patterns, state)
        {:error, reason} ->
          Logger.warning("[StoryAnalyst] Analysis failed: #{inspect(reason)}")
      end
    end)
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
    # Emit theme signals
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
        provider: config[:provider] || :groq,
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

  defp subscribe_to_signals do
    InterviewBus.subscribe("interview.utterance.**")
  end

  defp via_tuple(session_id) do
    {:via, Registry, {InterviewStudio.SessionRegistry, {:story_analyst, session_id}}}
  end

  defp default_llm_config do
    %{
      provider: :groq,
      model: "meta-llama/llama-4-scout-17b-16e-instruct",
      temperature: 0.3
    }
  end
end
