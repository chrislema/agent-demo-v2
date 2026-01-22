defmodule InterviewStudio.Signals.InsightTheme do
  @moduledoc """
  Signal emitted by the Story Analyst when a theme is identified.
  Consumed by the Director and Scribe.
  """

  use Jido.Signal,
    type: "observer.insight.theme",
    schema: [
      theme: [type: :string, required: true, doc: "The identified theme"],
      evidence: [type: {:list, :string}, required: true, doc: "Supporting evidence from the conversation"],
      confidence: [type: :float, required: true, doc: "Confidence score 0.0-1.0"],
      timestamp: [type: {:struct, DateTime}, required: true, doc: "When the theme was identified"]
    ]
end
