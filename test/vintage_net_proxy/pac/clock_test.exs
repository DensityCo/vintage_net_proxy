defmodule VintageNetProxy.PAC.ClockTest do
  use ExUnit.Case, async: true

  alias VintageNetProxy.PAC.Clock

  # 2025-01-07 is a Tuesday.
  @tuesday_noon ~N[2025-01-07 12:00:00]
  # 2025-01-04 is a Saturday.
  @saturday_noon ~N[2025-01-04 12:00:00]

  describe "in_weekday_range?/3 — single day" do
    test "matches when today is the target weekday" do
      assert Clock.in_weekday_range?("TUE", "TUE", @tuesday_noon)
    end

    test "doesn't match when today is a different weekday" do
      refute Clock.in_weekday_range?("MON", "MON", @tuesday_noon)
    end
  end

  describe "in_weekday_range?/3 — range" do
    test "MON-FRI covers Tuesday" do
      assert Clock.in_weekday_range?("MON", "FRI", @tuesday_noon)
    end

    test "MON-FRI doesn't cover Saturday" do
      refute Clock.in_weekday_range?("MON", "FRI", @saturday_noon)
    end

    test "SAT-SUN covers Saturday" do
      assert Clock.in_weekday_range?("SAT", "SUN", @saturday_noon)
    end

    test "FRI-MON wraps and covers Saturday" do
      assert Clock.in_weekday_range?("FRI", "MON", @saturday_noon)
    end

    test "FRI-MON wraps and covers Sunday" do
      sunday = ~N[2025-01-05 00:00:00]
      assert Clock.in_weekday_range?("FRI", "MON", sunday)
    end

    test "FRI-MON does not cover Tuesday" do
      refute Clock.in_weekday_range?("FRI", "MON", @tuesday_noon)
    end
  end

  describe "in_weekday_range?/3 — invalid input" do
    test "unrecognized day string returns false" do
      refute Clock.in_weekday_range?("XYZ", "FRI", @tuesday_noon)
      refute Clock.in_weekday_range?("MON", "XYZ", @tuesday_noon)
    end
  end

  describe "in_time_range?/7 — single hour" do
    test "matches mid-hour" do
      assert Clock.in_time_range?(12, 0, 0, 13, 0, 0, @tuesday_noon)
    end

    test "matches exactly at start" do
      assert Clock.in_time_range?(12, 0, 0, 13, 0, 0, ~N[2025-01-07 12:00:00])
    end

    test "doesn't match exactly at end (half-open)" do
      refute Clock.in_time_range?(12, 0, 0, 13, 0, 0, ~N[2025-01-07 13:00:00])
    end

    test "doesn't match outside the hour" do
      refute Clock.in_time_range?(9, 0, 0, 10, 0, 0, @tuesday_noon)
    end
  end

  describe "in_time_range?/7 — hh:mm and hh:mm:ss" do
    test "covers 9:30-17:00 at noon" do
      assert Clock.in_time_range?(9, 30, 0, 17, 0, 0, @tuesday_noon)
    end

    test "doesn't cover 9:30-17:00 at 9:15" do
      refute Clock.in_time_range?(9, 30, 0, 17, 0, 0, ~N[2025-01-07 09:15:00])
    end

    test "second-precision boundary" do
      # range: 12:00:00 inclusive, 12:00:05 exclusive
      assert Clock.in_time_range?(12, 0, 0, 12, 0, 5, ~N[2025-01-07 12:00:03])
      refute Clock.in_time_range?(12, 0, 0, 12, 0, 5, ~N[2025-01-07 12:00:05])
    end
  end

  describe "in_time_range?/7 — invalid input" do
    test "out-of-range hour returns false" do
      refute Clock.in_time_range?(99, 0, 0, 100, 0, 0, @tuesday_noon)
    end

    test "out-of-range minute returns false" do
      refute Clock.in_time_range?(9, 99, 0, 17, 0, 0, @tuesday_noon)
    end
  end

  describe "now/1 — real wallclock" do
    test ":utc returns a NaiveDateTime" do
      assert %NaiveDateTime{} = Clock.now(:utc)
    end

    test ":local returns a NaiveDateTime" do
      assert %NaiveDateTime{} = Clock.now(:local)
    end
  end

  describe "in_date_range?/2 — single unit" do
    test "{:day, d}" do
      assert Clock.in_date_range?({:day, 7}, @tuesday_noon)
      refute Clock.in_date_range?({:day, 8}, @tuesday_noon)
    end

    test "{:month, m}" do
      assert Clock.in_date_range?({:month, 1}, @tuesday_noon)
      refute Clock.in_date_range?({:month, 2}, @tuesday_noon)
    end

    test "{:year, y}" do
      assert Clock.in_date_range?({:year, 2025}, @tuesday_noon)
      refute Clock.in_date_range?({:year, 2024}, @tuesday_noon)
    end
  end

  describe "in_date_range?/2 — same-unit range" do
    test "{:day_range, d1, d2} — inclusive" do
      assert Clock.in_date_range?({:day_range, 1, 10}, @tuesday_noon)
      assert Clock.in_date_range?({:day_range, 7, 7}, @tuesday_noon)
      refute Clock.in_date_range?({:day_range, 10, 20}, @tuesday_noon)
    end

    test "{:day_range, d1, d2} — wraps when d2 < d1" do
      # Day 7 falls in "25-10" if we wrap (covers 25-31, 1-10).
      assert Clock.in_date_range?({:day_range, 25, 10}, @tuesday_noon)
    end

    test "{:month_range, m1, m2} — inclusive" do
      assert Clock.in_date_range?({:month_range, 1, 3}, @tuesday_noon)
      refute Clock.in_date_range?({:month_range, 4, 6}, @tuesday_noon)
    end

    test "{:month_range, m1, m2} — wraps when m2 < m1" do
      # January falls in NOV..FEB wrap.
      assert Clock.in_date_range?({:month_range, 11, 2}, @tuesday_noon)
    end

    test "{:year_range, y1, y2} — inclusive, no wrap" do
      assert Clock.in_date_range?({:year_range, 2024, 2026}, @tuesday_noon)
      refute Clock.in_date_range?({:year_range, 2026, 2024}, @tuesday_noon)
    end
  end

  describe "in_date_range?/2 — compound ranges" do
    test "{:day_month_range, d1, m1, d2, m2} within a year" do
      # Jan 1 - Jun 30
      assert Clock.in_date_range?({:day_month_range, 1, 1, 30, 6}, @tuesday_noon)
      refute Clock.in_date_range?({:day_month_range, 1, 7, 30, 12}, @tuesday_noon)
    end

    test "{:day_month_range} wraps the year boundary" do
      # Dec 15 - Feb 28 — Jan 7 falls in this wrap.
      assert Clock.in_date_range?({:day_month_range, 15, 12, 28, 2}, @tuesday_noon)
    end

    test "{:month_year_range} — no wrap" do
      assert Clock.in_date_range?({:month_year_range, 12, 2024, 3, 2025}, @tuesday_noon)
      refute Clock.in_date_range?({:month_year_range, 6, 2025, 12, 2025}, @tuesday_noon)
    end

    test "{:full_date_range} — no wrap" do
      assert Clock.in_date_range?(
               {:full_date_range, 1, 1, 2025, 31, 1, 2025},
               @tuesday_noon
             )

      refute Clock.in_date_range?(
               {:full_date_range, 1, 2, 2025, 31, 12, 2025},
               @tuesday_noon
             )
    end
  end

  describe "month_num/1" do
    test "valid months" do
      assert Clock.month_num("JAN") == 1
      assert Clock.month_num("JUN") == 6
      assert Clock.month_num("DEC") == 12
    end

    test "unrecognized → nil" do
      assert Clock.month_num("BAD") == nil
      assert Clock.month_num("jan") == nil
    end
  end

  describe "in_date_range?/2 — raw-args API" do
    # 2025-01-07. Exercise the classification + shape-matching the
    # list form does internally, with no Predicate in the loop.

    test "[day]" do
      assert Clock.in_date_range?([7], @tuesday_noon)
      refute Clock.in_date_range?([8], @tuesday_noon)
    end

    test "[month_name]" do
      assert Clock.in_date_range?(["JAN"], @tuesday_noon)
      refute Clock.in_date_range?(["FEB"], @tuesday_noon)
    end

    test "[year]" do
      assert Clock.in_date_range?([2025], @tuesday_noon)
      refute Clock.in_date_range?([2024], @tuesday_noon)
    end

    test "[day, day]" do
      assert Clock.in_date_range?([1, 10], @tuesday_noon)
    end

    test "[month, month] with wrap" do
      assert Clock.in_date_range?(["NOV", "FEB"], @tuesday_noon)
    end

    test "[day, month, day, month]" do
      assert Clock.in_date_range?([1, "JAN", 30, "JUN"], @tuesday_noon)
    end

    test "[day, month, year, day, month, year]" do
      assert Clock.in_date_range?(
               [1, "JAN", 2025, 31, "JAN", 2025],
               @tuesday_noon
             )
    end

    test "mixed types that don't form a valid shape → false" do
      # [day, year] isn't an allowed sequence.
      refute Clock.in_date_range?([15, 2025], @tuesday_noon)
    end

    test "unrecognized month → false" do
      refute Clock.in_date_range?(["BAD"], @tuesday_noon)
    end

    test "int outside [1..31] ∪ [1000..9999] → false" do
      refute Clock.in_date_range?([99], @tuesday_noon)
    end

    test "wrong arity → false" do
      refute Clock.in_date_range?([1, 2, 3], @tuesday_noon)
      refute Clock.in_date_range?([], @tuesday_noon)
    end
  end
end
