defmodule InterviewStudio.Signals.DecisionTransition do
  @moduledoc """
  Signal emitted by the Director when deciding to transition phases.
  Consumed by the Pipeline FSM.
  """

  use Jido.Signal,
    type: "director.decision.transition",
    schema: [
      to_phase: [
        type: {:in, [:opening, :core_questions, :probing, :synthesis, :closing]},
        required: true,
        doc: "The phase to transition to"
      ],
      reason: [type: :string, required: true, doc: "Why this transition is happening"],
      timestamp: [type: {:struct, DateTime}, required: true, doc: "When the decision was made"]
    ]
end
