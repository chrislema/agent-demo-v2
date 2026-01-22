defmodule InterviewStudio.Signals.PhaseCompleted do
  @moduledoc """
  Signal emitted when an interview phase is completed.
  Consumed by the Director and Scribe.
  """

  use Jido.Signal,
    type: "interview.phase.completed",
    schema: [
      phase_name: [
        type: {:in, [:preparation, :opening, :core_questions, :probing, :synthesis, :closing]},
        required: true,
        doc: "The phase being completed"
      ],
      summary: [type: :string, doc: "Summary of what happened in the phase"],
      next_phase: [
        type: {:in, [:opening, :core_questions, :probing, :synthesis, :closing, nil]},
        doc: "The next phase to transition to"
      ],
      timestamp: [type: {:struct, DateTime}, required: true, doc: "When the phase was completed"]
    ]
end
