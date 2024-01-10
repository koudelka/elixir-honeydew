#
# The goal of this module is to lamprey a queue onto an existing ecto schema with as few requirements and as little
# disruption as possible. It adds two fields to the schema, a "lock" field and a "private" field.
#
# The lock field is an integer overloaded with three jobs:
#  1. Acts as a lock, to ensure that only one worker is processing the job at a time, no matter how many nodes are running
#     copies of the queue. It expires after a configurable period of time (the queue process or entire node crashed).
#  2. Indicates the status of the job, it can be either:
#     - "ready", between zero and SQL.ready()
#     - "delayed", between SQL.ready() and the beginning of the stale window
#     - "in progress", from now until now + stale_timeout
#     - "stale", within a year ago ago from now
#     - "abandoned", -1
#     - "finished", nil
#  3. Indicate the order in which jobs should be processed.
#
#      unix epoch zero
#             |<-------- ~ 24+ yrs ------->|<----- ~ 18 yrs ---->|<--- 5 yrs -->|<------- stale_timeout ------->|
#             |<---------- ready ----------|<------ delayed -----|              |                               |
#             |                            |                     |<--- stale ---|<-------- in progress ---------|
# time -------0----------------------------|------------------------------------|-------------------------------|---->
#            ^                             ^                                    ^                               ^
#       abandoned(-1)                  SQL.ready()                             now                           reserve()
#                                 now - far_in_the_past()                                              now + stale_timeout
#
# The private field is a simple binary field that contains an erlang term, it's used for data that needs to be
# persisted between job attempts, specificaly, it's the "failure_private" contents of the job.
#
#
# As the main objective is to minimize disruption, I wanted the default values for the additional fields to be set
# statically in the migration, rather than possibly interfering with the user's schema validations on save etc...
# The only runtime configuration the user should set is the `stale_timeout`, which should be the maximum expected
# time that a job will take until it should be retried.
#

