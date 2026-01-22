defmodule InterviewStudio.Signals.HostUtterance do
  @moduledoc """
  Signal emitted when the Director (interviewer) sends a message.
  Consumed by all observers and the Scribe.
  """

  use Jido.Signal,
    type: "interview.utterance.host",
    schema: [
      content: [type: :string, required: true, doc: "The interviewer's message content"],
      timestamp: [type: {:struct, DateTime}, required: true, doc: "When the message was sent"],
      question_id: [type: :string, doc: "ID of the question if from question bank"]
    ]
end
