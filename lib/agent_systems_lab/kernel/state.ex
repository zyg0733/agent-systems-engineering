defmodule AgentSystemsLab.Kernel.State do
  @moduledoc """
  The complete in-memory state of a single run.

  This struct is a value, not a process. All changes go through
  `AgentSystemsLab.Kernel.dispatch/2` or `AgentSystemsLab.Kernel.apply_event/2`.
  An unresolved operation remains recorded if its run is cancelled or fails;
  terminating a run does not claim to undo a tool's external effects.
  """

  @type status ::
          :queued | :running | :waiting_tool | :blocked | :succeeded | :failed | :cancelled
  @type operation_status :: :pending | :ok | :error | :unknown
  @type operation :: %{
          operation_id: String.t(),
          tool: String.t(),
          arguments: map(),
          status: operation_status(),
          result: term()
        }

  @type t :: %__MODULE__{
          run_id: String.t(),
          status: status(),
          seq: non_neg_integer(),
          turn_count: non_neg_integer(),
          max_turns: pos_integer(),
          input: String.t() | nil,
          output: String.t() | nil,
          operations: %{optional(String.t()) => operation()},
          pending_operation_id: String.t() | nil,
          terminal_reason: term()
        }

  @enforce_keys [:run_id, :max_turns]
  defstruct run_id: nil,
            status: :queued,
            seq: 0,
            turn_count: 0,
            max_turns: 4,
            input: nil,
            output: nil,
            operations: %{},
            pending_operation_id: nil,
            terminal_reason: nil
end
