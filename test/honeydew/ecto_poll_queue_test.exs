defmodule Honeydew.EctoPollQueueTest do
  use ExUnit.Case, async: true
  alias Honeydew.EctoPollQueue
  alias Honeydew.EctoSource.SQL
  alias Honeydew.FailureMode.Abandon

  defmodule PseudoRepo do
    def __adapter__ do
      Ecto.Adapters.Postgres
    end
  end

  defmodule UnsupportedRepo do
    def __adapter__ do
      Ecto.Adapters.ButtDB
    end
  end

  describe "child_spec/1" do
    test "provides a supervision spec" do
      queue = :erlang.unique_integer

      spec = EctoPollQueue.child_spec([queue,
                                       schema: :my_schema,
                                       repo: PseudoRepo,
                                       poll_interval: 123,
                                       stale_timeout: 456,
                                       failure_mode: {Abandon, []}])

      assert spec == %{
        id: {:queue, queue},
        type: :supervisor,
        start: {Honeydew.QueueSupervisor, :start_link,
                [queue,
                 Honeydew.PollQueue, [Honeydew.EctoSource, [schema: :my_schema,
                                                            repo: PseudoRepo,
                                                            sql: SQL.Postgres,
                                                            poll_interval: 123,
                                                            stale_timeout: 456]],
                 1,
                 {Honeydew.Dispatcher.LRU, []},
                 {Abandon, []},
                 nil, false]}
      }
    end

    test "defaults" do
      queue = :erlang.unique_integer
      spec = EctoPollQueue.child_spec([queue, schema: :my_schema, repo: PseudoRepo])

      assert spec == %{
        id: {:queue, queue},
        type: :supervisor,
        start: {Honeydew.QueueSupervisor, :start_link,
                [queue,
                 Honeydew.PollQueue, [Honeydew.EctoSource, [schema: :my_schema,
                                                            repo: PseudoRepo,
                                                            sql: SQL.Postgres,
                                                            poll_interval: 10,
                                                            stale_timeout: 300]],
                 1,
                 {Honeydew.Dispatcher.LRU, []},
                 {Abandon, []},
                 nil, false]}
      }
    end

    test "cockroachdb" do
      queue = :erlang.unique_integer
      spec = EctoPollQueue.child_spec([queue, schema: :my_schema, repo: PseudoRepo, database: :cockroachdb])


      assert spec == %{
        id: {:queue, queue},
        type: :supervisor,
        start: {Honeydew.QueueSupervisor, :start_link,
                [queue,
                 Honeydew.PollQueue, [Honeydew.EctoSource, [schema: :my_schema,
                                                            repo: PseudoRepo,
                                                            sql: SQL.Cockroach,
                                                            poll_interval: 10,
                                                            stale_timeout: 300]],
                 1,
                 {Honeydew.Dispatcher.LRU, []},
                 {Abandon, []},
                 nil, false]}
      }
    end

    test "should raise when database isn't supported" do
      queue = :erlang.unique_integer

      assert_raise ArgumentError, fn ->
        EctoPollQueue.child_spec([queue, schema: :abc, repo: UnsupportedRepo, queue: :abc])
      end
    end

    test "should raise when :queue argument provided" do
      queue = :erlang.unique_integer

      assert_raise ArgumentError, fn ->
        EctoPollQueue.child_spec([queue, schema: :abc, repo: :abc, queue: :abc])
      end
    end

    test "should raise when :repo or :schema arguments aren't provided" do
      queue = :erlang.unique_integer

      assert_raise KeyError, fn ->
        EctoPollQueue.child_spec([queue, repo: :abc])
      end

      assert_raise KeyError, fn ->
        EctoPollQueue.child_spec([queue, schema: :abc])
      end
    end
  end

end
