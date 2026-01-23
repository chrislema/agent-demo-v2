defmodule InterviewStudio.Agents.Scribe do
  @moduledoc """
  The Scribe Agent - documents everything.

  Responsibilities:
  - Maintain full transcript with timestamps
  - Tag notable quotes
  - Generate phase summaries
  - Emit RecordQuote and RecordSummary signals

  No LLM required - pure recording and pattern matching.
  """

  use GenServer
  require Logger

  alias InterviewStudio.InterviewBus

  defstruct [
    :session_id,
    :transcript,
    :quotes,
    :phase_summaries,
    :current_phase,
    :phase_start_time,
    :phase_messages
  ]

  # Client API

  def start_link(opts \\ []) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(session_id))
  end

  def get_state(session_id) do
    GenServer.call(via_tuple(session_id), :get_state)
  end

  def get_transcript(session_id) do
    GenServer.call(via_tuple(session_id), :get_transcript)
  end

  def get_quotes(session_id) do
    GenServer.call(via_tuple(session_id), :get_quotes)
  end

  @doc """
  Get a formatted context summary for LLM prompts.
  Includes: phases completed, key quotes, and notable learnings.
  This provides memory across the entire interview without passing full transcript.
  """
  def get_interview_context(session_id) do
    GenServer.call(via_tuple(session_id), :get_interview_context)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    state = %__MODULE__{
      session_id: session_id,
      transcript: [],
      quotes: [],
      phase_summaries: %{},
      current_phase: :preparation,
      phase_start_time: DateTime.utc_now(),
      phase_messages: []
    }

    subscribe_to_signals()

    Logger.info("[Scribe] Started for session #{session_id}")
    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call(:get_transcript, _from, state) do
    {:reply, Enum.reverse(state.transcript), state}
  end

  @impl true
  def handle_call(:get_quotes, _from, state) do
    {:reply, Enum.reverse(state.quotes), state}
  end

  @impl true
  def handle_call(:get_interview_context, _from, state) do
    context = format_interview_context(state)
    {:reply, context, state}
  end

  @impl true
  def handle_info({:signal, signal}, state) do
    new_state = handle_signal(signal, state)
    {:noreply, new_state}
  end

  # Signal handlers

  defp handle_signal(%{type: "interview.utterance.user"} = signal, state) do
    entry = %{
      role: :user,
      content: signal.data.content,
      timestamp: signal.data.timestamp || DateTime.utc_now(),
      phase: state.current_phase
    }

    new_state = %{state |
      transcript: [entry | state.transcript],
      phase_messages: [entry | state.phase_messages]
    }

    # Check for notable quotes
    maybe_tag_quote(entry, new_state)
  end

  defp handle_signal(%{type: "interview.utterance.host"} = signal, state) do
    entry = %{
      role: :host,
      content: signal.data.content,
      timestamp: signal.data.timestamp || DateTime.utc_now(),
      phase: state.current_phase,
      question_id: Map.get(signal.data, :question_id)
    }

    new_state = %{state |
      transcript: [entry | state.transcript],
      phase_messages: [entry | state.phase_messages]
    }

    new_state
  end

  defp handle_signal(%{type: "interview.phase.entered"} = signal, state) do
    new_phase = signal.data.phase_name

    # Generate summary for previous phase if we have messages
    new_state = if state.phase_messages != [] do
      summary = generate_phase_summary(state.current_phase, state.phase_messages)
      publish_summary(state.current_phase, summary)

      %{state |
        phase_summaries: Map.put(state.phase_summaries, state.current_phase, summary),
        current_phase: new_phase,
        phase_start_time: DateTime.utc_now(),
        phase_messages: []
      }
    else
      %{state |
        current_phase: new_phase,
        phase_start_time: DateTime.utc_now(),
        phase_messages: []
      }
    end

    Logger.debug("[Scribe] Phase changed to: #{new_phase}")
    new_state
  end

  defp handle_signal(_signal, state), do: state

  # Quote detection

  defp maybe_tag_quote(entry, state) do
    cond do
      # Long, substantive responses often contain good quotes
      String.length(entry.content) > 200 ->
        tag_quote(entry, ["substantive"], state)

      # Emotional language
      contains_emotional_language?(entry.content) ->
        tag_quote(entry, ["emotional"], state)

      # Self-reflection
      contains_self_reflection?(entry.content) ->
        tag_quote(entry, ["reflection"], state)

      # Key phrases
      contains_key_phrases?(entry.content) ->
        tag_quote(entry, ["insight"], state)

      true ->
        state
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

    # Publish quote signal
    publish_quote(quote_entry)

    %{state | quotes: [quote_entry | state.quotes]}
  end

  defp contains_emotional_language?(text) do
    emotional_words = ~w(love hate afraid excited nervous proud frustrated happy sad angry passionate)
    downcased = String.downcase(text)
    Enum.any?(emotional_words, fn word -> String.contains?(downcased, word) end)
  end

  defp contains_self_reflection?(text) do
    reflection_phrases = ["i realized", "i learned", "i discovered", "i understood", "it hit me", "i knew then", "that's when i"]
    downcased = String.downcase(text)
    Enum.any?(reflection_phrases, fn phrase -> String.contains?(downcased, phrase) end)
  end

  defp contains_key_phrases?(text) do
    key_phrases = ["the most important", "what matters most", "my purpose", "what drives me", "the turning point", "changed everything"]
    downcased = String.downcase(text)
    Enum.any?(key_phrases, fn phrase -> String.contains?(downcased, phrase) end)
  end

  # Summary generation (simple, no LLM)

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

  # Signal publishing

  defp publish_quote(quote_entry) do
    signal = %Jido.Signal{
      type: "observer.record.quote",
      source: "scribe",
      id: Jido.Util.generate_id(),
      data: quote_entry
    }
    InterviewBus.publish(signal)
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

  defp subscribe_to_signals do
    InterviewBus.subscribe("interview.utterance.**")
    InterviewBus.subscribe("interview.phase.**")
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
    state.phase_summaries
    |> Enum.map(fn {phase, summary} ->
      %{
        phase: phase,
        exchanges: summary.exchange_count,
        user_engagement: if(summary.avg_user_response_length > 30, do: :high, else: :low)
      }
    end)
  end

  defp format_key_quotes(state) do
    state.quotes
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
    # Extract key facts from user messages
    user_messages = state.transcript
    |> Enum.reverse()
    |> Enum.filter(fn e -> e.role == :user end)
    |> Enum.map(fn e -> e.content end)

    %{
      total_exchanges: length(state.transcript),
      user_messages: length(user_messages),
      phases_visited: Map.keys(state.phase_summaries)
    }
  end

  # Build formatted text suitable for LLM system prompt
  defp build_context_text(state) do
    quotes_text = state.quotes
    |> Enum.reverse()
    |> Enum.take(8)
    |> Enum.map(fn q ->
      tags = Enum.join(q.tags, ", ")
      "- [#{tags}] \"#{String.slice(q.quote, 0, 150)}...\""
    end)
    |> Enum.join("\n")

    phases_text = state.phase_summaries
    |> Enum.map(fn {phase, summary} ->
      engagement = if summary.avg_user_response_length > 30, do: "engaged", else: "brief"
      "- #{phase}: #{summary.exchange_count} exchanges (#{engagement} responses)"
    end)
    |> Enum.join("\n")

    # Extract key learnings from longer user responses
    key_learnings = state.transcript
    |> Enum.reverse()
    |> Enum.filter(fn e -> e.role == :user and String.length(e.content) > 100 end)
    |> Enum.take(5)
    |> Enum.map(fn e ->
      # Extract first sentence or first 150 chars as a "learning"
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
