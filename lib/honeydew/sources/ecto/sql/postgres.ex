if Code.ensure_loaded?(Ecto) do
  defmodule Honeydew.EctoSource.SQL.Postgres do
    @moduledoc false

    alias Honeydew.EctoSource
    alias Honeydew.EctoSource.SQL

    @behaviour SQL

    @impl true
    def integer_type do
      :bigint
    end

    @impl true
    def table_name(schema) do
      source = schema.__schema__(:source)
      prefix = schema.__schema__(:prefix)

      if prefix do
        prefix <> "." <> source
      else
        source
      end
    end

    @impl true
    def ready do
      SQL.far_in_the_past()
      |> timestamp_in_msecs
      |> msecs_ago
    end

    @impl true
    def delay_ready(state) do
      "UPDATE #{state.table}
      SET #{state.lock_field} = (#{ready()} + $1 * 1000),
          #{state.private_field} = $2
      WHERE #{state.key_field} = $3"
    end

    @impl true
    def reserve(state) do
      "UPDATE #{state.table}
      SET #{state.lock_field} = #{reserve_at(state)}
      WHERE id = (
        SELECT id
        FROM #{state.table}
        WHERE #{state.lock_field} BETWEEN 0 AND #{ready()}
        ORDER BY #{state.lock_field}, #{state.key_field}
        LIMIT 1
        FOR UPDATE SKIP LOCKED
      )
      RETURNING #{state.key_field}, #{state.private_field}"
    end

    @impl true
    def cancel(state) do
      "UPDATE #{state.table}
      SET #{state.lock_field} = NULL
      WHERE
        id = $1
      RETURNING #{state.lock_field}"
    end

    @impl true
    def status(state) do
      "SELECT COUNT(#{state.lock_field}) AS count,
              COUNT(*) FILTER (WHERE #{state.lock_field} = #{EctoSource.abandoned()}) AS abandoned,

              COUNT(*) FILTER (WHERE #{state.lock_field} BETWEEN 0 AND #{ready()}) AS ready,

              COUNT(*) FILTER (WHERE #{ready()} < #{state.lock_field} AND #{state.lock_field} < #{stale_at()}) AS delayed,

              COUNT(*) FILTER (WHERE #{stale_at()} <= #{state.lock_field} AND #{state.lock_field} < #{now()}) AS stale,

              COUNT(*) FILTER (WHERE #{now()} < #{state.lock_field} AND #{state.lock_field} <= #{reserve_at(state)}) AS in_progress
      FROM #{state.table}"
    end

    @impl true
    def reset_stale(state) do
      "UPDATE #{state.table}
      SET #{state.lock_field} = DEFAULT,
          #{state.private_field} = DEFAULT
      WHERE
          #{stale_at()} < #{state.lock_field}
          AND
          #{state.lock_field} < #{now()}"
    end

    @impl true
    def filter(state, :abandoned) do
      "SELECT id FROM #{state.table} WHERE #{state.lock_field} = #{EctoSource.abandoned()}"
    end

    def reserve_at(state) do
      "#{now()} + #{state.stale_timeout}"
    end

    def stale_at do
      time_in_msecs("(NOW() - INTERVAL '5 year')")
    end

    defp msecs_ago(msecs) do
      "#{now()} - #{msecs}"
    end

    def now do
      time_in_msecs("NOW()")
    end

    defp timestamp_in_msecs(time) do
      time_in_msecs("timestamp '#{time}'")
    end

    defp time_in_msecs(time) do
      "(CAST(EXTRACT(epoch from #{time}) * 1000 AS BIGINT))"
    end
  end
end
