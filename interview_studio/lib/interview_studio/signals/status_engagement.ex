defmodule InterviewStudio.Signals.StatusEngagement do
  @moduledoc """
  Signal emitted by the Engagement Monitor when engagement level changes.
  Consumed by the Director.
  """

  use Jido.Signal,
    type: "observer.status.engagement",
    schema: [
      level: [
        type: {:in, [:high, :medium, :low, :critical]},
        required: true,
        doc: "Current engagement level"
      ],
      indicators: [type: {:list, :string}, required: true, doc: "What signals indicate this level"],
      recommendation: [type: :string, doc: "Suggested action based on engagement"],
      trend: [type: {:in, [:rising, :stable, :falling]}, doc: "Direction of engagement"],
      timestamp: [type: {:struct, DateTime}, required: true, doc: "When the status was assessed"]
    ]
end
