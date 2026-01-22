defmodule InterviewStudio.Signals.PhaseEntered do
  @moduledoc """
  Signal emitted when the interview enters a new phase.
  Consumed by all observers and the Director.
  """

  use Jido.Signal,
    type: "interview.phase.entered",
    schema: [
      phase_name: [
        type: {:in, [:preparation, :opening, :core_questions, :probing, :synthesis, :closing]},
        required: true,
        doc: "The phase being entered"
      ],
      timestamp: [type: {:struct, DateTime}, required: true, doc: "When the phase was entered"],
      context: [type: :map, default: %{}, doc: "Additional context for the phase"]
    ]
end
