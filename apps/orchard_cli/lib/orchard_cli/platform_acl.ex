defmodule OrchardCLI.PlatformACL do
  @moduledoc false

  @type acl_entry :: %{
          required(:scope) => :access | :default,
          required(:kind) => :user | :group | :mask | :other,
          required(:qualifier) => String.t() | nil,
          required(:permissions) => String.t(),
          optional(:disposition) => :allow | :deny,
          optional(:platform) => :darwin | :linux
        }
  @type path_type :: :regular | :directory

  @darwin_mutation_rights ~w(
    add_file
    add_subdirectory
    append
    chown
    delete
    delete_child
    write
    writeattr
    writeextattr
    writesecurity
  )
  @darwin_acl_tokens MapSet.new(~w(
                         add_file
                         add_subdirectory
                         append
                         chown
                         delete
                         delete_child
                         directory_inherit
                         execute
                         file_inherit
                         limit_inherit
                         list
                         only_inherit
                         read
                         readattr
                         readextattr
                         readsecurity
                         search
                         write
                         writeattr
                         writeextattr
                         writesecurity
                       ))
  @linux_base_kinds MapSet.new([:user, :group, :other])

  @spec remove_extended(String.t(), path_type(), keyword()) ::
          :ok | {:error, :acl_removal_failed}
  def remove_extended(path, type, opts \\ []) do
    case removal_command(platform(opts), path, type) do
      {:ok, command, args} -> run(command, args, opts, :acl_removal_failed)
      :error -> {:error, :acl_removal_failed}
    end
  end

  @spec entries(String.t(), keyword()) :: {:ok, [acl_entry()]} | {:error, :acl_inspection_failed}
  def entries(path, opts \\ []) do
    with {:ok, command, args} <- inspection_command(platform(opts), path),
         {:ok, output} <- run_for_output(command, args, opts),
         {:ok, entries} <- parse_entries(platform(opts), output) do
      {:ok, entries}
    else
      _error -> {:error, :acl_inspection_failed}
    end
  end

  @spec grants_parent_mutation?(acl_entry()) :: boolean()
  def grants_parent_mutation?(%{
        platform: :darwin,
        disposition: :allow,
        permissions: permissions
      }) do
    permissions
    |> darwin_permission_tokens()
    |> Enum.any?(&(&1 in @darwin_mutation_rights))
  end

  def grants_parent_mutation?(%{
        platform: :linux,
        scope: :access,
        kind: kind,
        qualifier: qualifier,
        permissions: permissions
      })
      when kind in [:user, :group] and is_binary(qualifier) do
    String.contains?(permissions, "w")
  end

  def grants_parent_mutation?(_entry), do: false

  defp removal_command(:darwin, path, type) when type in [:regular, :directory] do
    {:ok, "/bin/chmod", ["-N", path]}
  end

  defp removal_command(:linux, path, :regular) do
    {:ok, "/usr/bin/setfacl", ["-b", "--", path]}
  end

  defp removal_command(:linux, path, :directory) do
    {:ok, "/usr/bin/setfacl", ["-b", "-k", "--", path]}
  end

  defp removal_command(_platform, _path, _type), do: :error

  defp inspection_command(:darwin, path), do: {:ok, "/bin/ls", ["-lde", path]}

  defp inspection_command(:linux, path) do
    {:ok, "/usr/bin/getfacl", ["-c", "-p", "--", path]}
  end

  defp inspection_command(_platform, _path), do: :error

  defp run(command, args, opts, error_reason) do
    case invoke_runner(command, args, opts) do
      {_output, 0} -> :ok
      {_output, _status} -> {:error, error_reason}
      :runner_error -> {:error, error_reason}
    end
  end

  defp run_for_output(command, args, opts) do
    case invoke_runner(command, args, opts) do
      {output, 0} -> {:ok, output}
      {_output, _status} -> :error
      :runner_error -> :error
    end
  end

  defp invoke_runner(command, args, opts) do
    runner = Keyword.get(opts, :runner, &System.cmd/3)
    command_opts = [env: [{"LC_ALL", "C"}], stderr_to_stdout: true]

    runner.(command, args, command_opts)
  rescue
    _error in [ArgumentError, ErlangError] -> :runner_error
  end

  defp parse_entries(:darwin, output), do: parse_darwin_entries(output)
  defp parse_entries(:linux, output), do: parse_linux_entries(output)
  defp parse_entries(_platform, _output), do: :error

  defp parse_darwin_entries(output) do
    case String.split(output, "\n", trim: true) do
      [header | acl_lines] ->
        with {:ok, marker} <- darwin_header_acl_marker(header),
             {:ok, _next_ordinal, entries} <-
               Enum.reduce_while(acl_lines, {:ok, 0, []}, &parse_darwin_entry/2),
             :ok <- validate_darwin_acl_marker(marker, entries) do
          {:ok, Enum.reverse(entries)}
        else
          _error -> :error
        end

      [] ->
        :error
    end
  end

  defp darwin_header_acl_marker(header) do
    case Regex.run(
           ~r/^[bcdlpsw-][rwxStTs-]{9}([+@]?)\s+\d+\s+\S+\s+\S+\s+\d+\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+\d{1,2}\s+(?:\d{2}:\d{2}|\d{4})\s+.+$/,
           header
         ) do
      [_header, marker] -> {:ok, marker}
      _other -> :error
    end
  end

  defp validate_darwin_acl_marker("", []), do: :ok
  defp validate_darwin_acl_marker("+", [_entry | _entries]), do: :ok
  defp validate_darwin_acl_marker("@", _entries), do: :ok
  defp validate_darwin_acl_marker(_marker, _entries), do: :error

  defp parse_darwin_entry(line, {:ok, next_ordinal, entries}) do
    case Regex.run(~r/^\s+(\d+):\s+.+\s+(allow|deny)\s+(.+)$/, line) do
      [_line, ordinal, disposition, permissions] ->
        if String.to_integer(ordinal) == next_ordinal and valid_darwin_permissions?(permissions) do
          entry = %{
            platform: :darwin,
            scope: :access,
            kind: :other,
            qualifier: nil,
            disposition: String.to_existing_atom(disposition),
            permissions: permissions
          }

          {:cont, {:ok, next_ordinal + 1, [entry | entries]}}
        else
          {:halt, :error}
        end

      _other ->
        {:halt, :error}
    end
  end

  defp valid_darwin_permissions?(permissions) do
    tokens = darwin_permission_tokens(permissions)

    tokens != [] and
      Enum.all?(tokens, &(&1 != "" and MapSet.member?(@darwin_acl_tokens, &1)))
  end

  defp darwin_permission_tokens(permissions) do
    permissions
    |> String.split(~r/\s+/, trim: true)
    |> Enum.flat_map(&String.split(&1, ",", trim: false))
  end

  defp parse_linux_entries(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, %{base_kinds: MapSet.new(), entries: []}}, &parse_linux_line/2)
    |> complete_linux_entries()
  end

  defp parse_linux_line("#" <> _comment, accumulator), do: {:cont, accumulator}

  defp parse_linux_line(line, {:ok, accumulator}) do
    case Regex.run(
           ~r/^(default:)?(user|group|mask|other):([^:]*):([rwx-]{3})(?:\s+#effective:[rwx-]{3})?$/,
           line
         ) do
      [_line, default, kind, qualifier, permissions] ->
        entry = %{
          platform: :linux,
          scope: linux_scope(default),
          kind: String.to_existing_atom(kind),
          qualifier: empty_to_nil(qualifier),
          permissions: permissions
        }

        accumulate_linux_entry(entry, accumulator)

      _other ->
        {:halt, :error}
    end
  end

  defp complete_linux_entries({:ok, %{base_kinds: @linux_base_kinds, entries: entries}}) do
    {:ok, Enum.reverse(entries)}
  end

  defp complete_linux_entries(_incomplete), do: :error

  defp linux_scope("default:"), do: :default
  defp linux_scope(""), do: :access

  defp accumulate_linux_entry(entry, %{base_kinds: base_kinds} = accumulator) do
    case linux_base_kind(entry) do
      nil ->
        {:cont, {:ok, %{accumulator | entries: [entry | accumulator.entries]}}}

      kind ->
        if MapSet.member?(base_kinds, kind) do
          {:halt, :error}
        else
          {:cont, {:ok, %{accumulator | base_kinds: MapSet.put(base_kinds, kind)}}}
        end
    end
  end

  defp linux_base_kind(%{scope: :access, kind: kind, qualifier: nil})
       when kind in [:user, :group, :other],
       do: kind

  defp linux_base_kind(_entry), do: nil

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp platform(opts), do: Keyword.get_lazy(opts, :platform, &host_platform/0)

  defp host_platform do
    case :os.type() do
      {:unix, :darwin} -> :darwin
      {:unix, :linux} -> :linux
      _other -> :unsupported
    end
  end
end
