defmodule InterviewStudio.Session do
  @moduledoc """
  Session manager - coordinates all agents for an interview session.

  Responsibilities:
  - Start/stop FSM, Director, and all observers together
  - Provide unified API for session management
  - Track session state across all components
  """

  require Logger

  alias InterviewStudio.Pipeline.InterviewFSM
  alias InterviewStudio.Agents.{Director, Scribe, StoryAnalyst, ProbeCoach, EngagementMonitor}
  alias InterviewStudio.InterviewBus

  @doc """
  Start a new interview session with all agents.
  Returns {:ok, session_id} or {:error, reason}
  """
  def start_session(opts \\ []) do
    session_id = Keyword.get(opts, :session_id, generate_session_id())

    with {:ok, _fsm} <- start_fsm(session_id),
         {:ok, _director} <- start_director(session_id, opts),
         {:ok, _scribe} <- start_scribe(session_id),
         {:ok, _analyst} <- start_story_analyst(session_id, opts),
         {:ok, _coach} <- start_probe_coach(session_id, opts),
         {:ok, _monitor} <- start_engagement_monitor(session_id) do

      Logger.info("[Session] Started session #{session_id}")
      {:ok, session_id}
    else
      {:error, reason} ->
        Logger.error("[Session] Failed to start session: #{inspect(reason)}")
        # Attempt cleanup
        stop_session(session_id)
        {:error, reason}
    end
  end

  @doc """
  Stop an interview session and all its agents.
  """
  def stop_session(session_id) do
    # Stop all agents (ignore errors from already-stopped processes)
    stop_agent(:fsm, session_id)
    stop_agent(:director, session_id)
    stop_agent(:scribe, session_id)
    stop_agent(:story_analyst, session_id)
    stop_agent(:probe_coach, session_id)
    stop_agent(:engagement_monitor, session_id)

    Logger.info("[Session] Stopped session #{session_id}")
    :ok
  end

  @doc """
  Get the combined state of a session.
  """
  def get_session_state(session_id) do
    %{
      session_id: session_id,
      fsm_phase: get_fsm_phase(session_id),
      director: get_director_state(session_id),
      scribe: get_scribe_state(session_id),
      engagement: get_engagement_level(session_id)
    }
  end

  @doc """
  Process a user message through the session.
  Returns {:ok, response} or {:error, reason}

  This implements the multi-agent collaboration pattern:
  1. Record message with Director
  2. Trigger parallel analysis from all observer agents
  3. Wait for insights (with timeout)
  4. Director synthesizes insights into next action
  5. Execute action
  """
  def process_message(session_id, message) do
    # Record the message with Director
    :ok = Director.process_user_message(session_id, message)

    # MULTI-AGENT: Gather insights from all observers in parallel
    # This is the synchronization barrier - we wait for all agents before deciding
    insights = gather_insights(session_id, timeout: 3000)

    # Get Director's next action, informed by agent insights
    action = Director.get_next_action(session_id, insights)

    # Handle the action
    handle_action(session_id, action)
  end

  @doc """
  Gather insights from all observer agents with timeout.

  Triggers parallel analysis and waits for results. Returns a consolidated
  map of insights from all agents:

    %{
      themes: [%{theme: "...", evidence: "...", confidence: 0.8}, ...],
      probes: [%{topic: "...", rationale: "...", priority: :high}, ...],
      engagement: %{level: :high, trend: :stable, recommendation: "..."}
    }

  If an agent times out, partial results from other agents are still included.
  """
  def gather_insights(session_id, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 3000)

    # Start parallel tasks for each observer agent
    tasks = [
      Task.async(fn -> {:themes, get_story_analyst_insights(session_id)} end),
      Task.async(fn -> {:probes, get_probe_coach_insights(session_id)} end),
      Task.async(fn -> {:engagement, get_engagement_insights(session_id)} end)
    ]

    # Wait for all tasks with timeout
    results = Task.yield_many(tasks, timeout)

    # Collect results, using defaults for timed-out tasks
    insights = Enum.reduce(results, %{themes: [], probes: [], engagement: default_engagement()}, fn
      {task, {:ok, {key, value}}}, acc ->
        Map.put(acc, key, value)

      {task, {:exit, reason}}, acc ->
        Logger.warning("[Session] Agent task failed: #{inspect(reason)}")
        acc

      {task, nil}, acc ->
        # Task timed out - kill it and use default
        Task.shutdown(task, :brutal_kill)
        Logger.warning("[Session] Agent task timed out")
        acc
    end)

    Logger.debug("[Session] Gathered insights: #{inspect(insights, pretty: true, limit: 3)}")
    insights
  end

  defp get_story_analyst_insights(session_id) do
    try do
      # Request fresh analysis and get current themes
      case StoryAnalyst.analyze_now(session_id) do
        {:ok, themes} -> themes
        {:error, _} -> StoryAnalyst.get_themes(session_id)
      end
    rescue
      _ -> []
    end
  end

  defp get_probe_coach_insights(session_id) do
    try do
      # Request fresh analysis and get current probes
      case ProbeCoach.analyze_now(session_id) do
        {:ok, probes} -> probes
        {:error, _} -> ProbeCoach.get_pending_probes(session_id)
      end
    rescue
      _ -> []
    end
  end

  defp get_engagement_insights(session_id) do
    try do
      # Engagement Monitor is already synchronous (no LLM)
      state = EngagementMonitor.get_state(session_id)
      %{
        level: state.level,
        trend: state.trend,
        indicators: state.indicators,
        recommendation: engagement_recommendation(state.level, state.trend)
      }
    rescue
      _ -> default_engagement()
    end
  end

  defp default_engagement do
    %{level: :medium, trend: :stable, indicators: %{}, recommendation: "Monitor and adjust"}
  end

  defp engagement_recommendation(level, trend) do
    case {level, trend} do
      {:critical, _} -> "Wrap up or change topic - user wants to finish"
      {:low, :declining} -> "Try a different approach or easier question"
      {:low, _} -> "Keep questions light and build rapport"
      {:medium, :declining} -> "Engagement dropping, consider more engaging topic"
      {:high, _} -> "Good engagement, lean in and go deeper"
      _ -> "Monitor and adjust as needed"
    end
  end

  @doc """
  Transition the session to a new phase.
  """
  def transition_to(session_id, phase, reason \\ "Manual transition") do
    InterviewFSM.transition(session_id, phase, reason)
  end

  @doc """
  Get the current phase of the session.
  """
  def current_phase(session_id) do
    InterviewFSM.current_phase(session_id)
  end

  # Private functions

  defp start_fsm(session_id) do
    InterviewFSM.start_link(session_id: session_id)
  end

  defp start_director(session_id, opts) do
    llm_config = Keyword.get(opts, :llm_config, %{})
    Director.start_link(session_id: session_id, llm_config: llm_config)
  end

  defp start_scribe(session_id) do
    Scribe.start_link(session_id: session_id)
  end

  defp start_story_analyst(session_id, opts) do
    llm_config = Keyword.get(opts, :llm_config, %{})
    StoryAnalyst.start_link(session_id: session_id, llm_config: llm_config)
  end

  defp start_probe_coach(session_id, opts) do
    llm_config = Keyword.get(opts, :llm_config, %{})
    ProbeCoach.start_link(session_id: session_id, llm_config: llm_config)
  end

  defp start_engagement_monitor(session_id) do
    EngagementMonitor.start_link(session_id: session_id)
  end

  defp stop_agent(type, session_id) do
    case Registry.lookup(InterviewStudio.SessionRegistry, {type, session_id}) do
      [{pid, _}] ->
        GenServer.stop(pid, :normal, 5000)
      [] ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp get_fsm_phase(session_id) do
    case InterviewFSM.current_phase(session_id) do
      phase when is_atom(phase) -> phase
      _ -> :unknown
    end
  rescue
    _ -> :unknown
  end

  defp get_director_state(session_id) do
    Director.get_state(session_id)
  rescue
    _ -> nil
  end

  defp get_scribe_state(session_id) do
    Scribe.get_state(session_id)
  rescue
    _ -> nil
  end

  defp get_engagement_level(session_id) do
    EngagementMonitor.get_level(session_id)
  rescue
    _ -> :unknown
  end

  defp handle_action(session_id, %{type: :transition, to_phase: phase, reason: reason}) do
    case InterviewFSM.transition(session_id, phase, reason) do
      {:ok, ^phase} ->
        # Sync Director's phase immediately (don't wait for async signal)
        Director.set_phase(session_id, phase)

        # After transitioning, get the next action (question/probe/etc)
        # This ensures we ask the first question after entering a new phase
        if phase in [:opening, :core_questions, :probing, :synthesis, :closing] do
          action = Director.get_next_action(session_id)
          handle_action(session_id, action)
        else
          {:ok, nil}
        end
      {:error, err} ->
        {:error, err}
    end
  end

  defp handle_action(session_id, %{type: :ask, question: question} = action) do
    context = Map.take(action, [:question, :question_id, :source])

    case Director.generate_response(session_id, :ask, context) do
      {:ok, response} ->
        Director.record_host_message(session_id, response)
        publish_host_utterance(response, action, session_id)
        {:ok, response}
      {:error, _reason} ->
        # Fallback to the raw question
        Director.record_host_message(session_id, question)
        publish_host_utterance(question, action, session_id)
        {:ok, question}
    end
  end

  # DYNAMIC QUESTION - Generated from collective agent intelligence
  # This is where multi-agent collaboration produces emergent questions
  defp handle_action(session_id, %{type: :ask_dynamic} = action) do
    # Pass all context to Director for dynamic generation
    context = Map.take(action, [:topic, :themes, :probes, :engagement, :source])

    Logger.debug("[Session] Generating dynamic question for topic: #{action.topic}")

    case Director.generate_response(session_id, :ask_dynamic, context) do
      {:ok, response} ->
        Director.record_host_message(session_id, response)
        publish_host_utterance(response, action, session_id)
        {:ok, response}
      {:error, reason} ->
        # Fallback: generate a basic question for the topic
        Logger.warning("[Session] Dynamic generation failed: #{inspect(reason)}, using fallback")
        fallback = generate_topic_fallback(action.topic)
        Director.record_host_message(session_id, fallback)
        publish_host_utterance(fallback, action, session_id)
        {:ok, fallback}
    end
  end

  defp handle_action(session_id, %{type: :probe, question: question, topic: topic}) do
    context = %{question: question, topic: topic}

    case Director.generate_response(session_id, :probe, context) do
      {:ok, response} ->
        Director.record_host_message(session_id, response)
        publish_host_utterance(response, %{type: :probe, topic: topic}, session_id)
        {:ok, response}
      {:error, _reason} ->
        Director.record_host_message(session_id, question)
        publish_host_utterance(question, %{type: :probe, topic: topic}, session_id)
        {:ok, question}
    end
  end

  defp handle_action(session_id, %{type: :synthesize, themes: themes}) do
    context = %{themes: themes}

    case Director.generate_response(session_id, :synthesize, context) do
      {:ok, response} ->
        Director.record_host_message(session_id, response)
        publish_host_utterance(response, %{type: :synthesize}, session_id)
        {:ok, response}
      {:error, _reason} ->
        fallback = "I've really enjoyed learning about you. Let me share what I've heard..."
        Director.record_host_message(session_id, fallback)
        publish_host_utterance(fallback, %{type: :synthesize}, session_id)
        {:ok, fallback}
    end
  end

  defp handle_action(session_id, %{type: :close}) do
    case Director.generate_response(session_id, :close, %{}) do
      {:ok, response} ->
        Director.record_host_message(session_id, response)
        publish_host_utterance(response, %{type: :close}, session_id)
        {:ok, response}
      {:error, _reason} ->
        fallback = "Thank you so much for sharing your story with me. This has been wonderful!"
        Director.record_host_message(session_id, fallback)
        publish_host_utterance(fallback, %{type: :close}, session_id)
        {:ok, fallback}
    end
  end

  defp handle_action(_session_id, %{type: :wait}) do
    {:ok, nil}
  end

  defp handle_action(_session_id, action) do
    Logger.warning("[Session] Unknown action type: #{inspect(action)}")
    {:ok, nil}
  end

  defp publish_host_utterance(content, action, _session_id) do
    signal = %Jido.Signal{
      type: "interview.utterance.host",
      source: "director",
      id: Jido.Util.generate_id(),
      data: %{
        content: content,
        timestamp: DateTime.utc_now(),
        action_type: action[:type],
        question_id: action[:question_id]
      }
    }
    InterviewBus.publish(signal)
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  # Fallback questions when dynamic generation fails
  defp generate_topic_fallback(:origin) do
    "I'd love to hear about your background - how did you get to where you are today?"
  end
  defp generate_topic_fallback(:passion) do
    "What drives you? What are you most passionate about in your work?"
  end
  defp generate_topic_fallback(:differentiation) do
    "What would you say makes your approach or perspective unique?"
  end
  defp generate_topic_fallback(:moments) do
    "Was there a pivotal moment or turning point that really shaped who you've become?"
  end
  defp generate_topic_fallback(:vision) do
    "Where are you headed? What's the vision you're working toward?"
  end
  defp generate_topic_fallback(_topic) do
    "Tell me more about that - I'd love to hear your thoughts."
  end
end
