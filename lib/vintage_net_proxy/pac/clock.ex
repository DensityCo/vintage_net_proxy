defmodule VintageNetProxy.PAC.Clock do
  @moduledoc """
  Wallclock helpers for PAC's `weekdayRange` and `timeRange` predicates.

  `in_weekday_range?/3` and `in_time_range?/7` take a
  `NaiveDateTime` parameter — the "current time" — so they're pure
  given their arguments. The `now/1` function here is the default
  source of that time, used by `PAC.Predicate` when no `:now`
  override is supplied; tests pass a stub function returning a fixed
  time.

  Named `Clock` rather than `Time` to avoid colliding with Elixir's
  built-in `Time` module.
  """

  @doc """
  Default "current time" function. `tz` is `:utc` or `:local`; the
  result is a `NaiveDateTime`. Built from Erlang's `:calendar`
  module (no timezone database required).
  """
  @spec now(:utc | :local) :: NaiveDateTime.t()
  def now(:utc) do
    {date, time} = :calendar.universal_time()
    NaiveDateTime.from_erl!({date, time})
  end

  def now(:local) do
    {date, time} = :calendar.local_time()
    NaiveDateTime.from_erl!({date, time})
  end

  @doc """
  True if `now`'s weekday is between `wd1` and `wd2` inclusive.

  Days are PAC's three-letter strings (`"MON"`, `"TUE"`, …, `"SUN"`).
  When `wd2 < wd1` the range wraps: `"FRI"`–`"MON"` includes Fri,
  Sat, Sun, Mon. Unrecognized day strings return false.
  """
  @spec in_weekday_range?(String.t(), String.t(), NaiveDateTime.t()) :: boolean()
  def in_weekday_range?(wd1, wd2, now) do
    with n1 when not is_nil(n1) <- weekday_num(wd1),
         n2 when not is_nil(n2) <- weekday_num(wd2),
         today <- now |> NaiveDateTime.to_date() |> Date.day_of_week() do
      in_weekday?(today, n1, n2)
    else
      _ -> false
    end
  end

  defp in_weekday?(t, n1, n2) when n1 <= n2, do: t >= n1 and t <= n2
  defp in_weekday?(t, n1, n2), do: t >= n1 or t <= n2

  defp weekday_num("MON"), do: 1
  defp weekday_num("TUE"), do: 2
  defp weekday_num("WED"), do: 3
  defp weekday_num("THU"), do: 4
  defp weekday_num("FRI"), do: 5
  defp weekday_num("SAT"), do: 6
  defp weekday_num("SUN"), do: 7
  defp weekday_num(_), do: nil

  @doc """
  True if `now`'s time-of-day is in `[h1:m1:s1, h2:m2:s2)`.

  Half-open: start inclusive, end exclusive. So `timeRange(9, 17)`
  covering business hours becomes
  `in_time_range?(9, 0, 0, 17, 0, 0, now)` — true at 16:59:59,
  false at 17:00:00.

  No wrap-around. To express a night-shift range crossing midnight,
  a PAC script needs two `timeRange` calls combined with `||`.
  Out-of-range hour/minute/second values return false.
  """
  @spec in_time_range?(
          integer(),
          integer(),
          integer(),
          integer(),
          integer(),
          integer(),
          NaiveDateTime.t()
        ) :: boolean()
  def in_time_range?(h1, m1, s1, h2, m2, s2, now) do
    with {:ok, start} <- Time.new(h1, m1, s1),
         {:ok, finish} <- Time.new(h2, m2, s2),
         cur <- NaiveDateTime.to_time(now) do
      Time.compare(cur, start) != :lt and Time.compare(cur, finish) == :lt
    else
      _ -> false
    end
  end

  @doc """
  True if `now`'s date falls in the supplied range.

  Two input shapes:

    * **Raw value list** — `[String.t() | integer()]` straight from
      a `dateRange(...)` PAC call. Strings are interpreted as
      month names (`"JAN"`–`"DEC"`); ints in `[1..31]` are days;
      ints in `[1000..9999]` are years. Allowed arities are 1, 2,
      4, and 6 with specific type sequences (see below). Invalid
      input returns false.
    * **Pre-classified spec tuple** — one of `{:day, d}`,
      `{:day_range, d1, d2}`, `{:month, m}`,
      `{:month_range, m1, m2}`, `{:year, y}`,
      `{:year_range, y1, y2}`,
      `{:day_month_range, d1, m1, d2, m2}`,
      `{:month_year_range, m1, y1, m2, y2}`, or
      `{:full_date_range, d1, m1, y1, d2, m2, y2}`. Useful when
      callers already have typed values.

  Wrap semantics: day, month, and day-month ranges wrap when the
  end is before the start; year, month-year, and full-date ranges
  do not.

  Unrecognized shapes return false.
  """
  @spec in_date_range?([String.t() | integer()] | tuple(), NaiveDateTime.t()) :: boolean()
  def in_date_range?(args, now) when is_list(args) do
    case classify_args(args) do
      {:ok, spec} -> in_date_range?(spec, now)
      :error -> false
    end
  end

  def in_date_range?(spec, now) when is_tuple(spec) do
    date = NaiveDateTime.to_date(now)
    check_date(spec, date)
  end

  defp classify_args(values) do
    classified = Enum.map(values, &classify_one/1)

    if Enum.any?(classified, &(&1 == :error)) do
      :error
    else
      match_shape(classified)
    end
  end

  defp match_shape([{:day, d}]), do: {:ok, {:day, d}}
  defp match_shape([{:month, m}]), do: {:ok, {:month, m}}
  defp match_shape([{:year, y}]), do: {:ok, {:year, y}}
  defp match_shape([{:day, d1}, {:day, d2}]), do: {:ok, {:day_range, d1, d2}}
  defp match_shape([{:month, m1}, {:month, m2}]), do: {:ok, {:month_range, m1, m2}}
  defp match_shape([{:year, y1}, {:year, y2}]), do: {:ok, {:year_range, y1, y2}}

  defp match_shape([{:day, d1}, {:month, m1}, {:day, d2}, {:month, m2}]),
    do: {:ok, {:day_month_range, d1, m1, d2, m2}}

  defp match_shape([{:month, m1}, {:year, y1}, {:month, m2}, {:year, y2}]),
    do: {:ok, {:month_year_range, m1, y1, m2, y2}}

  defp match_shape([
         {:day, d1},
         {:month, m1},
         {:year, y1},
         {:day, d2},
         {:month, m2},
         {:year, y2}
       ]),
       do: {:ok, {:full_date_range, d1, m1, y1, d2, m2, y2}}

  defp match_shape(_), do: :error

  defp classify_one(s) when is_binary(s) do
    case month_num(s) do
      nil -> :error
      n -> {:month, n}
    end
  end

  defp classify_one(n) when is_integer(n) and n in 1..31, do: {:day, n}
  defp classify_one(n) when is_integer(n) and n in 1000..9999, do: {:year, n}
  defp classify_one(_), do: :error

  defp check_date({:day, d}, date), do: date.day == d
  defp check_date({:day_range, d1, d2}, date), do: in_wrap_range?(date.day, d1, d2)

  defp check_date({:month, m}, date), do: date.month == m
  defp check_date({:month_range, m1, m2}, date), do: in_wrap_range?(date.month, m1, m2)

  defp check_date({:year, y}, date), do: date.year == y
  defp check_date({:year_range, y1, y2}, date), do: date.year >= y1 and date.year <= y2

  defp check_date({:day_month_range, d1, m1, d2, m2}, date) do
    cur = {date.month, date.day}
    start = {m1, d1}
    finish = {m2, d2}

    if start <= finish do
      cur >= start and cur <= finish
    else
      cur >= start or cur <= finish
    end
  end

  defp check_date({:month_year_range, m1, y1, m2, y2}, date) do
    cur = {date.year, date.month}
    cur >= {y1, m1} and cur <= {y2, m2}
  end

  defp check_date({:full_date_range, d1, m1, y1, d2, m2, y2}, date) do
    cur = {date.year, date.month, date.day}
    cur >= {y1, m1, d1} and cur <= {y2, m2, d2}
  end

  defp check_date(_, _), do: false

  defp in_wrap_range?(v, lo, hi) when lo <= hi, do: v >= lo and v <= hi
  defp in_wrap_range?(v, lo, hi), do: v >= lo or v <= hi

  @doc """
  Month-name (`"JAN"` … `"DEC"`) to integer 1–12, or `nil` for
  unrecognized input. Public so `PAC.Predicate` can use it when
  classifying `dateRange` args.
  """
  @spec month_num(String.t()) :: 1..12 | nil
  def month_num("JAN"), do: 1
  def month_num("FEB"), do: 2
  def month_num("MAR"), do: 3
  def month_num("APR"), do: 4
  def month_num("MAY"), do: 5
  def month_num("JUN"), do: 6
  def month_num("JUL"), do: 7
  def month_num("AUG"), do: 8
  def month_num("SEP"), do: 9
  def month_num("OCT"), do: 10
  def month_num("NOV"), do: 11
  def month_num("DEC"), do: 12
  def month_num(_), do: nil
end
