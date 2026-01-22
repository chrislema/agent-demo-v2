defmodule InterviewStudio.Signals.RecordSummary do
  @moduledoc """
  Signal emitted by the Scribe with phase summaries.
  Consumed by the Director.
  """

  use Jido.Signal,
    type: "observer.record.summary",
    schema: [
      phase: [
        type: {:in, [:preparation, :opening, :core_questions, :probing, :synthesis, :closing]},
        required: true,
        doc: "The phase being summarized"
      ],
      summary_text: [type: :string, required: true, doc: "Summary of the phase"],
      key_points: [type: {:list, :string}, default: [], doc: "Key points from the phase"],
      timestamp: [type: {:struct, DateTime}, required: true, doc: "When the summary was generated"]
    ]
end
