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
    :topics_explored,       # Categories/topics we've covered
    :topics_to_explore,     # Categories/topics still to explore
    :active_themes,
    :pending_probes,
    :engagement_level,
    :conversation_history,
    :last_user_message,
    :llm_config,
    :synthesis_delivered,
    :user_responded_to_synthesis,
    :last_insights          # Most recent insights from parallel analysis
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

  def get_next_action(session_id, insights \\ %{}) do
    GenServer.call(via_tuple(session_id), {:get_next_action, insights}, 30_000)
  end

  def generate_response(session_id, action_type, context) do
    GenServer.call(via_tuple(session_id), {:generate_response, action_type, context}, 60_000)
  end

  def set_phase(session_id, phase) do
    GenServer.call(via_tuple(session_id), {:set_phase, phase})
  end

  def record_host_message(session_id, message) do
    GenServer.call(via_tuple(session_id), {:host_message, message})
  end

  @doc """
  Poll all observer agents for their vote on transitioning to a new phase.
  Returns a map of agent votes: %{agent_name: {:ready | :not_ready | :abstain, rationale}}
  Used for consensus-based phase transitions.
  """
  def poll_transition_readiness(session_id, target_phase) do
    GenServer.call(via_tuple(session_id), {:poll_transition, target_phase}, 10_000)
  end

  @doc """
  Check if there's consensus for a phase transition based on agent votes.
  Returns {:consensus, votes} or {:no_consensus, votes}
  """
  def check_transition_consensus(session_id, target_phase) do
    GenServer.call(via_tuple(session_id), {:check_consensus, target_phase}, 10_000)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    llm_config = Keyword.get(opts, :llm_config, default_llm_config())

    state = %__MODULE__{
      session_id: session_id,
      current_phase: :preparation,
      topics_explored: [],
      topics_to_explore: Phases.core_categories(),  # [:origin, :passion, :differentiation, :moments, :vision]
      active_themes: [],
      pending_probes: [],
      engagement_level: :high,
      conversation_history: [],
      last_user_message: nil,
      llm_config: llm_config,
      synthesis_delivered: false,
      user_responded_to_synthesis: false,
      last_insights: %{}
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
    # Skip empty messages (used to kick off the interview)
    if message == "" or message == nil do
      {:reply, :ok, state}
    else
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

      # Track if user responded after synthesis was delivered
      new_state = if state.current_phase == :synthesis and state.synthesis_delivered do
        %{new_state | user_responded_to_synthesis: true}
      else
        new_state
      end

      {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:get_next_action, insights}, _from, state) do
    # MULTI-AGENT: Merge gathered insights into state for decision-making
    # This is where parallel agent analysis influences the Director's decisions
    state_with_insights = merge_insights_into_state(state, insights)

    action = decide_next_action(state_with_insights)
    # Update state based on action taken
    new_state = apply_action_to_state(action, state_with_insights)

    # Log the synthesis for debugging
    Logger.debug("[Director] Synthesized action from insights: #{inspect(action.type)}")

    {:reply, action, new_state}
  end

  # Merge parallel agent insights into Director's state for decision-making
  defp merge_insights_into_state(state, insights) when map_size(insights) == 0 do
    # No insights provided - fall back to sync engagement check
    current_engagement = get_current_engagement(state.session_id)
    %{state | engagement_level: current_engagement}
  end

  defp merge_insights_into_state(state, insights) do
    # Extract themes from Story Analyst
    new_themes = Map.get(insights, :themes, [])
    merged_themes = merge_themes(state.active_themes, new_themes)

    # Extract probes from Probe Coach
    new_probes = Map.get(insights, :probes, [])
    merged_probes = merge_probes(state.pending_probes, new_probes)

    # Extract engagement from Engagement Monitor
    engagement_data = Map.get(insights, :engagement, %{})
    engagement_level = Map.get(engagement_data, :level, state.engagement_level)

    Logger.debug("[Director] Merged insights - themes: #{length(merged_themes)}, probes: #{length(merged_probes)}, engagement: #{engagement_level}")

    %{state |
      active_themes: merged_themes,
      pending_probes: merged_probes,
      engagement_level: engagement_level,
      last_insights: insights  # Store for dynamic question generation
    }
  end

  defp merge_themes(existing, new) do
    # Combine and deduplicate themes
    (new ++ existing)
    |> Enum.uniq_by(fn t -> t[:theme] || t.theme end)
    |> Enum.take(10)
  end

  defp merge_probes(existing, new) do
    # Convert new probes to expected format and merge
    formatted_new = Enum.map(new, fn p ->
      %{
        topic: p[:topic] || p.topic,
        question: p[:suggested_question] || p[:question] || p.suggested_question,
        rationale: p[:rationale] || p.rationale,
        priority: p[:priority] || p.priority || :medium
      }
    end)

    # Combine, sort by priority, and limit
    (formatted_new ++ existing)
    |> Enum.uniq_by(fn p -> p.topic end)
    |> Enum.sort_by(fn p ->
      case p.priority do
        :high -> 0
        :medium -> 1
        :low -> 2
        _ -> 1
      end
    end)
    |> Enum.take(5)
  end

  @impl true
  def handle_call({:generate_response, action_type, context}, _from, state) do
    response = do_generate_response(action_type, context, state)
    {:reply, response, state}
  end

  @impl true
  def handle_call({:set_phase, phase}, _from, state) do
    Logger.debug("[Director] Phase set directly to: #{phase}")
    {:reply, :ok, %{state | current_phase: phase}}
  end

  @impl true
  def handle_call({:host_message, message}, _from, state) do
    # Record interviewer's message in conversation history
    timestamp = DateTime.utc_now()

    new_history = [
      %{role: :host, content: message, timestamp: timestamp}
      | state.conversation_history
    ]

    {:reply, :ok, %{state | conversation_history: new_history}}
  end

  @impl true
  def handle_call({:poll_transition, target_phase}, _from, state) do
    # CONSENSUS MECHANISM: Poll all agents for their votes on phase transition
    votes = gather_transition_votes(state.session_id, target_phase)
    Logger.debug("[Director] Polled transition votes for #{target_phase}: #{inspect(votes)}")
    {:reply, votes, state}
  end

  @impl true
  def handle_call({:check_consensus, target_phase}, _from, state) do
    # CONSENSUS MECHANISM: Check if agents agree on the transition
    votes = gather_transition_votes(state.session_id, target_phase)
    result = evaluate_consensus(votes, target_phase)
    Logger.debug("[Director] Consensus check for #{target_phase}: #{elem(result, 0)}")
    {:reply, result, state}
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

  # Wrap-up detection - check user message directly for wrap-up cues
  # Get engagement level directly from Engagement Monitor (sync call)
  defp get_current_engagement(session_id) do
    alias InterviewStudio.Agents.EngagementMonitor
    try do
      EngagementMonitor.get_level(session_id)
    rescue
      _ -> :medium  # Default if monitor not available
    catch
      :exit, _ -> :medium
    end
  end

  defp user_wants_to_wrap_up?(nil), do: false
  defp user_wants_to_wrap_up?(message) do
    wrap_up_markers = [
      "wrap up", "let's wrap", "wrapping up", "finish", "let's finish",
      "move on", "let's move on", "already explained", "already said",
      "end the interview", "that's enough", "i'm done", "let's end",
      "can we finish", "ready to finish", "time to wrap", "let's stop"
    ]
    downcased = String.downcase(message)
    Enum.any?(wrap_up_markers, fn marker -> String.contains?(downcased, marker) end)
  end

  # Decision logic

  defp decide_next_action(state) do
    cond do
      # User explicitly wants to wrap up - check directly (don't wait for async signal)
      # This overrides consensus - user intent is always respected
      user_wants_to_wrap_up?(state.last_user_message) ->
        # Skip directly to synthesis if not there yet, or to closing if already past
        if state.current_phase in [:synthesis, :closing] do
          %{
            type: :transition,
            to_phase: :closing,
            reason: "User requested wrap up",
            consensus_override: :user_request
          }
        else
          %{
            type: :transition,
            to_phase: :synthesis,
            reason: "User requested wrap up",
            consensus_override: :user_request
          }
        end

      # Critical engagement - wrap up (engagement monitor has high weight)
      state.engagement_level == :critical ->
        %{
          type: :transition,
          to_phase: :closing,
          reason: "Engagement dropped to critical level",
          consensus_override: :critical_engagement
        }

      # In preparation - auto-advance to opening (no consensus needed)
      state.current_phase == :preparation ->
        %{
          type: :transition,
          to_phase: :opening,
          reason: "Preparation complete"
        }

      # In opening - greet the user, then move to core questions
      state.current_phase == :opening ->
        # If user has responded with actual content, transition to core questions
        user_messages = Enum.filter(state.conversation_history, fn m ->
          m.role == :user and m.content != "" and m.content != nil
        end)
        if length(user_messages) >= 1 do
          # CONSENSUS: Check if agents agree to move to core questions
          maybe_transition_with_consensus(state, :core_questions, "Opening complete, user engaged")
        else
          question = get_opening_question()
          %{
            type: :ask,
            question: question,
            source: :question_bank
          }
        end

      # In core questions - either probe or ask next question
      state.current_phase == :core_questions ->
        decide_core_questions_action(state)

      # In probing - ask probe questions
      state.current_phase == :probing ->
        decide_probing_action(state)

      # In synthesis - summarize themes, then transition to closing
      state.current_phase == :synthesis ->
        cond do
          # User has responded to synthesis - move to closing
          state.synthesis_delivered and state.user_responded_to_synthesis ->
            # CONSENSUS: Check before moving to closing
            maybe_transition_with_consensus(state, :closing, "Synthesis complete, user confirmed")

          # Synthesis already delivered - user response triggers closing
          state.synthesis_delivered and state.last_user_message != nil ->
            maybe_transition_with_consensus(state, :closing, "Synthesis delivered, moving to closing")

          # First time - deliver synthesis
          true ->
            %{
              type: :synthesize,
              themes: state.active_themes
            }
        end

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

  # CONSENSUS MECHANISM: Attempt transition with agent consensus
  # If no consensus, Director makes final call but logs the disagreement
  defp maybe_transition_with_consensus(state, target_phase, default_reason) do
    votes = gather_transition_votes(state.session_id, target_phase)
    {consensus_result, _votes} = evaluate_consensus(votes, target_phase)

    case consensus_result do
      :consensus ->
        Logger.info("[Director] CONSENSUS reached for transition to #{target_phase}")
        %{
          type: :transition,
          to_phase: target_phase,
          reason: default_reason,
          consensus: :reached,
          votes: votes
        }

      :no_consensus ->
        # Director makes final call but records the disagreement
        Logger.warning("[Director] NO CONSENSUS for #{target_phase} - Director overriding. Votes: #{inspect(votes)}")

        # Emit disagreement signal for debug visibility
        emit_disagreement_signal(target_phase, votes, state)

        %{
          type: :transition,
          to_phase: target_phase,
          reason: "#{default_reason} (Director override - no consensus)",
          consensus: :director_override,
          votes: votes
        }
    end
  end

  defp emit_disagreement_signal(target_phase, votes, _state) do
    signal = %Jido.Signal{
      type: "director.consensus.disagreement",
      source: "director",
      id: Jido.Util.generate_id(),
      data: %{
        target_phase: target_phase,
        votes: format_votes_for_signal(votes),
        resolution: :director_override,
        timestamp: DateTime.utc_now()
      }
    }
    InterviewBus.publish(signal)
  end

  defp format_votes_for_signal(votes) do
    votes
    |> Enum.map(fn {agent, {vote, rationale}} ->
      %{agent: agent, vote: vote, rationale: rationale}
    end)
  end

  defp decide_core_questions_action(state) do
    # Check if we have high-priority probes from Probe Coach
    high_probe = Enum.find(state.pending_probes, fn p -> p.priority == :high end)

    cond do
      # High-priority probe from Probe Coach - insert it (agent collaboration!)
      high_probe != nil ->
        %{
          type: :probe,
          question: high_probe.question,
          topic: high_probe.topic,
          source: :probe_coach
        }

      # More topics to explore - generate dynamic question
      state.topics_to_explore != [] ->
        # Pick next topic, considering themes and engagement
        next_topic = select_next_topic(state)

        %{
          type: :ask_dynamic,
          topic: next_topic,
          themes: state.active_themes,
          probes: state.pending_probes,
          engagement: state.engagement_level,
          source: :collective_intelligence
        }

      # All topics covered - transition to probing or synthesis
      # CONSENSUS: Check with agents before major transitions
      state.pending_probes != [] ->
        maybe_transition_with_consensus(state, :probing, "Core topics explored, probes pending")

      true ->
        maybe_transition_with_consensus(state, :synthesis, "Core topics explored")
    end
  end

  # Select the next topic to explore based on collective intelligence
  defp select_next_topic(state) do
    remaining = state.topics_to_explore

    # If we have themes that relate to a remaining topic, prioritize that
    theme_suggested_topic = find_theme_related_topic(state.active_themes, remaining)

    # If we have probes that relate to a topic, consider that
    probe_suggested_topic = find_probe_related_topic(state.pending_probes, remaining)

    cond do
      # Theme suggests a topic - explore that thread
      theme_suggested_topic != nil ->
        Logger.debug("[Director] Theme-guided topic selection: #{theme_suggested_topic}")
        theme_suggested_topic

      # Probe suggests a topic - follow that lead
      probe_suggested_topic != nil ->
        Logger.debug("[Director] Probe-guided topic selection: #{probe_suggested_topic}")
        probe_suggested_topic

      # Default: follow natural interview flow
      true ->
        hd(remaining)
    end
  end

  defp find_theme_related_topic(themes, remaining_topics) do
    # Map themes to related topics
    topic_keywords = %{
      origin: ["background", "start", "began", "grew up", "childhood", "early"],
      passion: ["love", "passion", "drive", "motivate", "care about", "excited"],
      differentiation: ["unique", "different", "approach", "perspective", "style"],
      moments: ["moment", "turning point", "pivotal", "changed", "realized"],
      vision: ["future", "goal", "vision", "next", "working toward", "dream"]
    }

    Enum.find(remaining_topics, fn topic ->
      keywords = Map.get(topic_keywords, topic, [])
      Enum.any?(themes, fn theme ->
        theme_text = (theme[:theme] || theme.theme || "") |> String.downcase()
        Enum.any?(keywords, fn kw -> String.contains?(theme_text, kw) end)
      end)
    end)
  end

  defp find_probe_related_topic(probes, remaining_topics) do
    topic_keywords = %{
      origin: ["background", "start", "how", "where"],
      passion: ["why", "love", "passion", "drive"],
      differentiation: ["unique", "different", "approach"],
      moments: ["when", "moment", "turning", "pivotal"],
      vision: ["future", "goal", "next", "plan"]
    }

    Enum.find(remaining_topics, fn topic ->
      keywords = Map.get(topic_keywords, topic, [])
      Enum.any?(probes, fn probe ->
        probe_text = (probe[:topic] || probe.topic || "") |> String.downcase()
        Enum.any?(keywords, fn kw -> String.contains?(probe_text, kw) end)
      end)
    end)
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

      # Done probing - CONSENSUS: Check with agents before synthesis
      true ->
        maybe_transition_with_consensus(state, :synthesis, "Probing complete")
    end
  end

  defp get_opening_question do
    case Phases.questions(:opening) do
      [first | _] -> first.text
      [] -> "Hi! I'm excited to learn more about you and your story. Ready to dive in?"
    end
  end

  # State updates based on actions

  defp apply_action_to_state(%{type: :ask_dynamic, topic: topic} = action, state) do
    # Dynamic question - mark topic as explored
    explored = [topic | state.topics_explored]
    remaining = Enum.reject(state.topics_to_explore, fn t -> t == topic end)
    Logger.debug("[Director] Topic explored: #{topic}, remaining: #{inspect(remaining)}")
    %{state | topics_explored: explored, topics_to_explore: remaining}
  end

  defp apply_action_to_state(%{type: :ask}, state) do
    # Opening question or scripted question - just track it
    state
  end

  defp apply_action_to_state(%{type: :probe, topic: topic}, state) do
    # Remove the used probe from pending
    remaining_probes = Enum.reject(state.pending_probes, fn p -> p.topic == topic end)
    %{state | pending_probes: remaining_probes}
  end

  defp apply_action_to_state(%{type: :synthesize}, state) do
    # Mark that synthesis has been delivered
    %{state | synthesis_delivered: true}
  end

  defp apply_action_to_state(_action, state) do
    # For transitions, waits, etc. - no state change needed
    state
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

  # CONSENSUS MECHANISM: Gather votes from all observer agents
  defp gather_transition_votes(session_id, target_phase) do
    alias InterviewStudio.Agents.{StoryAnalyst, ProbeCoach, EngagementMonitor}

    # Poll each agent in parallel with timeout handling
    tasks = [
      Task.async(fn -> {:story_analyst, safe_vote(StoryAnalyst, session_id, target_phase)} end),
      Task.async(fn -> {:probe_coach, safe_vote(ProbeCoach, session_id, target_phase)} end),
      Task.async(fn -> {:engagement_monitor, safe_vote(EngagementMonitor, session_id, target_phase)} end)
    ]

    # Wait for all votes with timeout
    results = Task.yield_many(tasks, 3_000)

    # Process results, using abstain for timeouts/failures
    results
    |> Enum.map(fn {task, result} ->
      case result do
        {:ok, {agent, vote}} -> {agent, vote}
        {:exit, _reason} -> {:unknown, {:abstain, "Agent failed to respond"}}
        nil ->
          Task.shutdown(task, :brutal_kill)
          {:unknown, {:abstain, "Agent timed out"}}
      end
    end)
    |> Enum.into(%{})
  end

  defp safe_vote(agent_module, session_id, target_phase) do
    try do
      agent_module.vote_transition(session_id, target_phase)
    rescue
      _ -> {:abstain, "Agent error"}
    catch
      :exit, _ -> {:abstain, "Agent unavailable"}
    end
  end

  # CONSENSUS MECHANISM: Evaluate votes to determine if transition should proceed
  # Default threshold: 2/3 agents must be ready (or abstain counts as not blocking)
  defp evaluate_consensus(votes, target_phase) do
    ready_count = Enum.count(votes, fn {_agent, {vote, _}} -> vote == :ready end)
    not_ready_count = Enum.count(votes, fn {_agent, {vote, _}} -> vote == :not_ready end)
    total_voting = Enum.count(votes, fn {_agent, {vote, _}} -> vote != :abstain end)

    # Apply weighted voting for certain decisions
    weighted_votes = apply_vote_weights(votes, target_phase)

    cond do
      # Strong consensus: majority of voters say ready
      ready_count >= 2 ->
        {:consensus, votes}

      # No objections: ready voters outnumber not_ready
      ready_count > not_ready_count ->
        {:consensus, votes}

      # Weighted override for critical decisions
      weighted_votes.weighted_ready > weighted_votes.threshold ->
        {:consensus, votes}

      # No consensus
      true ->
        {:no_consensus, votes}
    end
  end

  # Apply agent-specific weights for certain decisions
  defp apply_vote_weights(votes, target_phase) do
    # Default weights
    weights = %{
      story_analyst: 1.0,
      probe_coach: 1.0,
      engagement_monitor: 1.0
    }

    # Adjust weights based on decision type
    weights = case target_phase do
      :closing ->
        # Engagement Monitor has higher weight for closing decisions
        %{weights | engagement_monitor: 2.0}

      :synthesis ->
        # Story Analyst has higher weight for synthesis readiness
        %{weights | story_analyst: 1.5}

      :probing ->
        # Probe Coach has higher weight for probing decisions
        %{weights | probe_coach: 1.5}

      _ ->
        weights
    end

    # Calculate weighted score
    weighted_ready = votes
    |> Enum.reduce(0.0, fn {agent, {vote, _}}, acc ->
      weight = Map.get(weights, agent, 1.0)
      case vote do
        :ready -> acc + weight
        _ -> acc
      end
    end)

    total_weight = weights |> Map.values() |> Enum.sum()
    threshold = total_weight * 0.6  # 60% threshold

    %{weighted_ready: weighted_ready, threshold: threshold, weights: weights}
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
        |> Enum.map(fn t ->
          theme = t[:theme] || t.theme || "unknown"
          "- #{theme}"
        end)
        |> Enum.join("\n")
    end

    topics_explored = state.topics_explored |> Enum.map(&Atom.to_string/1) |> Enum.join(", ")
    topics_remaining = state.topics_to_explore |> Enum.map(&Atom.to_string/1) |> Enum.join(", ")

    """
    You are a warm, skilled interviewer conducting a "Story of You" interview.
    Your goal is to discover what makes this person unique and amazing, to create a compelling article about them.

    Interview Style:
    - Be genuinely curious and engaged
    - Ask follow-up questions naturally
    - Acknowledge and validate what they share
    - Keep responses concise (2-3 sentences max)
    - Be conversational, not formal
    - NEVER ask generic questions - always reference specific things they've shared

    Current phase: #{state.current_phase}
    Topics explored: #{if topics_explored == "", do: "none yet", else: topics_explored}
    Topics remaining: #{if topics_remaining == "", do: "none", else: topics_remaining}

    Themes discovered by Story Analyst:
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

  # DYNAMIC QUESTION GENERATION - The heart of multi-agent collaboration
  # This prompt synthesizes inputs from all observer agents to generate
  # contextually relevant questions that emerge from collective intelligence
  defp build_user_prompt(:ask_dynamic, context, state) do
    history = format_recent_history(state.conversation_history, 5)
    topic = context[:topic] || context.topic
    themes = context[:themes] || context.themes || []
    probes = context[:probes] || context.probes || []
    engagement = context[:engagement] || context.engagement || :medium

    themes_text = format_themes_for_prompt(themes)
    probes_text = format_probes_for_prompt(probes)
    engagement_guidance = engagement_to_guidance(engagement)
    topic_description = topic_to_description(topic)

    """
    Recent conversation:
    #{history}

    === MULTI-AGENT SYNTHESIS ===

    THEMES DISCOVERED BY STORY ANALYST:
    #{themes_text}

    PROBE SUGGESTIONS FROM PROBE COACH:
    #{probes_text}

    ENGAGEMENT LEVEL: #{engagement}
    #{engagement_guidance}

    === YOUR TASK ===

    Generate a question about: #{topic_description}

    CRITICAL REQUIREMENTS:
    1. The question MUST reference specific details from the conversation
    2. If themes were discovered, weave them into your question
    3. If probes were suggested, consider incorporating their insights
    4. Match the question depth to the engagement level
    5. DO NOT ask generic questions - be specific to what this person has shared
    6. The question should feel like a natural continuation of the conversation

    BAD EXAMPLE (generic): "What drives you in your work?"
    GOOD EXAMPLE (specific): "You mentioned your brother was the 'smart one' - I'm curious how that dynamic shaped your approach to building your company..."

    Respond with just the question, naturally phrased.
    """
  end

  defp format_themes_for_prompt([]), do: "No themes identified yet - this is early in the conversation."
  defp format_themes_for_prompt(themes) do
    themes
    |> Enum.take(5)
    |> Enum.map(fn t ->
      theme = t[:theme] || t.theme || "unknown"
      evidence = t[:evidence] || t.evidence || ""
      "- #{theme}" <> if(evidence != "", do: " (evidence: #{String.slice(evidence, 0, 100)})", else: "")
    end)
    |> Enum.join("\n")
  end

  defp format_probes_for_prompt([]), do: "No specific probes suggested yet."
  defp format_probes_for_prompt(probes) do
    probes
    |> Enum.take(3)
    |> Enum.map(fn p ->
      topic = p[:topic] || p.topic || "unknown"
      rationale = p[:rationale] || p.rationale || ""
      priority = p[:priority] || p.priority || :medium
      "- [#{priority}] #{topic}" <> if(rationale != "", do: ": #{rationale}", else: "")
    end)
    |> Enum.join("\n")
  end

  defp engagement_to_guidance(:high) do
    "User is highly engaged - lean in! Ask deeper, more probing questions. They're ready to share."
  end
  defp engagement_to_guidance(:medium) do
    "User engagement is moderate - balance depth with accessibility. Build on what's working."
  end
  defp engagement_to_guidance(:low) do
    "User engagement is lower - keep it lighter. Consider shifting to a topic they might find more energizing."
  end
  defp engagement_to_guidance(:critical) do
    "User seems ready to wrap up - respect their energy. Keep questions brief and consider transitioning."
  end
  defp engagement_to_guidance(_), do: "Adjust your approach based on the conversation flow."

  defp topic_to_description(:origin), do: "their ORIGIN STORY - background, how they got started, where they came from"
  defp topic_to_description(:passion), do: "their PASSION - what drives them, what they care deeply about"
  defp topic_to_description(:differentiation), do: "what makes them UNIQUE - their distinctive approach or perspective"
  defp topic_to_description(:moments), do: "PIVOTAL MOMENTS - turning points that shaped who they became"
  defp topic_to_description(:vision), do: "their VISION - where they're headed, what they're working toward"
  defp topic_to_description(topic), do: "#{topic}"

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
      # Build Model struct with API key from environment (Groq via OpenAI-compatible API)
      api_key = System.get_env("AgentDemo_Groq_API_Key") || ""

      model = %Jido.AI.Model{
        provider: :openrouter,
        base_url: "https://api.groq.com/openai/v1/chat/completions",
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
      provider: :openrouter,
      model: "meta-llama/llama-4-scout-17b-16e-instruct",
      temperature: 0.7
    }
  end
end
