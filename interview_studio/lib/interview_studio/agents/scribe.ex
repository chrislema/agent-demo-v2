defmodule InterviewStudio.Agents.Scribe do
  @moduledoc """
  The Scribe Agent - documents everything.

  Responsibilities:
  - Maintain full transcript with timestamps
  - Tag notable quotes
  - Generate phase summaries
  - Emit RecordQuote and RecordSummary signals

  No LLM required - pure recording and pattern matching.

  Implemented as a Jido.Agent with signal_routes and Actions.
  """

  use Jido.Agent,
    name: "scribe",
    description: "Documents interview transcript, quotes, and phase summaries",
    schema: [
      session_id: [type: :any, default: nil],
      transcript: [type: :any, default: []],
      quotes: [type: :any, default: []],
      phase_summaries: [type: :any, default: %{}],
      current_phase: [type: :atom, default: :preparation],
      phase_start_time: [type: :any, default: nil],
      phase_messages: [type: :any, default: []],
      config: [type: :any, default: %{}]
    ],
    signal_routes: [
      {"interview.utterance.user", InterviewStudio.Agents.Scribe.Actions.RecordUserUtterance},
      {"interview.utterance.host", InterviewStudio.Agents.Scribe.Actions.RecordHostUtterance},
      {"interview.phase.entered", InterviewStudio.Agents.Scribe.Actions.HandlePhaseChange}
    ]

  require Logger

  alias InterviewStudio.InterviewBus
  alias InterviewStudio.ConfigLoader

  @default_config %{
    quote_detection: %{
      min_length: 200,
      emotional_words: ~w(love hate afraid excited nervous proud frustrated happy sad angry passionate),
      reflection_phrases: ["i realized", "i learned", "i discovered", "i understood", "it hit me", "i knew then", "that's when i"],
      key_phrases: ["the most important", "what matters most", "my purpose", "what drives me", "the turning point", "changed everything"]
    }
  }

  # Client API

  def start_link(opts \\ []) do
    session_id = Keyword.fetch!(opts, :session_id)
    config = ConfigLoader.load_with_defaults(:scribe, @default_config)

    {:ok, pid} = Jido.AgentServer.start_link(
      agent: __MODULE__,
      name: via_tuple(session_id),
      id: "scribe_#{session_id}",
      register_global: false,
      initial_state: %{
        session_id: session_id,
        config: config,
        phase_start_time: DateTime.utc_now()
      }
    )

    InterviewBus.subscribe_pid("interview.utterance.**", pid)
    InterviewBus.subscribe_pid("interview.phase.**", pid)

    Logger.info("[Scribe] Started for session #{session_id}")
    {:ok, pid}
  end

  def get_state(session_id) do
    {:ok, server_state} = Jido.AgentServer.state(via_tuple(session_id))
    server_state.agent.state
  end

  def get_transcript(session_id) do
    state = get_state(session_id)
    Enum.reverse(state.transcript)
  end

  def get_quotes(session_id) do
    state = get_state(session_id)
    Enum.reverse(state.quotes)
  end

  @doc """
  Get a formatted context summary for LLM prompts.
  """
  def get_interview_context(session_id) do
    state = get_state(session_id)
    format_interview_context(state)
  end

  defp via_tuple(session_id) do
    {:via, Registry, {InterviewStudio.SessionRegistry, {:scribe, session_id}}}
  end

  # Format interview context for LLM memory
  defp format_interview_context(state) do
    %{
      phases_completed: format_phases_completed(state),
      key_quotes: format_key_quotes(state),
      conversation_summary: format_conversation_summary(state),
      formatted_text: build_context_text(state)
    }
  end

  defp format_phases_completed(state) do
    (state.phase_summaries || %{})
    |> Enum.map(fn {phase, summary} ->
      %{
        phase: phase,
        exchanges: summary.exchange_count,
        user_engagement: if(summary.avg_user_response_length > 30, do: :high, else: :low)
      }
    end)
  end

  defp format_key_quotes(state) do
    (state.quotes || [])
    |> Enum.reverse()
    |> Enum.take(10)
    |> Enum.map(fn q ->
      %{
        quote: String.slice(q.quote, 0, 200),
        tags: q.tags,
        phase: q.phase
      }
    end)
  end

  defp format_conversation_summary(state) do
    user_messages = (state.transcript || [])
    |> Enum.reverse()
    |> Enum.filter(fn e -> e.role == :user end)

    %{
      total_exchanges: length(state.transcript || []),
      user_messages: length(user_messages),
      phases_visited: Map.keys(state.phase_summaries || %{})
    }
  end

  defp build_context_text(state) do
    quotes_text = (state.quotes || [])
    |> Enum.reverse()
    |> Enum.take(8)
    |> Enum.map(fn q ->
      tags = Enum.join(q.tags, ", ")
      "- [#{tags}] \"#{String.slice(q.quote, 0, 150)}...\""
    end)
    |> Enum.join("\n")

    phases_text = (state.phase_summaries || %{})
    |> Enum.map(fn {phase, summary} ->
      engagement = if summary.avg_user_response_length > 30, do: "engaged", else: "brief"
      "- #{phase}: #{summary.exchange_count} exchanges (#{engagement} responses)"
    end)
    |> Enum.join("\n")

    key_learnings = (state.transcript || [])
    |> Enum.reverse()
    |> Enum.filter(fn e -> e.role == :user and String.length(e.content) > 100 end)
    |> Enum.take(5)
    |> Enum.map(fn e ->
      first_sentence = e.content
      |> String.split(~r/[.!?]/)
      |> List.first()
      |> String.slice(0, 150)
      "- #{first_sentence}"
    end)
    |> Enum.join("\n")

    """
    === INTERVIEW MEMORY (from Scribe) ===

    PHASES COMPLETED:
    #{if phases_text == "", do: "None yet", else: phases_text}

    KEY QUOTES CAPTURED:
    #{if quotes_text == "", do: "None yet", else: quotes_text}

    KEY LEARNINGS FROM USER:
    #{if key_learnings == "", do: "No substantial responses yet", else: key_learnings}

    === END INTERVIEW MEMORY ===
    """
  end
