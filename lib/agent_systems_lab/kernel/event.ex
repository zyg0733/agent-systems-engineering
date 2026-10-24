defmodule AgentSystemsLab.Kernel.Event do
  @moduledoc """
  A versioned fact in a run's strictly ordered history.

  Sequence numbers start at one and are local to `run_id`. Data is validated
  against the event type and current state during replay. A struct alone is not
  proof that an event is valid. This lab keeps events as Elixir terms; it does not
  define a persistent wire format or claim that a history has been authenticated.
  """

  @type type ::
          :run_started
          | :tool_requested
          | :tool_result_recorded
          | :tool_reconciled
          | :run_succeeded
          | :run_failed
          | :run_cancelled

  @type t :: %__MODULE__{
          run_id: String.t(),
          seq: pos_integer(),
          schema_version: pos_integer(),
          type: type(),
          data: map()
        }

  @enforce_keys [:run_id, :seq, :type, :data]
  defstruct [:run_id, :seq, :type, :data, schema_version: 1]
end
