defmodule InterviewStudio.Signals.InsightPattern do
  @moduledoc """
  Signal emitted by the Story Analyst when a pattern is detected across responses.
  Consumed by the Director.
  """

  use Jido.Signal,
    type: "observer.insight.pattern",
    schema: [
      pattern_type: [type: :string, required: true, doc: "Type of pattern detected"],
      instances: [type: {:list, :string}, required: true, doc: "Specific instances of the pattern"],
      significance: [type: :string, required: true, doc: "Why this pattern matters"],
      timestamp: [type: {:struct, DateTime}, required: true, doc: "When the pattern was detected"]
    ]
end
