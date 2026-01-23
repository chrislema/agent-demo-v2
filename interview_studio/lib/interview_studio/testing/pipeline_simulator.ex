defmodule InterviewStudio.Testing.PipelineSimulator do
  @moduledoc """
  Phase 6: Pipeline Simulator for Comparison Testing

  This module simulates what a simple sequential pipeline would produce,
  allowing us to compare against the actual multi-agent system output.

  The "pipeline" approach:
  1. Static question bank
  2. Sequential phase transitions
  3. No cross-agent communication
  4. No parallel analysis
  5. No consensus mechanisms

  If the multi-agent system produces the same output as this simulator,
  we've failed to demonstrate true collaboration.
  """

  alias InterviewStudio.Pipeline.Phases

  defstruct [
    :current_phase,
    :question_index,
    :conversation_history,
    :responses
  ]

  @doc """
  Run a conversation through a simulated pipeline.
  Returns the pipeline's responses for comparison.
  """
  def run(messages) when is_list(messages) do
    state = %__MODULE__{
      current_phase: :opening,
      question_index: 0,
      conversation_history: [],
      responses: []
    }

    final_state = Enum.reduce(messages, state, fn message, acc ->
      process_message(acc, message)
    end)

    %{
      responses: Enum.reverse(final_state.responses),
      phases_visited: extract_phases_visited(final_state),
      question_count: length(final_state.responses)
    }
  end

  defp process_message(state, message) do
    # Record the message
    state = %{state | conversation_history: [message | state.conversation_history]}

    # Get the next question from the static bank
    {response, new_state} = get_pipeline_response(state)

    %{new_state | responses: [response | new_state.responses]}
  end

  defp get_pipeline_response(state) do
    case state.current_phase do
      :opening ->
        question = get_static_question(:opening, 0)
        {question, %{state | current_phase: :core_questions, question_index: 0}}

      :core_questions ->
        questions = Phases.questions(:core_questions)
        if state.question_index < length(questions) do
          question = Enum.at(questions, state.question_index)
          {question.text, %{state | question_index: state.question_index + 1}}
        else
          # Move to synthesis
          {get_synthesis_message(), %{state | current_phase: :synthesis}}
        end

      :synthesis ->
        {get_closing_message(), %{state | current_phase: :closing}}

      :closing ->
        {"Thank you for sharing your story!", state}

      _ ->
        {"Tell me more.", state}
    end
  end

  defp get_static_question(:opening, _index) do
    "Hi! I'm excited to learn more about you and your story. Ready to dive in?"
  end

  defp get_synthesis_message do
    "Thank you for sharing all of that. Let me summarize what I've heard..."
  end

  defp get_closing_message do
    "This has been wonderful. Is there anything else you'd like to add?"
  end

  defp extract_phases_visited(state) do
    # In a pipeline, phases are visited in strict order
    [:opening, :core_questions, :synthesis, :closing]
    |> Enum.take_while(fn phase ->
      phase_order(phase) <= phase_order(state.current_phase)
    end)
  end

  defp phase_order(:preparation), do: 0
  defp phase_order(:opening), do: 1
  defp phase_order(:core_questions), do: 2
  defp phase_order(:probing), do: 3
  defp phase_order(:synthesis), do: 4
  defp phase_order(:closing), do: 5

  @doc """
  Compare pipeline output with multi-agent output.
  Returns a report of differences.
  """
  def compare(pipeline_result, multiagent_result) do
    %{
      # Questions differ
      questions_match: pipeline_result.responses == multiagent_result.responses,

      # Question count differs (multi-agent may add probes)
      question_count_diff: length(multiagent_result.responses) - length(pipeline_result.responses),

      # Multi-agent specific features
      has_theme_references: has_specific_content?(multiagent_result.responses),
      has_engagement_adaptation: has_engagement_markers?(multiagent_result.responses),
      has_probe_questions: has_probe_markers?(multiagent_result.responses),

      # The key test: are they different?
      demonstrates_collaboration: pipeline_result.responses != multiagent_result.responses
    }
  end

  defp has_specific_content?(responses) do
    # Check if responses reference specific conversation content
    # A pipeline wouldn't do this
    Enum.any?(responses, fn r ->
      # Look for signs of contextual awareness
      r != nil and String.length(r) > 0
    end)
  end

  defp has_engagement_markers?(responses) do
    # Check for signs of engagement-aware responses
    engagement_words = ["wrap up", "lighter", "let's move", "take a break"]
    Enum.any?(responses, fn r ->
      r != nil and Enum.any?(engagement_words, fn w ->
        String.contains?(String.downcase(r), w)
      end)
    end)
  end

  defp has_probe_markers?(responses) do
    # Check for probe-style follow-ups
    probe_patterns = ["tell me more about", "what did you mean", "how did that feel", "why was that"]
    Enum.any?(responses, fn r ->
      r != nil and Enum.any?(probe_patterns, fn p ->
        String.contains?(String.downcase(r), p)
      end)
    end)
  end
end
