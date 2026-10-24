# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule WeftWarpBurrito.Program do
  @moduledoc """
  One actor per RISC-V program using the tagged-GuestValue host-call
  ABI (RFD66606-0018's BEAM half). Currently unused in production -- the two
  callers this existed for, `Uro.ReBAC.SandboxAdapter` and
  `Uro.Planner.SandboxAdapter`, were retired in favor of plain-Elixir
  ports (RFD66606-0039) once their domains turned out to be trusted, bundled
  content rather than the adversarial input a RISC-V sandbox exists to
  contain. Kept as generic infrastructure for a future genuinely-
  untrusted-content guest program (`WeftWarpBurrito.Sandbox` is the
  fixed-capability sibling for that same libriscv::Machine boundary --
  also currently unused, since `Uro.LoopCore.Instance` moved
  combat/loot/progression off the sandbox entirely, RFD66606-0026/0027).

  Drives the host-call trampoline: when guest fixnum arithmetic
  overflows (or touches a bignum handle), the guest ecalls, the Machine
  stops with its state intact in the NIF resource, and this GenServer
  computes the operation with Elixir's native arbitrary-precision
  integers before resuming execution. Bignums therefore cross the
  boundary as real Elixir integers -- no GMP, no vendored numeric
  library.

  The per-call handle table lives here, in plain Elixir state, and is
  discarded when the call completes (godot-sandbox CurrentState
  semantics). Arguments and results may be integers of any size,
  booleans, nil, atoms, lists, tuples, maps, or binaries -- complex
  terms stay host-side as handles, and the guest reaches back through
  the same trampoline for every structural operation (car/cdr/cons,
  vector-ref on tuples, hash-table-ref on maps, string-length on
  binaries). Atoms are interned per call so guest `eq?` works on them.

  One documented collapse: Scheme has a single `()` where Elixir has
  both `nil` and `[]` -- both encode to the nil immediate, and it
  always decodes back as `nil` (so a guest-built list's empty tail
  never surfaces; only whole lists do, as real Elixir lists).
  """
  use GenServer

  import Bitwise

  alias WeftWarpBurrito.SandboxNif

  @default_fuel 100_000_000

  # Tagged GuestValue constants -- must match whatever ELF the caller
  # loads (RFD66606-0018's fixed tagging scheme: any guest program using this
  # ABI encodes values this same way).
  @false_v 0x06
  @true_v 0x0E
  @nil_v 0x16
  @handle_tag 0x2
  @closure_tag 0x4
  @fixnum_min -(1 <<< 60)
  @fixnum_max (1 <<< 60) - 1

  # Host-math ops -- must match whatever ELF the caller loads.
  @op_add 0
  @op_sub 1
  @op_mul 2
  @op_quot 3
  @op_rem 4
  @op_lt 5
  @op_eq 6

  # Handle-value ops (same trampoline, ops 16+) -- must match value.h.
  @op_car 16
  @op_cdr 17
  @op_cons 18
  @op_length 19
  @op_list_ref 20
  @op_is_pair 21
  @op_tuple_ref 22
  @op_tuple_size 23
  @op_map_ref 24
  @op_map_size 25
  @op_bin_size 26
  @op_str_eq 27
  @op_map_set 28
  @op_map_keys 29

  ## Public API

  def start_link(opts) do
    {elf, opts} = Keyword.pop!(opts, :elf)
    GenServer.start_link(__MODULE__, elf, opts)
  end

  @doc """
  Calls an exported function with integer/boolean arguments. Returns
  `{:ok, value}` (integers may exceed fixnum range -- decoded from the
  handle table), or `{:error, reason}`.
  """
  def call(pid, function, args, fuel \\ @default_fuel) when is_list(args) do
    GenServer.call(pid, {:call, function, args, fuel}, :infinity)
  end

  ## GenServer callbacks

  @impl true
  def init(elf) when is_binary(elf) do
    case SandboxNif.new_program_nif(elf) do
      {:ok, resource} -> {:ok, %{resource: resource}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:call, function, args, fuel}, _from, state) do
    handles = %{next: 0, values: %{}, interned: %{}}

    with {:ok, tagged_args, handles} <- encode_args(args, handles) do
      result =
        state.resource
        |> SandboxNif.program_call_nif(function, tagged_args, fuel)
        |> trampoline(state.resource, handles)

      {:reply, result, state}
    else
      error -> {:reply, error, state}
    end
  end

  ## Trampoline: keep computing host calls in Elixir until the guest
  ## finishes (or errors).

  defp trampoline({:host_call, op, a, b}, resource, handles) do
    case host_math(op, a, b, handles) do
      {:ok, tagged, handles} ->
        resource
        |> SandboxNif.program_resume_nif(tagged)
        |> trampoline(resource, handles)

      {:error, _} = error ->
        error
    end
  end

  defp trampoline({:ok, tagged}, _resource, handles), do: decode(tagged, handles)
  defp trampoline({:error, _} = error, _resource, _handles), do: error

  ## Host math (RFD66606-0018): Elixir integers ARE the bignums, and Elixir
  ## terms ARE the host-owned values behind handles.

  defp host_math(op, a, b, handles)
       when op in [@op_add, @op_sub, @op_mul, @op_quot, @op_rem, @op_lt, @op_eq] do
    with {:ok, x} <- unbox_number(a, handles),
         {:ok, y} <- unbox_number(b, handles) do
      case op do
        @op_add -> box(x + y, handles)
        @op_sub -> box(x - y, handles)
        @op_mul -> box(x * y, handles)
        @op_quot when y == 0 -> {:error, :division_by_zero}
        @op_quot -> box(div(x, y), handles)
        @op_rem when y == 0 -> {:error, :division_by_zero}
        @op_rem -> box(rem(x, y), handles)
        # Comparisons return RAW 0/1 (the guest tags them itself).
        @op_lt -> {:ok, if(x < y, do: 1, else: 0), handles}
        @op_eq -> {:ok, if(x == y, do: 1, else: 0), handles}
      end
    end
  end

  # pair? never errors: any undecodable or non-list word is just #f.
  defp host_math(@op_is_pair, a, _b, handles) do
    case unbox_term(a, handles) do
      {:ok, list} when is_list(list) and list != [] -> {:ok, 1, handles}
      _ -> {:ok, 0, handles}
    end
  end

  # Functional map insert: `a` may be #f (start from an empty map), since
  # a two-level nested-ref/nested-set chain never needs a separate
  # "create empty map" primitive (mirrors hash-table-ref's own
  # "missing key -> #f").
  defp host_math(@op_map_set, a, b, handles) do
    with {:ok, [key, value]} <- unbox_term(b, handles),
         {:ok, base} <- unbox_map_or_false(a, handles) do
      box(Map.put(base, key, value), handles)
    end
  end

  # (hash-table-keys m): `a` may be #f (an empty map, mirroring
  # hash-table-ref's own "missing key -> #f" convention) -> nil.
  defp host_math(@op_map_keys, a, _b, handles) do
    with {:ok, m} <- unbox_map_or_false(a, handles) do
      box(Map.keys(m), handles)
    end
  end

  defp host_math(op, a, b, handles) do
    with {:ok, x} <- unbox_term(a, handles) do
      case {op, x} do
        {@op_car, [h | _]} ->
          box(h, handles)

        {@op_cdr, [_ | t]} ->
          box(t, handles)

        {@op_length, l} when is_list(l) ->
          box(length(l), handles)

        {@op_tuple_size, t} when is_tuple(t) ->
          box(tuple_size(t), handles)

        {@op_map_size, m} when is_map(m) ->
          box(map_size(m), handles)

        {@op_bin_size, bin} when is_binary(bin) ->
          box(byte_size(bin), handles)

        {binop, _}
        when binop in [@op_cons, @op_list_ref, @op_tuple_ref, @op_map_ref, @op_str_eq] ->
          with {:ok, y} <- unbox_term(b, handles) do
            host_binop(binop, x, y, handles)
          end

        _ ->
          {:error, :host_op_type_error}
      end
    end
  end

  defp host_binop(@op_cons, x, y, handles) when is_list(y), do: box([x | y], handles)

  defp host_binop(@op_list_ref, x, y, handles) when is_list(x) and is_integer(y) do
    case Enum.fetch(x, y) do
      {:ok, value} -> box(value, handles)
      :error -> {:error, :index_out_of_range}
    end
  end

  defp host_binop(@op_tuple_ref, x, y, handles)
       when is_tuple(x) and is_integer(y) and y >= 0 and y < tuple_size(x),
       do: box(elem(x, y), handles)

  defp host_binop(@op_map_ref, x, y, handles) when is_map(x) do
    case Map.fetch(x, y) do
      {:ok, value} -> box(value, handles)
      # s7 hash-table-ref: missing key -> #f (tagged, not raw).
      :error -> {:ok, @false_v, handles}
    end
  end

  defp host_binop(@op_str_eq, x, y, handles) when is_binary(x) and is_binary(y),
    do: {:ok, if(x == y, do: 1, else: 0), handles}

  defp host_binop(_, _, _, _), do: {:error, :host_op_type_error}

  # Numbers only (checked arithmetic): a fixnum or an integer handle.
  defp unbox_number(tagged, handles) do
    cond do
      (tagged &&& 7) == 0 ->
        {:ok, tagged >>> 3}

      (tagged &&& 7) == @handle_tag ->
        case fetch_handle(handles, tagged >>> 3) do
          {:ok, value} when is_integer(value) -> {:ok, value}
          {:ok, _} -> {:error, :host_math_type_error}
          error -> error
        end

      true ->
        {:error, :host_math_type_error}
    end
  end

  # Any term: immediates decode too (nil is Scheme's (), hence []).
  defp unbox_term(tagged, handles) do
    cond do
      (tagged &&& 7) == 0 -> {:ok, tagged >>> 3}
      tagged == @true_v -> {:ok, true}
      tagged == @false_v -> {:ok, false}
      tagged == @nil_v -> {:ok, []}
      (tagged &&& 7) == @handle_tag -> fetch_handle(handles, tagged >>> 3)
      true -> {:error, :host_op_type_error}
    end
  end

  defp unbox_map_or_false(tagged, handles) do
    case unbox_term(tagged, handles) do
      {:ok, m} when is_map(m) -> {:ok, m}
      {:ok, false} -> {:ok, %{}}
      {:ok, _} -> {:error, :host_op_type_error}
      error -> error
    end
  end

  defp fetch_handle(handles, index) do
    case Map.fetch(handles.values, index) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :bad_handle}
    end
  end

  ## Boxing: Elixir term -> tagged GuestValue, allocating handles as
  ## needed. Atoms are interned (same atom -> same handle) so the
  ## guest's raw-word eq? is meaningful on them.

  defp box(value, handles)
       when is_integer(value) and value >= @fixnum_min and value <= @fixnum_max,
       do: {:ok, value <<< 3, handles}

  defp box(true, handles), do: {:ok, @true_v, handles}
  defp box(false, handles), do: {:ok, @false_v, handles}
  defp box(nil, handles), do: {:ok, @nil_v, handles}
  defp box([], handles), do: {:ok, @nil_v, handles}

  defp box(value, handles) when is_atom(value) do
    case Map.fetch(handles.interned, value) do
      {:ok, tagged} ->
        {:ok, tagged, handles}

      :error ->
        {:ok, tagged, handles} = new_handle(value, handles)
        {:ok, tagged, %{handles | interned: Map.put(handles.interned, value, tagged)}}
    end
  end

  defp box(value, handles)
       when is_integer(value) or is_list(value) or is_tuple(value) or is_map(value) or
              is_binary(value),
       do: new_handle(value, handles)

  defp box(_, _), do: {:error, :unsupported_value}

  defp new_handle(value, handles) do
    index = handles.next
    handles = %{handles | next: index + 1, values: Map.put(handles.values, index, value)}
    {:ok, index <<< 3 ||| @handle_tag, handles}
  end

  ## GuestValue codec

  defp encode_args(args, handles) do
    Enum.reduce_while(args, {:ok, [], handles}, fn arg, {:ok, acc, handles} ->
      case box(arg, handles) do
        {:ok, tagged, handles} -> {:cont, {:ok, [tagged | acc], handles}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed, handles} -> {:ok, Enum.reverse(reversed), handles}
      error -> error
    end
  end

  defp decode(tagged, handles) do
    cond do
      (tagged &&& 7) == 0 -> {:ok, tagged >>> 3}
      tagged == @true_v -> {:ok, true}
      tagged == @false_v -> {:ok, false}
      tagged == @nil_v -> {:ok, nil}
      (tagged &&& 7) == @handle_tag -> fetch_handle(handles, tagged >>> 3)
      (tagged &&& 7) == @closure_tag -> {:ok, :closure}
      true -> {:error, {:undecodable, tagged}}
    end
  end
end
