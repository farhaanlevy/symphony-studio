# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Studio.Intent.Store do
  @moduledoc """
  Owner-local, atomically replaced JSON storage for Intent Service documents.

  Each project and intent has one canonical document. Intent events are
  append-only values inside that document; a successful command replaces the
  complete document through a same-directory temporary file and rename. The
  public service API is deliberately independent of this representation so a
  later SQLite store can implement the same boundary.
  """

  alias SymphonyElixir.Studio.Intent.Canonical

  @schema_version 1
  @id_pattern ~r/\A[a-z][a-z0-9_]{7,95}\z/

  @enforce_keys [:root]
  defstruct [:root]

  @type t :: %__MODULE__{root: String.t()}
  @type error ::
          :invalid_store_options
          | :invalid_store_root
          | :invalid_document_id
          | :not_found
          | :document_conflict
          | :invalid_document
          | :store_unavailable

  @doc "Returns the default owner-local Intent Service data root."
  @spec default_root() :: String.t()
  def default_root do
    case System.get_env("XDG_DATA_HOME") do
      value when is_binary(value) and value != "" ->
        Path.join([value, "symphony-studio", "intent"])

      _unset ->
        Path.join([System.user_home!(), ".local", "share", "symphony-studio", "intent"])
    end
  end

  @doc "Opens or creates an owner-only Intent Service store."
  @spec open(keyword()) :: {:ok, t()} | {:error, error()}
  def open(opts \\ []) do
    with true <- is_list(opts),
         true <- Keyword.keyword?(opts),
         true <- unique_allowed_options?(opts, [:root]),
         root when is_binary(root) <- Keyword.get(opts, :root, default_root()),
         true <- Path.type(root) == :absolute,
         expanded <- Path.expand(root),
         :ok <- ensure_root(expanded) do
      {:ok, %__MODULE__{root: expanded}}
    else
      false -> {:error, :invalid_store_options}
      _invalid -> {:error, :invalid_store_root}
    end
  end

  @doc "Reads one attached project document."
  @spec read_project(t(), String.t()) :: {:ok, map()} | {:error, error()}
  def read_project(%__MODULE__{} = store, project_id) do
    read_document(store, :project, project_id)
  end

  @doc "Stores a project document once, returning the existing exact document on replay."
  @spec put_project(t(), map()) :: {:ok, map(), :created | :existing} | {:error, error()}
  def put_project(%__MODULE__{} = store, %{"project_id" => project_id} = document) do
    with :ok <- validate_document(document, :project, project_id) do
      path = document_path(store, :project, project_id)
      locked(path, fn -> put_project_locked(path, project_id, document) end)
    end
  end

  def put_project(_store, _document), do: {:error, :invalid_document}

  @doc "Reads one intent document."
  @spec read_intent(t(), String.t()) :: {:ok, map()} | {:error, error()}
  def read_intent(%__MODULE__{} = store, intent_id) do
    read_document(store, :intent, intent_id)
  end

  @doc "Creates one intent document without replacing an existing command result."
  @spec create_intent(t(), map()) :: {:ok, map(), :created | :existing} | {:error, error()}
  def create_intent(%__MODULE__{} = store, %{"intent_id" => intent_id} = document) do
    with :ok <- validate_document(document, :intent, intent_id) do
      path = document_path(store, :intent, intent_id)
      locked(path, fn -> create_intent_locked(path, intent_id, document) end)
    end
  end

  def create_intent(_store, _document), do: {:error, :invalid_document}

  @doc "Atomically updates one intent document through an injected reducer."
  @spec update_intent(t(), String.t(), (map() -> {:ok, map(), term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def update_intent(%__MODULE__{} = store, intent_id, reducer)
      when is_function(reducer, 1) do
    with :ok <- validate_id(intent_id) do
      path = document_path(store, :intent, intent_id)
      locked(path, fn -> update_intent_locked(path, intent_id, reducer) end)
    end
  end

  def update_intent(_store, _intent_id, _reducer), do: {:error, :invalid_document}

  @doc "Returns intents currently waiting for admission of an exact Linear issue ID."
  @spec waiting_intents_for_issue(t(), String.t()) :: {:ok, [map()]} | {:error, error()}
  def waiting_intents_for_issue(%__MODULE__{} = store, issue_id)
      when is_binary(issue_id) and issue_id != "" do
    with {:ok, documents} <- list_intents(store) do
      {:ok,
       Enum.filter(documents, fn document ->
         get_in(document, ["start", "status"]) == "waiting_for_admission" and
           get_in(document, ["start", "issue_id"]) == issue_id
       end)}
    end
  end

  def waiting_intents_for_issue(_store, _issue_id), do: {:error, :invalid_document}

  @doc "Lists valid intent documents in deterministic ID order."
  @spec list_intents(t()) :: {:ok, [map()]} | {:error, error()}
  def list_intents(%__MODULE__{} = store) do
    directory = Path.join(store.root, "intents")

    case File.ls(directory) do
      {:ok, names} -> read_intent_names(store, names)
      {:error, :enoent} -> {:ok, []}
      {:error, _reason} -> {:error, :store_unavailable}
    end
  end

  defp put_project_locked(path, project_id, document) do
    case read_path(path, :project, project_id) do
      {:ok, existing} -> compare_project(existing, document)
      {:error, :not_found} -> create_project(path, document)
      {:error, reason} -> {:error, reason}
    end
  end

  defp compare_project(existing, document) do
    if Canonical.digest(existing) == Canonical.digest(document),
      do: {:ok, existing, :existing},
      else: {:error, :document_conflict}
  end

  defp create_project(path, document) do
    case atomic_write(path, document) do
      :ok -> {:ok, document, :created}
      {:error, _reason} -> {:error, :store_unavailable}
    end
  end

  defp create_intent_locked(path, intent_id, document) do
    case read_path(path, :intent, intent_id) do
      {:ok, existing} -> {:ok, existing, :existing}
      {:error, :not_found} -> create_new_intent(path, document)
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_intent_locked(path, intent_id, reducer) do
    with {:ok, current} <- read_path(path, :intent, intent_id),
         {:ok, next, result} <- safe_reduce(reducer, current),
         :ok <- validate_document(next, :intent, intent_id),
         :ok <- maybe_write_changed(path, current, next) do
      {:ok, result}
    end
  end

  defp read_intent_names(store, names) do
    names
    |> Enum.filter(&String.ends_with?(&1, ".json"))
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, &read_intent_name(store, &1, &2))
    |> reverse_documents()
  end

  defp read_intent_name(store, name, {:ok, documents}) do
    intent_id = String.trim_trailing(name, ".json")

    case read_intent(store, intent_id) do
      {:ok, document} -> {:cont, {:ok, [document | documents]}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp reverse_documents({:ok, documents}), do: {:ok, Enum.reverse(documents)}
  defp reverse_documents({:error, reason}), do: {:error, reason}

  defp create_new_intent(path, document) do
    case atomic_write(path, document) do
      :ok -> {:ok, document, :created}
      {:error, _reason} -> {:error, :store_unavailable}
    end
  end

  defp read_document(store, kind, id) do
    with :ok <- validate_id(id) do
      read_path(document_path(store, kind, id), kind, id)
    end
  end

  defp read_path(path, kind, id) do
    case File.read(path) do
      {:ok, contents} ->
        with {:ok, decoded} when is_map(decoded) <- Jason.decode(contents),
             :ok <- validate_document(decoded, kind, id) do
          {:ok, decoded}
        else
          _invalid -> {:error, :invalid_document}
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, _reason} ->
        {:error, :store_unavailable}
    end
  end

  defp validate_document(document, kind, id) when is_map(document) do
    id_key = if(kind == :project, do: "project_id", else: "intent_id")

    with :ok <- validate_id(id),
         ^id <- Map.get(document, id_key),
         @schema_version <- Map.get(document, "schema_version") do
      :ok
    else
      _invalid -> {:error, :invalid_document}
    end
  end

  defp validate_document(_document, _kind, _id), do: {:error, :invalid_document}

  defp validate_id(id) when is_binary(id) do
    if Regex.match?(@id_pattern, id), do: :ok, else: {:error, :invalid_document_id}
  end

  defp validate_id(_id), do: {:error, :invalid_document_id}

  defp ensure_root(root) do
    with :ok <- File.mkdir_p(root),
         :ok <- File.mkdir_p(Path.join(root, "projects")),
         :ok <- File.mkdir_p(Path.join(root, "intents")),
         :ok <- owner_only(root),
         :ok <- owner_only(Path.join(root, "projects")),
         :ok <- owner_only(Path.join(root, "intents")) do
      :ok
    else
      _error -> {:error, :invalid_store_root}
    end
  end

  defp owner_only(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> File.chmod(path, 0o700)
      _invalid -> {:error, :invalid_root_type}
    end
  end

  defp document_path(store, :project, id),
    do: Path.join([store.root, "projects", id <> ".json"])

  defp document_path(store, :intent, id),
    do: Path.join([store.root, "intents", id <> ".json"])

  defp atomic_write(path, document) do
    temporary =
      Path.join(
        Path.dirname(path),
        ".#{Path.basename(path)}.tmp-#{System.unique_integer([:positive, :monotonic])}"
      )

    encoded = Canonical.json(document)

    try do
      with :ok <- File.write(temporary, encoded, [:binary, :sync]),
           :ok <- File.chmod(temporary, 0o600) do
        File.rename(temporary, path)
      end
    after
      _ignored = File.rm(temporary)
    end
  end

  defp maybe_write_changed(path, current, next) do
    if Canonical.digest(current) == Canonical.digest(next), do: :ok, else: atomic_write(path, next)
  end

  defp safe_reduce(reducer, current) do
    reducer.(current)
  rescue
    _error -> {:error, :invalid_document}
  catch
    _kind, _reason -> {:error, :invalid_document}
  end

  defp locked(path, callback) do
    :global.trans({__MODULE__, path}, callback)
  catch
    _kind, _reason -> {:error, :store_unavailable}
  end

  defp unique_allowed_options?(opts, allowed) do
    keys = Keyword.keys(opts)
    Enum.all?(keys, &(&1 in allowed)) and length(keys) == MapSet.size(MapSet.new(keys))
  end
end
