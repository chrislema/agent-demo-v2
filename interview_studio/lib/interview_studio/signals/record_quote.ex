defmodule InterviewStudio.Signals.RecordQuote do
  @moduledoc """
  Signal emitted by the Scribe when a notable quote is captured.
  Stored for final output.
  """

  use Jido.Signal,
    type: "observer.record.quote",
    schema: [
      quote: [type: :string, required: true, doc: "The notable quote"],
      speaker: [type: {:in, [:user, :host]}, required: true, doc: "Who said this"],
      tags: [type: {:list, :string}, default: [], doc: "Tags categorizing the quote"],
      phase: [type: :atom, doc: "Which phase this occurred in"],
      timestamp: [type: {:struct, DateTime}, required: true, doc: "When the quote was captured"]
    ]
end
