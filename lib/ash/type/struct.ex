defmodule Ash.Type.Struct do
  @constraints [
    instance_of: [
      type: :atom,
      doc: "The module the struct should be an instance of"
    ],
    preserve_nil_values?: [
      type: :boolean,
      default: false,
      doc:
        "If set to true, when storing, nil values will be kept. Otherwise, nil values will be omitted."
    ],
    fields: [
      type: :keyword_list,
      keys: [
        *: [
          type: :keyword_list,
          keys: [
            type: [
              type: Ash.OptionsHelpers.ash_type(),
              required: true
            ],
            allow_nil?: [
              type: :boolean,
              default: true
            ],
            constraints: [
              type: :keyword_list,
              default: []
            ]
          ]
        ]
      ],
      doc: """
      The types of the fields in the struct, and their constraints.

      For example:

          fields:  [
            amount: [
              type: :integer,
              constraints: [
                max: 10
              ]
            ],
            currency: [
              type: :string,
              allow_nil?: false,
              constraints: [
                max_length: 3
              ]
            ]
          ]

      allow_nil? is true by default
      """
    ]
  ]
  @moduledoc """
  Represents a struct.

  Use the `instance_of` constraint to specify that it must be an instance of a specific struct.

  This cannot be loaded from a database unless the `instance_of` constraint is provided.
  If not, it can only be used to cast input, i.e for arguments.

  ## Constraints

  #{Spark.Options.docs(@constraints)}
  """

  use Ash.Type

  @impl true
  def constraints, do: @constraints

  @impl true
  def storage_type(_), do: :map

  @impl true
  def init(constraints) do
    if is_list(constraints[:fields]) do
      constraints[:fields]
      |> List.wrap()
      |> Enum.reduce_while({:ok, []}, fn {name, config}, {:ok, fields} ->
        type = config[:type]
        constraints = config[:constraints] || []

        if Keyword.get(config, :init?, true) do
          case Ash.Type.init(type, constraints) do
            {:ok, constraints} ->
              {:cont, {:ok, [{name, Keyword.put(config, :constraints, constraints)} | fields]}}

            {:error, error} ->
              {:halt, {:error, error}}
          end
        else
          {:cont, {:ok, [{name, config} | fields]}}
        end
      end)
      |> case do
        {:ok, fields} ->
          {:ok, Keyword.put(constraints, :fields, Enum.reverse(fields))}

        {:error, error} ->
          {:error, error}
      end
    else
      if is_nil(constraints[:fields]) do
        {:ok, constraints}
      else
        {:error, "fields must be a list, got `#{constraints[:fields]}`"}
      end
    end
  end

  defp fields(constraints) do
    case Keyword.fetch(constraints, :fields) do
      {:ok, fields} ->
        fields

      :error ->
        nil
    end
  end

  @impl true
  def matches_type?(v, constraints) do
    if instance_of = constraints[:instance_of] do
      is_struct(v, instance_of)
    else
      is_struct(v)
    end
  end

  @impl true
  def cast_input("", _), do: {:ok, nil}

  def cast_input(nil, _), do: {:ok, nil}

  def cast_input(value, constraints) when is_binary(value) do
    case Ash.Helpers.json_module().decode(value) do
      {:ok, value} ->
        cast_input(value, constraints)

      _ ->
        :error
    end
  end

  def cast_input(value, _) when is_map(value), do: {:ok, value}
  def cast_input(_, _), do: :error

  @impl true
  def cast_stored(nil, _), do: {:ok, nil}

  def cast_stored(value, constraints) when is_map(value) do
    if fields = fields(constraints) do
      if constraints[:instance_of] do
        nil_values = constraints[:store_nil_values?]

        Enum.reduce_while(fields, {:ok, %{}}, fn {key, config}, {:ok, acc} ->
          case Map.fetch(value, key) do
            {:ok, value} ->
              case Ash.Type.cast_stored(config[:type], value, config[:constraints] || []) do
                {:ok, value} ->
                  if is_nil(value) && !nil_values do
                    {:cont, {:ok, acc}}
                  else
                    {:cont, {:ok, Map.put(acc, key, value)}}
                  end

                other ->
                  {:halt, other}
              end

            :error ->
              {:cont, {:ok, acc}}
          end
        end)
      else
        :error
      end
    else
      :error
    end
  end

  def cast_stored(_, _), do: :error

  @impl true
  def dump_to_native(nil, _), do: {:ok, nil}

  def dump_to_native(value, constraints) when is_map(value) do
    if fields = fields(constraints) do
      if constraints[:instance_of] do
        Enum.reduce_while(fields, {:ok, %{}}, fn {key, config}, {:ok, acc} ->
          case Map.fetch(value, key) do
            {:ok, value} ->
              case Ash.Type.dump_to_native(config[:type], value, config[:constraints] || []) do
                {:ok, value} ->
                  {:cont, {:ok, Map.put(acc, key, value)}}

                other ->
                  {:halt, other}
              end

            :error ->
              {:cont, {:ok, acc}}
          end
        end)
      else
        :error
      end
    else
      :error
    end
  end

  def dump_to_native(_, _), do: :error

  @impl true
  def cast_atomic(new_value, constraints) do
    if fields(constraints) do
      {:not_atomic, "Structs do not support atomic updates when using the `keys` constraint"}
    else
      {:atomic, new_value}
    end
  end

  @impl true
  def generator(constraints) do
    if !constraints[:instance_of] do
      raise ArgumentError,
            "Cannot generate instances of the `:struct` type without an `:instance_of` constraint"
    end

    Ash.Type.Map.generator(constraints)
    |> StreamData.map(fn value ->
      struct(constraints[:instance_of], value)
    end)
  end

  @impl true
  def apply_constraints(value, constraints) do
    with {:ok, value} <- handle_fields(value, constraints) do
      handle_instance_of(value, constraints)
    end
  end

  @impl Ash.Type
  def load(record, load, _constraints, %{domain: domain} = context) do
    opts = Ash.Context.to_opts(context, domain: domain)

    Ash.load(record, load, opts)
  end

  @impl Ash.Type
  def merge_load(left, right, constraints, context) do
    instance_of = constraints[:instance_of]

    if instance_of do
      # instance_of_query = Ash.Query.new(instance_of)
      left = Ash.Query.load(instance_of, left)
      right = Ash.Query.load(instance_of, right)

      if left.valid? do
        {:ok, Ash.Query.merge_query_load(left, right, context)}
      else
        {:error, Ash.Error.to_ash_error(left.errors)}
      end
    else
      {:error, "Structs must have an `instance_of` constraint to be loaded through"}
    end
  end

  @impl Ash.Type
  def get_rewrites(merged_load, calculation, path, constraints) do
    instance_of = constraints[:instance_of]

    if instance_of && Ash.Resource.Info.resource?(instance_of) do
      merged_load = Ash.Query.load(instance_of, merged_load)
      Ash.Actions.Read.Calculations.get_all_rewrites(merged_load, calculation, path)
    else
      []
    end
  end

  @impl Ash.Type
  def rewrite(value, rewrites, _constraints) do
    Ash.Actions.Read.Calculations.rewrite(rewrites, value)
  end

  @impl Ash.Type
  def can_load?(constraints) do
    instance_of = constraints[:instance_of]

    instance_of && Ash.Resource.Info.resource?(instance_of)
  end

  defp handle_fields(value, constraints) do
    if fields = fields(constraints) do
      check_fields(value, fields)
    else
      {:ok, value}
    end
  end

  defp handle_instance_of(nil, _), do: {:ok, nil}

  defp handle_instance_of(value, constraints) do
    case Keyword.fetch(constraints, :instance_of) do
      {:ok, struct} ->
        cond do
          is_struct(value, struct) ->
            {:ok, value}

          is_struct(value) ->
            {:error, "is invalid"}

          true ->
            if fields(constraints) do
              {:ok, struct(struct, value)}
            else
              keys = Map.keys(value)

              if Enum.all?(keys, &is_atom/1) do
                {:ok, struct(struct, value)}
              else
                Map.delete(struct.__struct__(), :__struct__)
                |> Enum.reduce({:ok, struct(struct)}, fn {key, _value}, {:ok, acc} ->
                  with :error <- Map.fetch(value, key),
                       :error <- Map.fetch(value, to_string(key)) do
                    {:ok, acc}
                  else
                    {:ok, val} ->
                      {:ok, Map.put(acc, key, val)}
                  end
                end)
              end
            end
        end

      :error ->
        if is_struct(value) do
          {:ok, value}
        else
          {:error, "is invalid"}
        end
    end
  end

  defp check_fields(value, fields) do
    Enum.reduce(fields, {:ok, %{}}, fn
      {field, field_constraints}, {:ok, checked_value} ->
        case fetch_field(value, field) do
          {:ok, field_value} ->
            check_field(checked_value, field, field_value, field_constraints)

          :error ->
            if field_constraints[:allow_nil?] == false do
              {:error, [[message: "field must be present", field: field]]}
            else
              {:ok, checked_value}
            end
        end

      {_, _}, {:error, errors} ->
        {:error, errors}
    end)
  end

  defp check_field(result, field, field_value, field_constraints) do
    case Ash.Type.cast_input(
           field_constraints[:type],
           field_value,
           field_constraints[:constraints] || []
         ) do
      {:ok, field_value} ->
        case Ash.Type.apply_constraints(
               field_constraints[:type],
               field_value,
               field_constraints[:constraints] || []
             ) do
          {:ok, nil} ->
            if field_constraints[:allow_nil?] == false do
              {:error, [[message: "value must not be nil", field: field]]}
            else
              {:ok, Map.put(result, field, nil)}
            end

          {:ok, field_value} ->
            {:ok, Map.put(result, field, field_value)}

          {:error, errors} ->
            {:error, Enum.map(errors, fn error -> Keyword.put(error, :field, field) end)}
        end

      :error ->
        {:error, [[message: "invalid value", field: field]]}
    end
  end

  defp fetch_field(map, atom) when is_atom(atom) do
    case Map.fetch(map, atom) do
      {:ok, value} -> {:ok, value}
      :error -> fetch_field(map, to_string(atom))
    end
  end

  defp fetch_field(map, key), do: Map.fetch(map, key)
end
