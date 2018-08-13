defmodule Honeydew.EctoPollQueue do
  alias Honeydew.PollQueue
  alias Honeydew.EctoSource

  @type queue_name :: Honeydew.queue_name()

  @type ecto_poll_queue_spec_opt ::
    Honeydew.queue_spec_opt |
    {:schema, module} |
    {:repo, module} |
    {:poll_interval, pos_integer} |
    {:stale_timeout, pos_integer}

  @doc """
  Creates a supervision spec for an Ecto Poll Queue.

  In addition to the arguments from `queue_spec/4`:

  You *must* provide:

  - `repo`: is your Ecto.Repo module
  - `schema`: is your Ecto.Schema module

  You may provide:

  - `poll_interval`: is how often Honeydew will poll your database when the queue is silent, in seconds (default: 10)
  - `stale_timeout`: is the amount of time a job can take before it risks retry, in seconds (default: 300)

  For example:

  - `{Honeydew.Queues, [:classify_photos, repo: MyApp.Repo, schema: MyApp.Photo]}`
  - `{Honeydew.Queues, [:classify_photos, repo: MyApp.Repo, schema: MyApp.Photo, failure_mode: {Honeydew.Retry, times: 3}]}`

  """

  def validate_args!(args) do
    PollQueue.validate_args!(args)
    validate_module_loaded!(args, :schema)
    validate_module_loaded!(args, :repo)
    validate_stale_timeout!(args[:stale_timeout])
  end

  defp validate_module_loaded!(args, type) do
    module = Keyword.get(args, type)

    unless Code.ensure_loaded?(module) do
      raise module_not_loaded_error(module, type)
    end
  end

  defp validate_stale_timeout!(interval) when is_integer(interval), do: :ok
  defp validate_stale_timeout!(nil), do: :ok
  defp validate_stale_timeout!(arg), do: raise invalid_stale_timeout_error(arg)

  defp invalid_stale_timeout_error(argument) do
    "Stale timeout must be an integer number of seconds. You gave #{inspect argument}"
  end

  defp module_not_loaded_error(module, type) do
    "The #{type} module you provided, #{inspect module} couldn't be found"
  end

  def rewrite_opts([name, __MODULE__, args | rest]) do
    {database_override, args} = Keyword.pop(args, :database)

    sql = EctoSource.SQL.module(args[:repo], database_override)

    ecto_source_args =
      args
      |> Keyword.put(:sql, sql)
      |> Keyword.put(:poll_interval, args[:poll_interval] || 10)
      |> Keyword.put(:stale_timeout, args[:stale_timeout] || 300)

    [name, PollQueue, [EctoSource, ecto_source_args] | rest]
  end

  defmodule Schema do
    defmacro honeydew_fields(queue) do
      quote do
        alias Honeydew.EctoSource.ErlangTerm

        unquote(queue)
        |> Honeydew.EctoSource.field_name(:lock)
        |> Ecto.Schema.field(:integer)

        unquote(queue)
        |> Honeydew.EctoSource.field_name(:private)
        |> Ecto.Schema.field(ErlangTerm)
      end
    end
  end

  defmodule Migration do
    defmacro honeydew_fields(queue, opts \\ []) do
      quote do
        require unquote(__MODULE__)
        alias Honeydew.EctoSource.SQL
        alias Honeydew.EctoSource.ErlangTerm
        require SQL

        database = Keyword.get(unquote(opts), :database, nil)

        sql_module =
          :repo
          |> Ecto.Migration.Runner.repo_config(nil)
          |> SQL.module(database)

        unquote(queue)
        |> Honeydew.EctoSource.field_name(:lock)
        |> Ecto.Migration.add(sql_module.integer_type(), default: SQL.ready_fragment(sql_module))

        unquote(queue)
        |> Honeydew.EctoSource.field_name(:private)
        |> Ecto.Migration.add(ErlangTerm.type())
      end
    end

    defmacro honeydew_indexes(table, queue, opts \\ []) do
      quote do
        lock_field = unquote(queue) |> Honeydew.EctoSource.field_name(:lock)
        Ecto.Migration.create(index(unquote(table), [lock_field], unquote(opts)))
      end
    end
  end

end
