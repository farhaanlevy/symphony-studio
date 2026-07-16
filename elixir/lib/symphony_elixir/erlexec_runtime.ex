# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.ErlexecRuntime do
  @moduledoc """
  Prepares the vendored `erlexec` runtime without invoking a shell.

  Native releases use the architecture-specific executable from the dependency
  `priv` directory. Mix escripts cannot execute a file in their in-memory ZIP
  archive, so that one exact regular-file entry is copied into a fresh private
  runtime directory before `erlexec` starts.
  """

  import Bitwise, only: [band: 2]

  @directory_prefix "symphony-erlexec-"
  @directory_attempts 8
  @fallback_shell "/bin/sh"
  @maximum_port_executable_bytes 4 * 1024 * 1024
  @private_mode 0o700

  @enforce_keys [:temporary_root, :directory, :executable]
  defstruct [:temporary_root, :directory, :executable]

  @opaque t :: %__MODULE__{
            temporary_root: Path.t(),
            directory: Path.t(),
            executable: Path.t()
          }

  @type prepare_option ::
          {:architecture, String.t()}
          | {:directory_suffixes, [String.t()]}
          | {:priv_dir, Path.t()}
          | {:script_path, Path.t()}
          | {:temporary_root, Path.t()}

  @type prepare_error ::
          :embedded_port_executable_invalid
          | :embedded_port_executable_missing
          | :erlexec_port_executable_invalid
          | :escript_archive_invalid
          | :escript_path_invalid
          | :invalid_prepare_options
          | :invalid_system_architecture
          | :private_runtime_directory_unavailable
          | :private_runtime_file_unavailable
          | :temporary_root_invalid

  @doc """
  Prepares `SHELL` and an executable `erlexec` port path for this runtime.

  A returned lease owns only a newly extracted escript artifact and must be
  passed to `cleanup/1` after the supervised `erlexec` process has stopped.
  Native and operator-provided executables return a `nil` lease.
  """
  @spec prepare() :: {:ok, t() | nil} | {:error, prepare_error()}
  def prepare do
    prepare([])
  end

  @doc false
  @spec prepare([prepare_option()]) :: {:ok, t() | nil} | {:error, prepare_error()}
  def prepare(opts) when is_list(opts) do
    with {:ok, options} <- validate_options(opts),
         :ok <- prepare_shell_environment(),
         {:ok, native_state} <- native_port_executable_state(options) do
      case native_state do
        :ready -> {:ok, nil}
        :missing -> extract_embedded_port_executable(options)
      end
    end
  end

  def prepare(_opts), do: {:error, :invalid_prepare_options}

  @doc """
  Removes an extracted runtime artifact owned by `prepare/0` or `prepare/1`.

  The cleanup path is structurally revalidated and never recursively removed.
  """
  @spec cleanup(t() | nil) :: :ok | {:error, :runtime_cleanup_failed}
  def cleanup(nil), do: :ok

  def cleanup(%__MODULE__{} = runtime) do
    if owned_runtime_layout?(runtime) do
      maybe_delete_owned_portexe(runtime.executable)

      file_result = remove_if_present(runtime.executable, &File.rm/1)
      directory_result = remove_if_present(runtime.directory, &File.rmdir/1)

      if file_result == :ok and directory_result == :ok do
        :ok
      else
        {:error, :runtime_cleanup_failed}
      end
    else
      {:error, :runtime_cleanup_failed}
    end
  end

  @doc "Supplies `/bin/sh` only when the ambient `SHELL` value is missing or blank."
  @spec prepare_shell_environment() :: :ok
  def prepare_shell_environment do
    case System.get_env("SHELL") do
      nil -> System.put_env("SHELL", @fallback_shell)
      "" -> System.put_env("SHELL", @fallback_shell)
      value -> preserve_or_replace_shell(value)
    end
  end

  defp validate_options(opts) do
    defaults = [
      architecture: system_architecture(),
      directory_suffixes: nil,
      priv_dir: default_priv_dir(),
      script_path: default_script_path(),
      temporary_root: System.tmp_dir()
    ]

    case Keyword.validate(opts, defaults) do
      {:ok, options} -> validate_option_values(options)
      {:error, _unknown} -> {:error, :invalid_prepare_options}
    end
  end

  defp validate_option_values(options) do
    with :ok <- validate_architecture(options[:architecture]),
         :ok <- validate_optional_path(options[:priv_dir]),
         :ok <- validate_optional_path(options[:script_path]),
         :ok <- validate_optional_path(options[:temporary_root]),
         :ok <- validate_directory_suffixes(options[:directory_suffixes]) do
      {:ok, options}
    end
  end

  defp validate_architecture(architecture) when is_binary(architecture) do
    if byte_size(architecture) <= 128 and
         Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/, architecture) do
      :ok
    else
      {:error, :invalid_system_architecture}
    end
  end

  defp validate_architecture(_architecture), do: {:error, :invalid_system_architecture}

  defp validate_optional_path(path) when is_binary(path), do: :ok
  defp validate_optional_path(_path), do: {:error, :invalid_prepare_options}

  defp validate_directory_suffixes(nil), do: :ok

  defp validate_directory_suffixes(suffixes) when is_list(suffixes) do
    if suffixes != [] and Enum.all?(suffixes, &valid_directory_suffix?/1) do
      :ok
    else
      {:error, :invalid_prepare_options}
    end
  end

  defp validate_directory_suffixes(_suffixes), do: {:error, :invalid_prepare_options}

  defp valid_directory_suffix?(suffix) when is_binary(suffix) do
    byte_size(suffix) in 8..64 and Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, suffix)
  end

  defp valid_directory_suffix?(_suffix), do: false

  defp preserve_or_replace_shell(value) do
    if String.trim(value) == "" do
      System.put_env("SHELL", @fallback_shell)
    else
      :ok
    end
  end

  defp native_port_executable_state(options) do
    case Application.fetch_env(:erlexec, :portexe) do
      {:ok, configured_path} ->
        case validate_native_executable(configured_path) do
          :ok -> {:ok, :ready}
          {:error, _reason} -> {:error, :erlexec_port_executable_invalid}
        end

      :error ->
        candidate =
          Path.join([
            options[:priv_dir],
            options[:architecture],
            "exec-port"
          ])

        case validate_native_executable(candidate) do
          :ok -> {:ok, :ready}
          {:error, :missing} -> {:ok, :missing}
          {:error, _reason} -> {:error, :erlexec_port_executable_invalid}
        end
    end
  end

  defp validate_native_executable(path) when is_list(path) do
    path
    |> List.to_string()
    |> validate_native_executable()
  end

  defp validate_native_executable(path) when is_binary(path) do
    if Path.type(path) == :absolute do
      validate_native_executable_file(path)
    else
      {:error, :invalid_path}
    end
  end

  defp validate_native_executable(_path), do: {:error, :invalid_path}

  defp validate_native_executable_file(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size, mode: mode}}
      when size > 0 and size <= @maximum_port_executable_bytes ->
        if band(mode, 0o111) != 0, do: :ok, else: {:error, :not_executable}

      {:ok, _unsafe_type} ->
        {:error, :unsafe_type}

      {:error, reason} when reason in [:enoent, :enotdir] ->
        {:error, :missing}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  defp extract_embedded_port_executable(options) do
    entry =
      String.to_charlist("erlexec/priv/#{options[:architecture]}/exec-port")

    with {:ok, data} <- read_regular_archive_entry(options[:script_path], entry),
         {:ok, temporary_root} <- validate_temporary_root(options[:temporary_root]),
         {:ok, directory} <- create_private_runtime_directory(temporary_root, options),
         {:ok, executable} <- write_private_executable(directory, data) do
      Application.put_env(:erlexec, :portexe, executable)

      {:ok,
       %__MODULE__{
         temporary_root: temporary_root,
         directory: directory,
         executable: executable
       }}
    else
      {:error, _reason} = error -> error
    end
  end

  defp read_regular_archive_entry(script_path, entry) do
    with {:ok, %File.Stat{type: :regular}} <- File.stat(script_path),
         {:ok, sections} <- :escript.extract(String.to_charlist(script_path), []),
         {:archive, archive} when is_binary(archive) <- List.keyfind(sections, :archive, 0),
         {:ok, table} <- :zip.table(archive),
         {:ok, expected_size} <- validate_archive_entry_table(table, entry),
         {:ok, [{^entry, data}]} when byte_size(data) == expected_size <-
           :zip.extract(archive, [:memory, {:file_list, [entry]}]) do
      {:ok, data}
    else
      {:ok, %File.Stat{}} -> {:error, :escript_path_invalid}
      {:error, :embedded_port_executable_missing} = error -> error
      {:error, :embedded_port_executable_invalid} = error -> error
      _other -> {:error, :escript_archive_invalid}
    end
  end

  defp validate_archive_entry_table(table, entry) do
    matches =
      Enum.filter(table, fn
        {:zip_file, ^entry, _info, _comment, _offset, _compressed_size} -> true
        _other -> false
      end)

    case matches do
      [{:zip_file, ^entry, info, _comment, _offset, _compressed_size}] ->
        validate_archive_file_info(info)

      [] ->
        {:error, :embedded_port_executable_missing}

      _duplicates ->
        {:error, :embedded_port_executable_invalid}
    end
  end

  defp validate_archive_file_info(info)
       when is_tuple(info) and tuple_size(info) >= 4 and elem(info, 0) == :file_info and
              elem(info, 2) == :regular do
    size = elem(info, 1)

    if is_integer(size) and size > 0 and size <= @maximum_port_executable_bytes do
      {:ok, size}
    else
      {:error, :embedded_port_executable_invalid}
    end
  end

  defp validate_archive_file_info(_info), do: {:error, :embedded_port_executable_invalid}

  defp validate_temporary_root(root) do
    expanded_root = Path.expand(root)

    case File.lstat(expanded_root) do
      {:ok, %File.Stat{type: :directory}} -> {:ok, expanded_root}
      _other -> {:error, :temporary_root_invalid}
    end
  end

  defp create_private_runtime_directory(temporary_root, options) do
    suffixes =
      options[:directory_suffixes] ||
        Enum.map(1..@directory_attempts, fn _attempt -> random_directory_suffix() end)

    do_create_private_runtime_directory(temporary_root, suffixes)
  end

  defp do_create_private_runtime_directory(_temporary_root, []),
    do: {:error, :private_runtime_directory_unavailable}

  defp do_create_private_runtime_directory(temporary_root, [suffix | rest]) do
    directory = Path.join(temporary_root, @directory_prefix <> suffix)

    case File.mkdir(directory) do
      :ok ->
        case secure_private_directory(directory) do
          :ok ->
            {:ok, directory}

          {:error, _reason} ->
            _ignored = File.rmdir(directory)
            {:error, :private_runtime_directory_unavailable}
        end

      {:error, :eexist} ->
        do_create_private_runtime_directory(temporary_root, rest)

      {:error, _reason} ->
        {:error, :private_runtime_directory_unavailable}
    end
  end

  defp secure_private_directory(directory) do
    with :ok <- File.chmod(directory, @private_mode),
         {:ok, %File.Stat{type: :directory, mode: mode}} <- File.lstat(directory),
         true <- band(mode, 0o777) == @private_mode do
      :ok
    else
      _other -> {:error, :unsafe_directory}
    end
  end

  defp write_private_executable(directory, data) do
    executable = Path.join(directory, "exec-port")

    result =
      with :ok <- write_exclusive(executable, data),
           :ok <- File.chmod(executable, @private_mode),
           {:ok, %File.Stat{type: :regular, size: size, mode: mode}} <-
             File.lstat(executable),
           true <- size == byte_size(data) and band(mode, 0o777) == @private_mode do
        :ok
      else
        _other -> {:error, :private_runtime_file_unavailable}
      end

    case result do
      :ok ->
        {:ok, executable}

      {:error, _reason} = error ->
        _ignored_file = File.rm(executable)
        _ignored_directory = File.rmdir(directory)
        error
    end
  end

  defp write_exclusive(path, data) do
    case :file.open(String.to_charlist(path), [:write, :binary, :exclusive, :raw]) do
      {:ok, device} ->
        write_result = :file.write(device, data)
        close_result = :file.close(device)

        if write_result == :ok and close_result == :ok do
          :ok
        else
          {:error, :write_failed}
        end

      {:error, _reason} ->
        {:error, :open_failed}
    end
  end

  defp owned_runtime_layout?(runtime) do
    directory_name = Path.basename(runtime.directory)

    String.starts_with?(directory_name, @directory_prefix) and
      Path.dirname(runtime.directory) == runtime.temporary_root and
      runtime.executable == Path.join(runtime.directory, "exec-port")
  end

  defp maybe_delete_owned_portexe(executable) do
    if Application.get_env(:erlexec, :portexe) == executable do
      Application.delete_env(:erlexec, :portexe)
    end

    :ok
  end

  defp remove_if_present(path, remove) do
    case remove.(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> {:error, :remove_failed}
    end
  end

  defp random_directory_suffix do
    18
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp default_priv_dir do
    case :code.priv_dir(:erlexec) do
      path when is_list(path) -> List.to_string(path)
      _error -> ""
    end
  end

  defp default_script_path do
    :escript.script_name()
    |> List.to_string()
  end

  defp system_architecture do
    :erlang.system_info(:system_architecture)
    |> List.to_string()
  end
end
