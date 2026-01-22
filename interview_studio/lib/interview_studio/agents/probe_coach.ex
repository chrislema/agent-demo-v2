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

  defp handle_signal(_signal, state), do: state

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
        provider: :openai,
        base_url: "https://api.groq.com/openai/v1",
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
  end

  defp via_tuple(session_id) do
    {:via, Registry, {InterviewStudio.SessionRegistry, {:probe_coach, session_id}}}
  end

  defp default_llm_config do
    %{
      provider: :openai,
      model: "meta-llama/llama-4-scout-17b-16e-instruct",
      temperature: 0.4
    }
  end
end
