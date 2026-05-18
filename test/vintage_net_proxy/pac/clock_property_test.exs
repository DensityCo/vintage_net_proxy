defmodule VintageNetProxy.PAC.ClockPropertyTest do
  @moduledoc """
  Property-based tests for `VintageNetProxy.PAC.Clock`.

  Wraparound logic in weekday / time / date ranges is the textbook
  place humans get arithmetic wrong: `FRI`–`MON` should match
  Fri/Sat/Sun/Mon, `Nov`–`Feb` should span year-end (for day-month
  ranges), `Nov 2024`–`Feb 2025` should NOT wrap (year-month ranges
  are strictly increasing). Example tests check named boundaries;
  these properties pin down the algebra across the full input space.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias VintageNetProxy.PAC.Clock

  @weekdays ~w(MON TUE WED THU FRI SAT SUN)
  @months ~w(JAN FEB MAR APR MAY JUN JUL AUG SEP OCT NOV DEC)

  # --- Generators ---

  # Valid NaiveDateTime in 2000..2050. Days capped at 28 so every
  # (year, month, day) is a real date regardless of month length.
  defp naive_datetime do
    gen all year <- StreamData.integer(2000..2050),
            month <- StreamData.integer(1..12),
            day <- StreamData.integer(1..28),
            hour <- StreamData.integer(0..23),
            minute <- StreamData.integer(0..59),
            second <- StreamData.integer(0..59) do
      NaiveDateTime.new!(year, month, day, hour, minute, second)
    end
  end

  defp weekday, do: StreamData.member_of(@weekdays)
  defp month, do: StreamData.member_of(@months)

  # Valid hour/minute/second components (no wrap into next field).
  defp hms do
    gen all h <- StreamData.integer(0..23),
            m <- StreamData.integer(0..59),
            s <- StreamData.integer(0..59) do
      {h, m, s}
    end
  end

  # --- month_num/1 ---

  property "month_num returns 1..12 for each known abbreviation, nil otherwise" do
    check all m <- StreamData.string(:alphanumeric, max_length: 8) do
      case Clock.month_num(m) do
        nil ->
          refute m in @months

        n when n in 1..12 ->
          assert m in @months
          assert Enum.at(@months, n - 1) == m
      end
    end
  end

  property "every known month string maps to its 1-indexed position" do
    check all m <- month() do
      assert Clock.month_num(m) == Enum.find_index(@months, &(&1 == m)) + 1
    end
  end

  # --- in_weekday_range?/3 ---

  property "single-day range matches iff today's weekday equals the requested day" do
    check all wd <- weekday(),
              now <- naive_datetime() do
      today = now |> NaiveDateTime.to_date() |> Date.day_of_week()
      expected = today == Enum.find_index(@weekdays, &(&1 == wd)) + 1
      assert Clock.in_weekday_range?(wd, wd, now) == expected
    end
  end

  property "MON–SUN matches every day" do
    check all now <- naive_datetime() do
      assert Clock.in_weekday_range?("MON", "SUN", now)
    end
  end

  property "unrecognized weekday strings always return false" do
    check all bogus <- StreamData.string(:alphanumeric, min_length: 1, max_length: 8),
              real <- weekday(),
              now <- naive_datetime() do
      if bogus not in @weekdays do
        refute Clock.in_weekday_range?(bogus, real, now)
        refute Clock.in_weekday_range?(real, bogus, now)
        refute Clock.in_weekday_range?(bogus, bogus, now)
      end
    end
  end

  property "wrap range agrees with the bit-level definition for any date" do
    check all wd1 <- weekday(),
              wd2 <- weekday(),
              now <- naive_datetime() do
      n1 = Enum.find_index(@weekdays, &(&1 == wd1)) + 1
      n2 = Enum.find_index(@weekdays, &(&1 == wd2)) + 1
      today = now |> NaiveDateTime.to_date() |> Date.day_of_week()

      expected =
        if n1 <= n2,
          do: today >= n1 and today <= n2,
          else: today >= n1 or today <= n2

      assert Clock.in_weekday_range?(wd1, wd2, now) == expected
    end
  end

  # --- in_time_range?/7 ---

  property "empty interval (start == end) is false for any now" do
    check all {h, m, s} <- hms(),
              now <- naive_datetime() do
      refute Clock.in_time_range?(h, m, s, h, m, s, now)
    end
  end

  property "start > end never matches (no wrap)" do
    check all {h1, m1, s1} <- hms(),
              {h2, m2, s2} <- hms(),
              now <- naive_datetime() do
      start = {h1, m1, s1}
      finish = {h2, m2, s2}

      if start > finish do
        refute Clock.in_time_range?(h1, m1, s1, h2, m2, s2, now)
      end
    end
  end

  property "half-open [start, end) agrees with the Time.compare definition" do
    check all {h1, m1, s1} <- hms(),
              {h2, m2, s2} <- hms(),
              now <- naive_datetime() do
      cur = NaiveDateTime.to_time(now)
      start = Time.new!(h1, m1, s1)
      finish = Time.new!(h2, m2, s2)

      expected =
        Time.compare(cur, start) != :lt and Time.compare(cur, finish) == :lt

      assert Clock.in_time_range?(h1, m1, s1, h2, m2, s2, now) == expected
    end
  end

  property "out-of-range hour / minute / second returns false" do
    check all bad_hour <- StreamData.integer(24..48),
              now <- naive_datetime() do
      refute Clock.in_time_range?(bad_hour, 0, 0, 23, 59, 59, now)
      refute Clock.in_time_range?(0, 0, 0, bad_hour, 0, 0, now)
    end
  end

  # --- in_date_range?/2 ---

  property "{:day, d} matches iff now.day == d" do
    check all d <- StreamData.integer(1..28),
              now <- naive_datetime() do
      assert Clock.in_date_range?({:day, d}, now) == (now.day == d)
    end
  end

  property "{:month, m} matches iff now.month == m" do
    check all m <- StreamData.integer(1..12),
              now <- naive_datetime() do
      assert Clock.in_date_range?({:month, m}, now) == (now.month == m)
    end
  end

  property "{:year, y} matches iff now.year == y" do
    check all y <- StreamData.integer(1900..2100),
              now <- naive_datetime() do
      assert Clock.in_date_range?({:year, y}, now) == (now.year == y)
    end
  end

  property "{:year_range, y1, y2} does NOT wrap; matches iff y1 <= now.year <= y2" do
    check all y1 <- StreamData.integer(1900..2100),
              y2 <- StreamData.integer(1900..2100),
              now <- naive_datetime() do
      expected = now.year >= y1 and now.year <= y2
      assert Clock.in_date_range?({:year_range, y1, y2}, now) == expected
    end
  end

  property "{:day_range, d1, d2} wraps when d2 < d1" do
    check all d1 <- StreamData.integer(1..31),
              d2 <- StreamData.integer(1..31),
              now <- naive_datetime() do
      expected =
        if d1 <= d2,
          do: now.day >= d1 and now.day <= d2,
          else: now.day >= d1 or now.day <= d2

      assert Clock.in_date_range?({:day_range, d1, d2}, now) == expected
    end
  end

  property "list-shape single-day arg agrees with tuple-shape" do
    check all d <- StreamData.integer(1..28),
              now <- naive_datetime() do
      assert Clock.in_date_range?([d], now) == Clock.in_date_range?({:day, d}, now)
    end
  end

  property "list-shape single-month arg agrees with tuple-shape" do
    check all m <- month(),
              now <- naive_datetime() do
      n = Clock.month_num(m)
      assert Clock.in_date_range?([m], now) == Clock.in_date_range?({:month, n}, now)
    end
  end

  property "list-shape with an unrecognized arity returns false" do
    # Arities the dateRange grammar doesn't define: 3, 5, 7+.
    check all arity <- StreamData.member_of([0, 3, 5, 7, 8]),
              args <- StreamData.list_of(StreamData.integer(1..28), length: arity),
              now <- naive_datetime() do
      refute Clock.in_date_range?(args, now)
    end
  end

  property "in_date_range? never raises for arbitrary list args" do
    check all args <-
                StreamData.list_of(
                  StreamData.one_of([
                    StreamData.integer(),
                    StreamData.string(:printable, max_length: 8)
                  ]),
                  max_length: 6
                ),
              now <- naive_datetime() do
      result = Clock.in_date_range?(args, now)
      assert result == true or result == false
    end
  end
end