#
# This module is tested and dialyzed via the included test project in examples/ecto_poll_queue
#
if Code.ensure_loaded?(Ecto) do
  defmodule Honeydew.EctoSource do
    @moduledoc false

    require Logger
    alias Honeydew.Job
    alias Honeydew.PollQueue
    alias Honeydew.PollQueue.State, as: PollQueueState
    alias Honeydew.EctoSource.State
    alias Honeydew.Queue.State, as: QueueState

    @behaviour PollQueue

    @reset_stale_interval 5 * 60 * 1_000 # five minutes in msecs

    @abandoned -1
    def abandoned, do: @abandoned

    @impl true
    def init(queue, args) do
      schema = Keyword.fetch!(args, :schema)
      repo = Keyword.fetch!(args, :repo)
      sql = Keyword.fetch!(args, :sql)
      stale_timeout = args[:stale_timeout] * 1_000
      reset_stale_interval = @reset_stale_interval # held in state so tests can change it

      table = sql.table_name(schema)

      key_fields = schema.__schema__(:primary_key)

      task_fn =
        schema.__info__(:functions)
        |> Enum.member?({:honeydew_task, 2})
        |> if do
             &schema.honeydew_task/2
           else
             fn(id, _queue) -> {:run, [id]} end
           end

      run_if = args[:run_if]

      reset_stale(reset_stale_interval)

      {:ok, %State{schema: schema,
                   repo: repo,
                   sql: sql,
                   table: table,
                   key_fields: key_fields,
                   lock_field: field_name(queue, :lock),
                   private_field: field_name(queue, :private),
                   task_fn: task_fn,
                   queue: queue,
                   stale_timeout: stale_timeout,
                   reset_stale_interval: reset_stale_interval,
                   run_if: run_if}}
    end

    # lock a row for processing
    @impl true
    def reserve(%State{queue: queue, schema: schema, repo: repo, sql: sql, private_field: private_field, task_fn: task_fn} = state) do
      try do
        state
        |> sql.reserve
        |> repo.query([])
      rescue e in DBConnection.ConnectionError ->
        {:error, e}
      end
      |> case do
        {:ok, %{num_rows: 1, rows: [[dumped_private | dumped_key_values]]}} ->
          # convert key and private_field from db representation to schema's type
          private = load_field(schema, repo, private_field, dumped_private)

          loaded_keys = load_keys(state, dumped_key_values)

          # if there's only one primary key, just pass the value, otherwise pass the list of compound key values
          job =
            loaded_keys
            |> case do
                 [{_single_key, value}] -> value
                 other -> other
               end
            |> task_fn.(queue)
            |> Job.new(queue)
            |> struct(failure_private: private)

          {{:value, {loaded_keys, job}}, state}

        {:ok, %{num_rows: 0}} ->
          {:empty, state}

        {:error, error} ->
          Logger.warning("[Honeydew] Ecto queue '#{inspect queue}' couldn't poll for jobs because #{inspect error}")
          {:empty, state}
      end
    end

    @impl true
    # acked without completing, either moved or abandoned
    def ack(%Job{private: key_fields, completed_at: nil}, state) do
      finalize(key_fields, @abandoned, nil, state)
    end

    @impl true
    def ack(%Job{private: key_fields}, state) do
      finalize(key_fields, nil, nil, state)
    end

    @impl true
    def nack(%Job{private: key_values, failure_private: private, delay_secs: delay_secs}, %State{sql: sql,
                                                                                                        repo: repo,
                                                                                                        schema: schema,
                                                                                                        private_field: private_field} = state) do
      dumped_keys = dump_keys(state, key_values)

      {:ok, private} = dump_field(schema, repo, private_field, private)

      {:ok, %{num_rows: 1}} =
        state
        |> sql.delay_ready
        |> repo.query([delay_secs, private | dumped_keys])

      state
    end

    @impl true
    # handles the case where Honeydew.cancel/2 is called with just a single primary key id
    def cancel(%Job{private: id}, state) when not is_list(id), do: cancel(%Job{private: [id: id]}, state)

    # handles the case where Honeydew.cancel/2 is called with a compound key
    def cancel(%Job{private: key_values}, %State{repo: repo, sql: sql} = state) do
      dumped_keys = dump_keys(state, key_values)

      state
      |> sql.cancel
      |> repo.query(dumped_keys)
      |> case do
           {:ok, %{num_rows: 1}} ->
             {:ok, state}
           {:ok, %{num_rows: 0}} ->
             {{:error, :not_found}, state}
         end
    end

    @impl true
    def status(%State{repo: repo, sql: sql} = state) do
      {:ok, %{num_rows: 1, columns: columns, rows: [values]}} =
        state
        |> sql.status
        |> repo.query([])

      columns
      |> Enum.map(&String.to_atom/1)
      |> Enum.zip(values)
      |> Enum.into(%{})
    end

    @impl true
    def filter(%State{repo: repo, sql: sql, queue: queue} = state, filter) do
      {:ok, %{rows: rows}} =
        state
        |> sql.filter(filter)
        |> repo.query([])

      Enum.map(rows, fn key_field_values ->
        %Job{queue: queue,
             private: load_keys(state, key_field_values)}
      end)
    end

    @impl true
    def handle_info(:__reset_stale__, %QueueState{private: %PollQueueState{source: {__MODULE__, %State{sql: sql,
                                                                                                       repo: repo,
                                                                                                       reset_stale_interval: reset_stale_interval} = state}}} = queue_state) do
      {:ok, _} =
        state
        |> sql.reset_stale
        |> repo.query([])

      reset_stale(reset_stale_interval)

      {:noreply, queue_state}
    end

    def handle_info(msg, queue_state) do
      Logger.warning("[Honeydew] Queue #{inspect(self())} received unexpected message #{inspect(msg)}")

      {:noreply, queue_state}
    end

    def field_name(queue, name) do
      :"honeydew_#{Honeydew.table_name(queue)}_#{name}"
    end

    defp reset_stale(reset_stale_interval) do
      {:ok, _} = :timer.send_after(reset_stale_interval, :__reset_stale__)
    end

    defp finalize(key_fields, lock, private, state) do
      import Ecto.Query

      from(s in state.schema,
        where: ^key_fields,
        update: [set: ^[{state.lock_field, lock}, {state.private_field, private}]])
      |> state.repo.update_all([]) # avoids touching auto-generated fields

      state
    end

    defp dump_field(schema, repo, field, value) do
      type = schema.__schema__(:type, field)
      Ecto.Type.adapter_dump(repo.__adapter__(), type, value)
    end

    defp load_field(schema, repo, field, dumped_value) do
      %^schema{^field => value} = repo.load(schema, %{field => dumped_value})
      value
    end

    defp dump_keys(%State{repo: repo, schema: schema}, key_values) do
      Enum.map(key_values, fn {key_field, dumped_value} ->
        {:ok, value} = dump_field(schema, repo, key_field, dumped_value)
        value
      end)
    end

    defp load_keys(%State{repo: repo, schema: schema, key_fields: key_fields}, key_values) do
      key_fields
      |> Enum.zip(key_values)
      |> Enum.into(%{})
      |> Enum.map(fn {key_field, dumped_value} ->
        key_value = load_field(schema, repo, key_field, dumped_value)
        {key_field, key_value}
      end)
    end
  end
end
