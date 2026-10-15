# Benchmarks

Two benchmarks share one workload (`bench_common.nim`): 29 items grouped into
ten categories — literals, character classes, alternation, quantifiers, anchors,
captures, lookaround, Unicode, no-match scans and backtracking — each run over
one of two same-sized subjects:

| corpus | content |
| --- | --- |
| `code` | synthetic Nim source, ASCII-heavy, built by cycling 10 sample lines |
| `text` | mixed Japanese / ASCII prose, UTF-8 multibyte |

| File | What it measures |
| --- | --- |
| `bench_reni.nim` | reni alone: per-item wall time and throughput |
| `bench_compare.nim` | reni vs. nim-regex vs. Oniguruma vs. PCRE2 (interpreted and JIT), in the same process |
| `bench_common.nim` | shared patterns, subject builder, timing and formatting |
| `onig.nim` | minimal FFI bindings to libonig (benchmark-only) |
| `pcre2.nim` | minimal FFI bindings to libpcre2-8 (benchmark-only) |
| `RESULTS.md` | a captured `bench_compare` run |

## Requirements

The comparison's Nim dependencies live in `bench/benchmarks.nimble`, separately
from the library's requirements. Install them with Atlas from this directory:

```sh
cd bench
atlas --project:. init
atlas install
```

This fetches nim-regex HEAD and unicodedb into `bench/deps` and generates
`bench/nim.cfg`. To refresh HEAD later, run `atlas update regex`. Record the
resolved commit in a captured run, or use `atlas pin` / `atlas rep` to reproduce
a particular dependency checkout.

`bench_compare` also links against Oniguruma and PCRE2. Install both development
packages (`oniguruma` / `libonig-dev` and `pcre2` / `libpcre2-dev`) so that
`pkg-config --libs oniguruma` / `pkg-config --libs libpcre2-8` and their headers
resolve; the build falls back to `-lonig` / `-lpcre2-8` when `pkg-config` has no
entry.

PCRE2 is not the subject of the comparison — it is a calibration point. Reading
reni against Oniguruma alone cannot tell a fast reference from a slow one, so
the table also carries PCRE2's interpreter (an engine of the same class as
Oniguruma) and its JIT (a different class entirely).

## Running

After installing the benchmark dependencies, run from `bench/`:

```sh
nim c -d:release --opt:speed --mm:orc bench_reni.nim
./bench_reni [lines] [iterations] [--md]      # default: 5000 lines, 5 iterations

nim c -d:release --opt:speed --mm:orc \
  -d:nimRegexRevision="$(git -C deps/regex rev-parse HEAD)" bench_compare.nim
./bench_compare [lines] [iterations] [--md]   # default: 5000 lines, 5 iterations
```

`--md` prints the tables as Markdown instead of aligned text. Every run starts
with the engine versions, the machine, the build and the invocation, so a
captured run stays self-describing:

```sh
./bench_compare 5000 7 --md > RESULTS.md
```

## Methodology

- Every engine finds all non-overlapping matches on the same subject. Reni
  uses `MatchScanner` with a reused `MatchContext`; Oniguruma uses `onig_search`
  with a reused `OnigRegion`; PCRE2 uses `pcre2_match` with reused match data.
  nim-regex uses its capture-producing `findAll` iterator, which retains its
  own scratch state during a scan. `findAllBounds` is deliberately excluded
  because it disables captures.
- Patterns use UTF-8: `ONIG_SYNTAX_ONIGURUMA` for Oniguruma,
  `PCRE2_UTF | PCRE2_UCP | PCRE2_MULTILINE` for PCRE2, and `regexMultiline`
  with nim-regex's default Unicode mode. nim-regex spells the named groups
  `(?P<lhs>...)` / `(?P<rhs>...)`. PCRE2 uses `\p{sc=Han}+` for the workload's
  `\p{Han}+`, matching Script rather than Script_Extensions. The latter also
  matches punctuation in this corpus and would produce different spans.
- Before timing, every engine's full matches and numbered captures are compared
  span by span against Reni's. Ends are normalized to half-open byte offsets,
  with unmatched captures kept distinct from empty ones. The `agree` column
  reports agreement among supported engines and the first divergence appears
  below the table.
