import std/[strutils, unittest]
import ../bench/bench_common

suite "benchmark correctness checks":
  test "capture differences are detected when full matches agree":
    let reference = @[@[(0, 3), (0, 1)]]
    let other = @[@[(0, 3), (1, 2)]]
    check diffSummary(reference, reference) == ""
    check "group #1" in diffSummary(reference, other)

  test "capture counts and match counts are compared":
    check "capture slots" in diffSummary(@[@[(0, 1), (0, 1)]], @[@[(0, 1)]])
    check "match count" in diffSummary(@[@[(0, 1)]], @[])

  test "unmatched captures are distinct from empty captures":
    check normalizeSpan(-1, -2) == (-1, -1)
    check normalizeSpan(-1, -1) == (-1, -1)
    check normalizeSpan(2, 2) == (2, 2)
    check normalizeSpan(-1, -1) != normalizeSpan(2, 2)

  test "every timed sample is checked against the validated count":
    var calls = 0
    expect AssertionDefect:
      discard measure(
        0,
        3,
        proc(): int =
          inc calls
          if calls == 1: 0 else: 1,
        expectedMatches = 1,
      )
    check calls == 1

  test "warmup samples are checked too":
    expect AssertionDefect:
      discard measure(
        1,
        1,
        proc(): int =
          0,
        expectedMatches = 1,
      )

  test "single-engine measurements reject changing counts":
    var calls = 0
    expect AssertionDefect:
      discard measure(
        0,
        3,
        proc(): int =
          inc calls
          calls,
      )
    check calls == 2

  test "a constant count preserves timing and the final count":
    let timing = measure(
      2,
      3,
      proc(): int =
        4,
      expectedMatches = 4,
    )
    check timing.matches == 4
    check timing.best >= 0
    check timing.median >= timing.best
