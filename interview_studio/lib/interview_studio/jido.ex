defmodule InterviewStudio.Jido do
  @moduledoc """
  Jido Instance for Interview Studio.

  Provides the core Jido infrastructure: TaskSupervisor, Registry,
  and DynamicSupervisor for agent lifecycle management.
  """

  use Jido, otp_app: :interview_studio
end
