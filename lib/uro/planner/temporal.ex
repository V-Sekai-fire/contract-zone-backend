# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Planner.Temporal do
  @moduledoc """
  Hand-ported from `standalone/tw_temporal.hpp` into plain Elixir --
  same reasoning as `Uro.LoopCore`'s port (RFD66606-0026): this is
  fully-trusted, self-contained arithmetic/parsing logic, not the kind
  of untrusted content the RISC-V sandbox exists to contain.

  One real simplification found during porting (see RFD66606-0028): the
  original's Simple Temporal Network used `double` distances and
  `infinity()` purely as a "no constraint yet" sentinel -- every actual
  constraint fed to it is an integer millisecond duration. Kept in
  integer milliseconds throughout here (a large sentinel instead of
  true infinity), so this module needs no floating point at all, unlike
  the original's `dur_s = dur_ms / 1000.0` round-trip.

  Civil-calendar (`Y`/`Mo`) arithmetic uses Elixir's stdlib `Date` plus
  Erlang's `:calendar.last_day_of_the_month/2` for day-clamping (e.g.
  Jan 31 + 1 month -> Feb 28/29) -- no date library dependency needed,
  unlike the original's vendored Howard Hinnant `date.h`.
  """

  # Unit milliseconds (Timex conventions: 1Y=365d, 1Mo=30d, 1W=7d) --
  # matches tw_duration_detail exactly.
  @ms_y 365 * 86_400 * 1000
  @ms_mo 30 * 86_400 * 1000
  @ms_w 7 * 86_400 * 1000
  @ms_d 86_400 * 1000
  @ms_h 3600 * 1000
  @ms_mi 60 * 1000
  @ms_s 1000

  # "No constraint yet" sentinel for the STN (ms-scale; ~34,000 years) --
  # replaces the original's `double` infinity, per this module's own
  # moduledoc note.
  @sentinel 1_000_000_000_000

  # --- ISO 8601 duration parsing (tw_parse_duration_ms) ---

  @doc """
  Parses an ISO 8601 duration (`P[nY][nM][nD][T[nH][nM][nS]]` or `PnW`)
  to total milliseconds. `:error` on any malformed input (matches the
  original's `-1` return, just idiomatic).
  """
  @spec parse_duration_ms(String.t()) :: {:ok, non_neg_integer()} | :error
  def parse_duration_ms("P"), do: {:ok, 0}

  def parse_duration_ms("P" <> rest) when byte_size(rest) > 0 do
    parse_duration_loop(rest, %{
      total_ms: 0,
      in_time: false,
      saw_t: false,
      saw_w: false,
      saw_any: false,
      last_rank: -1
    })
  end

  def parse_duration_ms(_), do: :error

  defp parse_duration_loop("", st), do: {:ok, st.total_ms}

  defp parse_duration_loop("T" <> rest, st) do
    cond do
      st.saw_t -> :error
      rest == "" -> :error
      true -> parse_duration_loop(rest, %{st | in_time: true, saw_t: true})
    end
  end

  defp parse_duration_loop(s, st) do
    with {:ok, whole, rest1} <- take_digits(s),
         {:ok, frac_ms_per_unit, has_frac, rest2} <- take_fraction(rest1),
         {:ok, unit_c, rest3} <- take_unit_char(rest2),
         {:ok, rank, unit_ms} <- classify_unit(unit_c, st.in_time),
         :ok <- check_week_rule(unit_c, st),
         :ok <- check_canonical_order(rank, st.last_rank) do
      frac_ms = if has_frac, do: frac_ms_per_unit * div(unit_ms, 1000), else: 0

      st = %{
        st
        | total_ms: st.total_ms + whole * unit_ms + frac_ms,
          # check_week_rule/2 already errors on a prior saw_w: true, so
          # st.saw_w is always false by the time we reach this update.
          saw_w: unit_c == "W",
          saw_any: true,
          last_rank: if(rank == 99, do: st.last_rank, else: rank)
      }

      if has_frac do
        # Fraction only allowed on the lowest-order (last) unit --
        # anything remaining after this is an error.
        if rest3 == "", do: {:ok, st.total_ms}, else: :error
      else
        parse_duration_loop(rest3, st)
      end
    end
  end

  defp take_digits(<<c, _::binary>> = s) when c in ~c"0123456789" do
    {digits, rest} = split_while_digit(s, [])
    {:ok, String.to_integer(digits), rest}
  end

  defp take_digits(_), do: :error

  defp split_while_digit(<<c, rest::binary>>, acc) when c in ~c"0123456789",
    do: split_while_digit(rest, [c | acc])

  defp split_while_digit(rest, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp take_fraction("." <> rest) do
    case split_while_digit(rest, []) do
      {"", _} ->
        :error

      {digits, tail} ->
        # Max 3 significant digits (milliseconds), excess truncated --
        # matches the original's `n < 3` cap exactly.
        {kept, _excess} = String.split_at(digits, min(String.length(digits), 3))
        padded = String.pad_trailing(kept, 3, "0")
        {:ok, String.to_integer(padded), true, tail}
    end
  end

  defp take_fraction(rest), do: {:ok, 0, false, rest}

  defp take_unit_char(""), do: :error
  defp take_unit_char(<<c::binary-size(1), rest::binary>>), do: {:ok, c, rest}

  defp classify_unit("Y", false), do: {:ok, 0, @ms_y}
  defp classify_unit("M", false), do: {:ok, 1, @ms_mo}
  defp classify_unit("W", false), do: {:ok, 99, @ms_w}
  defp classify_unit("D", false), do: {:ok, 2, @ms_d}
  defp classify_unit("H", true), do: {:ok, 3, @ms_h}
  defp classify_unit("M", true), do: {:ok, 4, @ms_mi}
  defp classify_unit("S", true), do: {:ok, 5, @ms_s}
  defp classify_unit(_, _), do: :error

  # W must stand alone (mixedBasicExtended) and appear at most once.
  defp check_week_rule("W", %{saw_any: true}), do: :error
  defp check_week_rule("W", %{in_time: true}), do: :error
  defp check_week_rule(_unit, %{saw_w: true}), do: :error
  defp check_week_rule(_unit, _st), do: :ok

  defp check_canonical_order(99, _last_rank), do: :ok
  defp check_canonical_order(rank, last_rank) when rank > last_rank, do: :ok
  defp check_canonical_order(_rank, _last_rank), do: :error

  @doc "ms -> ISO 8601 duration string (integer arithmetic only)."
  @spec format_duration_ms(integer()) :: String.t()
  def format_duration_ms(ms) do
    ms = max(ms, 0)
    total_s = div(ms, 1000)
    milli = rem(ms, 1000)
    h = div(total_s, 3600)
    total_s = total_s - h * 3600
    m = div(total_s, 60)
    s = rem(total_s, 60)

    h_part = if h > 0, do: "#{h}H", else: ""
    m_part = if m > 0, do: "#{m}M", else: ""

    s_part =
      if s > 0 or milli > 0 or (h == 0 and m == 0) do
        frac = if milli > 0, do: "." <> trim_trailing_zeros(pad3(milli)), else: ""
        "#{s}#{frac}S"
      else
        ""
      end

    "PT" <> h_part <> m_part <> s_part
  end

  defp pad3(n), do: n |> Integer.to_string() |> String.pad_leading(3, "0")
  defp trim_trailing_zeros(s), do: String.trim_trailing(s, "0")

  # --- STN: Floyd-Warshall consistency check, integer ms + sentinel ---

  defmodule STN do
    @moduledoc false
    defstruct idx: %{}, dist: %{}, size: 0
  end

  defp stn_new, do: %STN{}

  defp stn_add_point(%STN{idx: idx} = stn, p) do
    if Map.has_key?(idx, p) do
      stn
    else
      i = stn.size
      dist = Map.put(stn.dist, {i, i}, 0)
      %STN{stn | idx: Map.put(idx, p, i), dist: dist, size: i + 1}
    end
  end

  defp stn_add_constraint(stn, from, to, lo, hi) do
    stn = stn |> stn_add_point(from) |> stn_add_point(to)
    fi = stn.idx[from]
    ti = stn.idx[to]

    dist =
      stn.dist
      |> Map.update({fi, ti}, hi, &min(&1, hi))
      |> Map.update({ti, fi}, -lo, &min(&1, -lo))

    %STN{stn | dist: dist}
  end

  defp stn_consistent?(%STN{size: 0}), do: true

  defp stn_consistent?(%STN{size: n} = stn) do
    range = 0..(n - 1)

    final =
      Enum.reduce(range, stn.dist, fn k, d ->
        Enum.reduce(range, d, fn i, d ->
          dik = Map.get(d, {i, k}, @sentinel)

          if dik == @sentinel do
            d
          else
            Enum.reduce(range, d, fn j, d ->
              dkj = Map.get(d, {k, j}, @sentinel)

              if dkj == @sentinel do
                d
              else
                via = dik + dkj
                dij = Map.get(d, {i, j}, @sentinel)
                if via < dij, do: Map.put(d, {i, j}, via), else: d
              end
            end)
          end
        end)
      end)

    Enum.all?(range, fn i -> Map.get(final, {i, i}, @sentinel) >= 0 end)
  end

  # --- Sequential temporal check ---

  @doc """
  Builds a sequential STN from `plan` (a list of action-name strings)
  and `action_durations` (a map of action name -> ISO 8601 duration
  string) and returns temporal metadata. Actions with no duration entry
  are treated as `"PT0S"`. Sequential assumption: each action starts
  exactly when the previous one ends.
  """
  @spec check(
          [String.t()],
          %{String.t() => String.t()},
          String.t()
        ) :: %{
          consistent: boolean(),
          total: String.t(),
          origin: String.t(),
          steps: [%{action: String.t(), duration: String.t(), start: String.t(), end: String.t()}]
        }
  def check(plan, action_durations, origin_iso \\ "PT0S") do
    origin_ms = with({:ok, ms} <- parse_duration_ms(origin_iso), do: ms) || 0

    if plan == [] do
      %{consistent: true, total: "PT0S", origin: origin_iso, steps: []}
    else
      duration_of = fn name ->
        with iso when is_binary(iso) <- Map.get(action_durations, name),
             {:ok, ms} <- parse_duration_ms(iso) do
          {iso, ms}
        else
          _ -> {"PT0S", 0}
        end
      end

      {steps, stn, _prev_end, _current, total_ms} =
        Enum.reduce(
          Enum.with_index(plan),
          {[], stn_add_point(stn_new(), "t0"), "t0", origin_ms, 0},
          fn
            {name, i}, {steps, stn, prev_end, current, total_ms} ->
              {dur_iso, dur_ms} = duration_of.(name)

              step = %{
                action: name,
                duration: dur_iso,
                start: format_duration_ms(current),
                end: format_duration_ms(current + dur_ms)
              }

              a_s = "a#{i}_start"
              a_e = "a#{i}_end"

              stn =
                stn
                |> stn_add_constraint(prev_end, a_s, 0, 0)
                |> stn_add_constraint(a_s, a_e, dur_ms, dur_ms)

              {[step | steps], stn, a_e, current + dur_ms, total_ms + dur_ms}
          end
        )

      %{
        consistent: stn_consistent?(stn),
        total: format_duration_ms(total_ms),
        origin: origin_iso,
        steps: Enum.reverse(steps)
      }
    end
  end

  # --- Civil-calendar layer ---

  @doc "Parses \"YYYY-MM-DD\" (trailing content, e.g. a time part, ignored)."
  @spec parse_date(String.t()) :: {:ok, Date.t()} | :error
  def parse_date(s) when byte_size(s) >= 10 do
    case String.slice(s, 0, 10) do
      <<y::binary-size(4), "-", m::binary-size(2), "-", d::binary-size(2)>> ->
        with {year, ""} <- Integer.parse(y),
             {month, ""} <- Integer.parse(m),
             {day, ""} <- Integer.parse(d),
             {:ok, date} <- Date.new(year, month, day) do
          {:ok, date}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  def parse_date(_), do: :error

  defp last_day_of_month(year, month), do: :calendar.last_day_of_the_month(year, month)

  defp add_years(%Date{} = date, n) do
    new_year = date.year + n
    last_day = last_day_of_month(new_year, date.month)
    Date.new!(new_year, date.month, min(date.day, last_day))
  end

  defp add_months(%Date{} = date, n) do
    total = date.year * 12 + (date.month - 1) + n
    new_year = Integer.floor_div(total, 12)
    new_month = Integer.mod(total, 12) + 1
    last_day = last_day_of_month(new_year, new_month)
    Date.new!(new_year, new_month, min(date.day, last_day))
  end

  @doc """
  Civil-time-aware duration -> milliseconds. `cursor` (a `Date.t()`) is
  advanced for `Y`/`Mo` components so successive calls accumulate
  correctly through a plan -- `P1Y` from a leap-year date is 366 days;
  `P1M` from the 31st clamps to the target month's last valid day
  (e.g. Jan 31 + 1Mo -> Feb 28/29). Fractions on `Y`/`Mo` fall back to
  the fixed-day unit (calendar fractions are ambiguous), same as the
  original. `W`/`D`/`H`/`Mi`/`S` are unaffected by the cursor.
  """
  @spec civil_duration_ms(String.t(), Date.t()) :: {:ok, non_neg_integer(), Date.t()} | :error
  def civil_duration_ms("P", cursor), do: {:ok, 0, cursor}

  def civil_duration_ms("P" <> rest, cursor) when byte_size(rest) > 0 do
    civil_duration_loop(rest, cursor, %{
      total_ms: 0,
      in_time: false,
      saw_t: false,
      saw_w: false,
      saw_any: false,
      last_rank: -1
    })
  end

  def civil_duration_ms(_, _cursor), do: :error

  defp civil_duration_loop("", cursor, st), do: {:ok, st.total_ms, cursor}

  defp civil_duration_loop("T" <> rest, cursor, st) do
    cond do
      st.saw_t -> :error
      rest == "" -> :error
      true -> civil_duration_loop(rest, cursor, %{st | in_time: true, saw_t: true})
    end
  end

  defp civil_duration_loop(s, cursor, st) do
    with {:ok, whole, rest1} <- take_digits(s),
         {:ok, frac_ms_per_unit, has_frac, rest2} <- take_fraction(rest1),
         {:ok, unit_c, rest3} <- take_unit_char(rest2),
         {:ok, rank, unit_ms} <- classify_unit(unit_c, st.in_time),
         :ok <- check_week_rule(unit_c, st),
         :ok <- check_canonical_order(rank, st.last_rank) do
      {added_ms, new_cursor} =
        if not st.in_time and unit_c in ["Y", "M"] do
          before = cursor

          new_cursor =
            if unit_c == "Y", do: add_years(cursor, whole), else: add_months(cursor, whole)

          days = Date.diff(new_cursor, before)
          frac = if has_frac, do: frac_ms_per_unit * div(unit_ms, 1000), else: 0
          {days * @ms_d + frac, new_cursor}
        else
          frac = if has_frac, do: frac_ms_per_unit * div(unit_ms, 1000), else: 0
          {whole * unit_ms + frac, cursor}
        end

      st = %{
        st
        | total_ms: st.total_ms + added_ms,
          # check_week_rule/2 already errors on a prior saw_w: true, so
          # st.saw_w is always false by the time we reach this update.
          saw_w: unit_c == "W",
          saw_any: true,
          last_rank: if(rank == 99, do: st.last_rank, else: rank)
      }

      if has_frac do
        if rest3 == "", do: {:ok, st.total_ms, new_cursor}, else: :error
      else
        civil_duration_loop(rest3, new_cursor, st)
      end
    end
  end

  @doc """
  Civil-calendar-aware variant of `check/3`. `reference_date` (a
  `"YYYY-MM-DD"` string) makes `Y`/`Mo` durations use real calendar
  arithmetic; `nil` (or an unparseable date) falls back to `check/3`'s
  fixed-day (`parse_duration_ms/1`) behavior. The civil cursor
  accumulates through the plan, matching the original's per-action
  civil-date advancement.
  """
  @spec check_civil(
          [String.t()],
          %{String.t() => String.t()},
          String.t(),
          String.t() | nil
        ) :: map()
  def check_civil(plan, action_durations, origin_iso \\ "PT0S", reference_date \\ nil) do
    civil_cursor =
      case reference_date && parse_date(reference_date) do
        {:ok, date} -> date
        _ -> nil
      end

    origin_ms = with({:ok, ms} <- parse_duration_ms(origin_iso), do: ms) || 0

    if plan == [] do
      %{consistent: true, total: "PT0S", origin: origin_iso, steps: []}
    else
      duration_of = fn name, cursor ->
        iso = Map.get(action_durations, name)

        cond do
          !is_binary(iso) ->
            {"PT0S", 0, cursor}

          cursor ->
            case civil_duration_ms(iso, cursor) do
              {:ok, ms, new_cursor} -> {iso, ms, new_cursor}
              :error -> {iso, 0, cursor}
            end

          true ->
            case parse_duration_ms(iso) do
              {:ok, ms} -> {iso, ms, cursor}
              :error -> {iso, 0, cursor}
            end
        end
      end

      init = {[], stn_add_point(stn_new(), "t0"), "t0", origin_ms, 0, civil_cursor}

      {steps, stn, _prev_end, _current, total_ms, _cursor} =
        Enum.reduce(Enum.with_index(plan), init, fn
          {name, i}, {steps, stn, prev_end, current, total_ms, cursor} ->
            {dur_iso, dur_ms, new_cursor} = duration_of.(name, cursor)

            step = %{
              action: name,
              duration: dur_iso,
              start: format_duration_ms(current),
              end: format_duration_ms(current + dur_ms)
            }

            a_s = "a#{i}_start"
            a_e = "a#{i}_end"

            stn =
              stn
              |> stn_add_constraint(prev_end, a_s, 0, 0)
              |> stn_add_constraint(a_s, a_e, dur_ms, dur_ms)

            {[step | steps], stn, a_e, current + dur_ms, total_ms + dur_ms, new_cursor}
        end)

      %{
        consistent: stn_consistent?(stn),
        total: format_duration_ms(total_ms),
        origin: origin_iso,
        steps: Enum.reverse(steps)
      }
    end
  end
end
