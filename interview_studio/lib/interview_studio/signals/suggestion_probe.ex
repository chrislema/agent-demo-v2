defmodule InterviewStudio.Signals.SuggestionProbe do
  @moduledoc """
  Signal emitted by the Probe Coach when an opportunity to dig deeper is identified.
  Consumed by the Director.
  """

  use Jido.Signal,
    type: "observer.suggestion.probe",
    schema: [
      topic: [type: :string, required: true, doc: "The topic to probe deeper on"],
      rationale: [type: :string, required: true, doc: "Why this probe is valuable"],
      suggested_question: [type: :string, required: true, doc: "A suggested follow-up question"],
      priority: [type: {:in, [:high, :medium, :low]}, default: :medium, doc: "Priority of this probe"],
      timestamp: [type: {:struct, DateTime}, required: true, doc: "When the probe was suggested"]
    ]
end
