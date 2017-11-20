defmodule Honeydew.FailureMode.Move do
  @moduledoc """
  Instructs Honeydew to move a job to another queue on failure.

  ## Example

  Move this job to the `:failed` queue, on failure.

      Honeydew.queue_spec(:my_queue, failure_mode: {#{inspect __MODULE__}, [queue: :failed]})
  """

  alias Honeydew.Job

  require Logger

  @behaviour Honeydew.FailureMode

  @impl true
  def handle_failure(%Job{queue: queue, from: from} = job, reason, [queue: to_queue]) do
    Logger.info "Job failed because #{inspect reason}, moving to #{inspect to_queue}: #{inspect job}"

    # tell the queue that that job can be removed.
    queue
    |> Honeydew.get_queue
    |> GenServer.cast({:ack, job})

    {:ok, job} =
      %{job | queue: to_queue}
      |> Honeydew.enqueue

    # send the error to the awaiting process, if necessary
    with {owner, _ref} <- from,
      do: send(owner, %{job | result: {:moved, reason}})
  end
end
