defmodule InterviewStudio.Signals.DecisionAsk do
  @moduledoc """
  Signal emitted by the Director when deciding to ask a question.
  Consumed by the Chat interface.
  """

  use Jido.Signal,
    type: "director.decision.ask",
    schema: [
      question: [type: :string, required: true, doc: "The question to ask"],
      rationale: [type: :string, doc: "Why this question was chosen"],
      source: [type: {:in, [:question_bank, :probe, :synthesis, :followup]}, doc: "Where the question came from"],
      timestamp: [type: {:struct, DateTime}, required: true, doc: "When the decision was made"]
    ]
end