end

# =============================================================================
# Action: RecordUserUtterance
# =============================================================================

defmodule InterviewStudio.Agents.Scribe.Actions.RecordUserUtterance do
  @moduledoc "Records a user utterance and checks for notable quotes."

  use Jido.Action,
    name: "scribe_record_user_utterance",
    description: "Record user utterance to transcript and detect quotes",
    schema: [
      content: [type: :string, required: true],
      timestamp: [type: :any]
    ]

  alias InterviewStudio.InterviewBus

  @impl true
  def run(params, context) do
    state = context.state
    content = params.content || params[:content] || ""

    entry = %{
      role: :user,
      content: content,
      timestamp: params[:timestamp] || DateTime.utc_now(),
      phase: state.current_phase
    }

    new_transcript = [entry | (state.transcript || [])]
    new_phase_messages = [entry | (state.phase_messages || [])]

    # Check for notable quotes
    {new_quotes, quote_signals} = maybe_tag_quote(entry, state)

    # Publish quote signals
    Enum.each(quote_signals, &InterviewBus.publish/1)

    {:ok, %{
      transcript: new_transcript,
      phase_messages: new_phase_messages,
      quotes: new_quotes
    }}
  end

  defp maybe_tag_quote(entry, state) do
    quote_config = (state.config || %{})[:quote_detection] || %{}
    min_length = quote_config[:min_length] || 200

    cond do
      String.length(entry.content) > min_length ->
        tag_quote(entry, ["substantive"], state)

      contains_markers?(entry.content, quote_config[:emotional_words] || ~w(love hate afraid excited nervous proud frustrated happy sad angry passionate)) ->
        tag_quote(entry, ["emotional"], state)

      contains_phrases?(entry.content, quote_config[:reflection_phrases] || ["i realized", "i learned", "i discovered", "i understood", "it hit me", "i knew then", "that's when i"]) ->
        tag_quote(entry, ["reflection"], state)

      contains_phrases?(entry.content, quote_config[:key_phrases] || ["the most important", "what matters most", "my purpose", "what drives me", "the turning point", "changed everything"]) ->
        tag_quote(entry, ["insight"], state)

      true ->
        {state.quotes || [], []}
    end
  end

  defp tag_quote(entry, tags, state) do
    quote_entry = %{
      quote: entry.content,
      speaker: entry.role,
      tags: tags,
      phase: entry.phase,
      timestamp: entry.timestamp
    }

    signal = %Jido.Signal{
      type: "observer.record.quote",
      source: "scribe",
      id: Jido.Util.generate_id(),
      data: quote_entry
    }

    {[quote_entry | (state.quotes || [])], [signal]}
  end

  defp contains_markers?(text, words) do
    downcased = String.downcase(text)
    Enum.any?(words, fn word -> String.contains?(downcased, word) end)
  end

  defp contains_phrases?(text, phrases) do
    downcased = String.downcase(text)
    Enum.any?(phrases, fn phrase -> String.contains?(downcased, phrase) end)
  end
