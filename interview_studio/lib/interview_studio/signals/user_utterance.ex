defmodule InterviewStudio.Signals.UserUtterance do
  @moduledoc """
  Signal emitted when the user sends a message in the interview.
  Consumed by all observers and the Director.
  """

  use Jido.Signal,
    type: "interview.utterance.user",
    schema: [
      content: [type: :string, required: true, doc: "The user's message content"],
      timestamp: [type: {:struct, DateTime}, required: true, doc: "When the message was sent"],
      phase_context: [type: :atom, doc: "Current interview phase when message was sent"]
    ]
end
