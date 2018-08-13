defmodule EctoPollQueueExample.Repo.Migrations.CreatePhotosAndUsers do
  use Ecto.Migration
  import Honeydew.EctoPollQueue.Migration
  import EctoPollQueueExample.User, only: [notify_queue: 0]
  import EctoPollQueueExample.Photo, only: [classify_queue: 0]
  alias Honeydew.EctoSource.ErlangTerm

  def change do
    create table(:photos, primary_key: false) do
      add :tag, :string
      add :should_fail, :boolean
      add :sleep, :integer
      add :from, ErlangTerm.type()

      if Mix.env == :cockroach do
        add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
        honeydew_fields(classify_queue(), database: :cockroachdb)
      else
        add :id, :binary_id, primary_key: true
        honeydew_fields(classify_queue())
      end

      timestamps()
    end
    honeydew_indexes(:photos, classify_queue())

    create table(:users, primary_key: false) do
      add :name, :string
      add :should_fail, :boolean
      add :sleep, :integer
      add :from, ErlangTerm.type()

      if Mix.env == :cockroach do
        add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
        honeydew_fields(notify_queue(), database: :cockroachdb)
      else
        add :id, :binary_id, primary_key: true
        honeydew_fields(notify_queue())
      end

      timestamps()
    end
    honeydew_indexes(:users, notify_queue())
  end
end