end

# =============================================================================
# Action: RecordHostUtterance
# =============================================================================

defmodule InterviewStudio.Agents.Scribe.Actions.RecordHostUtterance do
  @moduledoc "Records a host utterance to the transcript."

  use Jido.Action,
    name: "scribe_record_host_utterance",
    description: "Record host utterance to transcript",
    schema: [
      content: [type: :string, required: true],
      timestamp: [type: :any],
      question_id: [type: :any]
    ]

  @impl true
  def run(params, context) do
    state = context.state

    entry = %{
      role: :host,
      content: params.content || "",
      timestamp: params[:timestamp] || DateTime.utc_now(),
      phase: state.current_phase,
      question_id: params[:question_id]
    }

    {:ok, %{
      transcript: [entry | (state.transcript || [])],
      phase_messages: [entry | (state.phase_messages || [])]
    }}
  end
end

# =============================================================================
# Action: HandlePhaseChange
# =============================================================================

defmodule InterviewStudio.Agents.Scribe.Actions.HandlePhaseChange do
  @moduledoc "Handles phase transitions — generates summary of previous phase."

  use Jido.Action,
    name: "scribe_handle_phase_change",
    description: "Generate phase summary and transition to new phase",
    schema: [
      phase_name: [type: :any, required: true]
    ]

  require Logger

  alias InterviewStudio.InterviewBus

  @impl true
  def run(params, context) do
    state = context.state
    new_phase = params.phase_name || params[:phase_name]

    phase_messages = state.phase_messages || []

    # Generate summary for previous phase if we have messages
    new_state = if phase_messages != [] do
      summary = generate_phase_summary(state.current_phase, phase_messages)
      publish_summary(state.current_phase, summary)

      %{
        phase_summaries: Map.put(state.phase_summaries || %{}, state.current_phase, summary),
        current_phase: new_phase,
        phase_start_time: DateTime.utc_now(),
        phase_messages: []
      }
    else
      %{
        current_phase: new_phase,
        phase_start_time: DateTime.utc_now(),
        phase_messages: []
      }
    end

    Logger.debug("[Scribe] Phase changed to: #{new_phase}")
    {:ok, new_state}
  end

  defp generate_phase_summary(phase, messages) do
    user_messages = Enum.filter(messages, fn m -> m.role == :user end)
    host_messages = Enum.filter(messages, fn m -> m.role == :host end)

    total_user_words = user_messages
    |> Enum.map(fn m -> String.split(m.content) |> length() end)
    |> Enum.sum()

    %{
      phase: phase,
      exchange_count: length(messages),
      user_message_count: length(user_messages),
      host_message_count: length(host_messages),
      user_word_count: total_user_words,
      avg_user_response_length: if(length(user_messages) > 0, do: div(total_user_words, length(user_messages)), else: 0)
    }
  end

  defp publish_summary(phase, summary) do
    signal = %Jido.Signal{
      type: "observer.record.summary",
      source: "scribe",
      id: Jido.Util.generate_id(),
      data: %{
        phase: phase,
        summary: summary,
        timestamp: DateTime.utc_now()
      }
    }
    InterviewBus.publish(signal)
  end
end