- Summary and category totals use only items supported by **all five** engines
  with identical output. Partial category counts show comparable/total, so every
  engine column still measures the same work. nim-regex HEAD currently rejects
  the possessive quantifier, backreference, and Han script property: 26 of the
  29 items are shared. The per-item table retains every engine's individual
  timings and marks unsupported patterns `n/a`.
- An engine that rejects a pattern outright shows `n/a`; reni hitting its step
  limit shows `limit`. Neither stops the rest of the run.
- Each pattern is warmed up, then timed over N iterations; the table reports the
  best sample (least noise), and `bench_reni` also reports the median. Every
  warmup and timed scan must return the validated match count; these assertions
  execute outside the timed interval. Pattern compilation is excluded from
  search measurements and has its own table. Compilation totals also use the
  subset supported by all five engines.
- Tables carry measured times only. Ratios are left to the reader: which
  baseline is meaningful depends on the question being asked, and the totals
  are dominated by the slowest pattern.

## Reading a run

`bench_compare` prints, in this order:

1. **What was measured** — workload, engine configuration, machine, invocation.
2. **Summary** — one row per engine: total search time, scan rate in MiB/s
   (higher is better), and a bar proportional to that rate. This is the part to
   quote; everything below it is evidence.
3. **By category** — where the time goes, so a weak spot is visible without
   reading 29 rows.
4. **Per item** — the individual measurements behind the two tables above.
5. **Compile, per item** — pattern compilation cost (`re` vs. `onig_new` vs.
   `pcre2_compile`, with and without a JIT pass).
6. **Patterns** — the regex behind each item, so the workload is inspectable.

## Checking the harness

The pure-Nim correctness helper tests run with the library's ordinary test
suite, or individually from the repository root:

```sh
nim c -r tests/test_bench_common.nim
# Requires the C reference libraries:
nim c -r bench/test_bindings.nim
```

`Benchmark smoke tests` CI builds the comparison in release mode on Nim 2.0.16
and stable, checks all supported outputs on a small corpus, and verifies that
only the three documented nim-regex patterns are unavailable. Raw C bindings
retain runtime error codes for the differential fuzzer; the benchmark uses
`checkedSearch` / `checkedMatch` wrappers to raise on errors. Binding regression
tests cover this distinction and preserve ordinary no-match behavior. CI builds
Atlas 0.16.3 with Nim 2.2.12 before selecting the benchmark compiler, so Atlas's
compiler requirements do not prevent the Nim 2.0.16 comparison. It checks
correctness and table coverage; timing thresholds are deliberately absent.

## TextMate captures and anchor options

```sh
nim c -d:release -o:/tmp/reni_bench_textmate bench/bench_textmate.nim
/tmp/reni_bench_textmate 10000 9
```

This separate short-subject benchmark checks every capture span before timing.
It compares `rfCaptureGroup` against the former client workaround of assigning
private names to ordinary groups and rewriting numeric references. Compile time
excludes the client's rewrite itself, so it understates the work avoided.
Search uses one reused context and result, with compilation excluded.

The anchor case compares compiling four source variants of one rule against
compiling it once and using `MatchOptions`. Search performs the same number of
calls, cycling all four option combinations; it borrows variant regexes to
avoid charging deep copies to that baseline. Both modes use the same context
and agree on all numbered captures.

On an Apple M3 Pro, macOS arm64, Nim 2.2.12, release/ORC, 10,000 rounds,
100,000 search rounds, two warmups and median of nine samples (2026-10-11), native mixed-capture
compilation took about 14–23% less time on these five small patterns.
Per-call anchor options reduced the anchor case's compile time from about
222 ms to 52 ms, and search time from 159 ms to 112 ms. The compile saving
includes the intended reduction from four compiled patterns to one; the
search saving includes avoiding repeated binding to different trees.

These are focused API workloads, not a claim about whole-document TextMate
throughput or a general speedup for existing callers. Run the harness on the
target machine to measure its effect there.
