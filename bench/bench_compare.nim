## Head-to-head benchmark: reni vs. nim-regex and Oniguruma, with PCRE2
## (interpreted and JIT) as a calibration point.
##
## All engines run the same patterns over the same subject inside the same
## process, using capture-producing findAll APIs. Full matches and captures
## are compared against reni's before timing. An engine that disagrees on a
## pattern is flagged, since its timing would not measure the same work.
##
## Run with:
##   nim c -d:release --opt:speed --mm:orc bench/bench_compare.nim
##   ./bench/bench_compare              # default 5_000 lines, 5 iterations
##   ./bench/bench_compare 20000 7      # lines, iterations
##   ./bench/bench_compare --md         # tables as Markdown

import std/[strformat, strutils]

import ../reni
from pkg/regex as nimregex import nil
import bench_common
import onig
import pcre2

type
  Engine = enum
    eReni = "reni"
    eNimRegex = "nim-regex"
    eOnig = "onig"
    ePcre2 = "pcre2"
    ePcre2Jit = "pcre2-jit"

  Compiled = object
    reni: Regex
    nimRegex: nimregex.Regex2
    onig: onig.OnigRegex
    pcre2: pcre2.Pcre2Code
    pcre2Jit: pcre2.Pcre2Code

  Scratch = ref object
    ctx: MatchContext
    region: ptr onig.OnigRegion
    data: pcre2.Pcre2MatchData

const
  TimeCol = 11
  NimRegexRevision {.strdefine.} = "unrecorded"

# ---------------------------------------------------------------- match loops
#
# One loop shape per engine, mirroring reni's `findAll`: search from `pos`,
# record the match, advance to the match end (one code point on a zero-width
# match), repeat.  reni's own loops run on `MatchScanner`, which is what
# `findAll` runs on; the foreign engines hand back an ovector, which reports
# what the attempt consumed, and `advanceOvector` below is the whole cursor
# rule such a match needs.  It is the deprecated `advanceAfterMatch` of the
# public API, kept here because here it is the right rule.  The `collect*` variants exist for the
# pre-timing agreement check; the `count*` variants are what gets timed.

proc advanceOvector(subject: string, mStart, mEnd: int): int {.inline.} =
  ## Next search position after a match that reported what it consumed.
  ## A zero-width match steps one code point, or ends the scan at the end.
  if mEnd == mStart:
    if mStart < subject.len:
      nextRunePos(subject, mStart)
    else:
      -1
  else:
    mEnd

proc collectReni(ctx: MatchContext, subject: string, regex: Regex): seq[MatchSpans] =
  var sc = initMatchScanner(subject)
  var m: Match
  while scanNext(sc, ctx, subject, regex, m):
    var captures: MatchSpans
    for span in m.boundaries:
      captures.add normalizeSpan(span.a, span.b)
    result.add captures

proc collectOnig(
    reg: onig.OnigRegex, subject: string, region: ptr onig.OnigRegion
): seq[MatchSpans] =
  var pos = 0
  while pos <= subject.len:
    if onig.checkedSearch(reg, subject, region, pos) < 0:
      break
    let mStart = region.beg[0].int
    let mEnd = region.ends[0].int
    var captures: MatchSpans
    for group in 0 ..< region.numRegs.int:
      captures.add normalizeSpan(region.beg[group].int, region.ends[group].int)
    result.add captures
    let nextPos = advanceOvector(subject, mStart, mEnd)
    if nextPos < 0:
      break
    pos = nextPos

proc collectPcre2(
    code: pcre2.Pcre2Code, subject: string, data: pcre2.Pcre2MatchData
): seq[MatchSpans] =
  var pos = 0
  while pos <= subject.len:
    let rc = pcre2.checkedMatch(code, subject, data, pos)
    if rc < 0:
      break
    let ov = pcre2.ovector(data)
    let mStart = ov[0].int
    let mEnd = ov[1].int
    var captures: MatchSpans
    for group in 0 ..< pcre2.ovectorCount(data):
      if group >= rc.int or ov[2 * group] == csize_t.high:
        captures.add (-1, -1)
      else:
        captures.add normalizeSpan(ov[2 * group].int, ov[2 * group + 1].int)
    result.add captures
    let nextPos = advanceOvector(subject, mStart, mEnd)
    if nextPos < 0:
      break
    pos = nextPos

proc countReni(ctx: MatchContext, subject: string, regex: Regex): int =
  var sc = initMatchScanner(subject)
  var m: Match
  while scanNext(sc, ctx, subject, regex, m):
    inc result

proc countOnig(reg: onig.OnigRegex, subject: string, region: ptr onig.OnigRegion): int =
  var pos = 0
  while pos <= subject.len:
    if onig.checkedSearch(reg, subject, region, pos) < 0:
      break
    inc result
    let nextPos = advanceOvector(subject, region.beg[0].int, region.ends[0].int)
    if nextPos < 0:
      break
    pos = nextPos

proc countPcre2(
    code: pcre2.Pcre2Code, subject: string, data: pcre2.Pcre2MatchData
): int =
  var pos = 0
  while pos <= subject.len:
    if pcre2.checkedMatch(code, subject, data, pos) <= 0:
      break
    inc result
    let nextPos =
      advanceOvector(subject, pcre2.ovector(data)[0].int, pcre2.ovector(data)[1].int)
    if nextPos < 0:
      break
    pos = nextPos

# -------------------------------------------------------------------- helpers

proc nimRegexPattern(pattern: string): string =
  # This workload names lhs/rhs. Leave lookbehind's (?<= / (?<! unchanged.
  pattern.replace("(?<lhs>", "(?P<lhs>").replace("(?<rhs>", "(?P<rhs>")

proc pcre2Pattern(pattern: string): string =
  # Bare Han selects Script_Extensions in PCRE2; Reni/Oniguruma use Script.
  if pattern == r"\p{Han}+": r"\p{sc=Han}+" else: pattern

proc collectNimRegex(subject: string, regex: nimregex.Regex2): seq[MatchSpans] =
  for m in nimregex.findAll(subject, regex):
    var captures = @[normalizeSpan(m.boundaries.a, m.boundaries.b + 1)]
    for span in m.captures:
      captures.add normalizeSpan(span.a, span.b + 1)
    result.add captures

proc countNimRegex(subject: string, regex: nimregex.Regex2): int =
  # The capture-producing iterator reuses its own scratch state for the scan.
  for m in nimregex.findAll(subject, regex):
    inc result

proc engineColumns(width = TimeCol): seq[(string, int)] =
  for e in Engine:
    result.add ($e, width)

# ------------------------------------------------------------------ one item

type
  Status = enum
    stOk = "ok"
    stUnsupported = "n/a" ## the engine rejected the pattern
    stLimit = "limit" ## reni hit its step limit

  ItemResult = object
    bench: Bench
    time: array[Engine, int64]
    status: array[Engine, Status]
    matches: int
    agree: string ## "" when every available engine agrees, else the first divergence
    disagreeing: seq[string] ## engines whose match sequence differs
    comparable: bool ## every engine ran and agreed
    bytes: int

proc runItem(
    b: Bench, subject: string, scratch: Scratch, warmup, iters: int
): ItemResult =
  result.bench = b
  result.bytes = subject.len

  var c: Compiled
  var have: array[Engine, bool]
  try:
    c.reni = re(b.pattern)
    have[eReni] = true
  except CatchableError:
    result.status[eReni] = stUnsupported
  try:
    c.nimRegex = nimregex.re2(nimRegexPattern(b.pattern), {nimregex.regexMultiline})
    have[eNimRegex] = true
  except nimregex.RegexError:
    result.status[eNimRegex] = stUnsupported
  try:
    c.onig = onig.compile(b.pattern)
    have[eOnig] = true
  except onig.OnigError:
    result.status[eOnig] = stUnsupported
  try:
    c.pcre2 = pcre2.compile(pcre2Pattern(b.pattern), jit = false)
    have[ePcre2] = true
    c.pcre2Jit = pcre2.compile(pcre2Pattern(b.pattern), jit = true)
    have[ePcre2Jit] = true
  except pcre2.Pcre2Error:
    if not have[ePcre2]:
      result.status[ePcre2] = stUnsupported
    result.status[ePcre2Jit] = stUnsupported
  # `c.reni` is garbage-collected; the C engines need explicit frees.
  defer:
    if have[eOnig]:
      onig.free(c.onig)
    if have[ePcre2]:
      pcre2.free(c.pcre2)
    if have[ePcre2Jit]:
      pcre2.free(c.pcre2Jit)

  if have[ePcre2]:
    scratch.data = pcre2.newMatchData(c.pcre2)
  defer:
    if have[ePcre2]:
      pcre2.free(scratch.data)

  # Match sequences first: timing an engine that computes something else
  # would be meaningless.
  var spans: array[Engine, seq[MatchSpans]]
  if have[eReni]:
    try:
      spans[eReni] = collectReni(scratch.ctx, subject, c.reni)
    except RegexError:
      have[eReni] = false
      result.status[eReni] = stLimit
  if have[eNimRegex]:
    spans[eNimRegex] = collectNimRegex(subject, c.nimRegex)
  if have[eOnig]:
    spans[eOnig] = collectOnig(c.onig, subject, scratch.region)
  if have[ePcre2]:
    spans[ePcre2] = collectPcre2(c.pcre2, subject, scratch.data)
  if have[ePcre2Jit]:
    spans[ePcre2Jit] = collectPcre2(c.pcre2Jit, subject, scratch.data)

  let reference =
    if have[eReni]:
      eReni
    elif have[eOnig]:
      eOnig
    else:
      ePcre2
  result.matches = spans[reference].len
  for e in Engine:
    if have[e] and e != reference and spans[e] != spans[reference]:
      result.disagreeing.add $e
      if result.agree.len == 0:
        result.agree = fmt"vs {reference}, " & diffSummary(spans[reference], spans[e])

  for e in Engine:
    if not have[e]:
      result.time[e] = -1
      continue
    result.time[e] =
      case e
      of eReni:
        measure(
          warmup,
          iters,
          proc(): int =
            countReni(scratch.ctx, subject, c.reni),
          expectedMatches = spans[e].len,
        ).best
      of eNimRegex:
        measure(
          warmup,
          iters,
          proc(): int =
            countNimRegex(subject, c.nimRegex),
          expectedMatches = spans[e].len,
        ).best
      of eOnig:
        measure(
          warmup,
          iters,
          proc(): int =
            countOnig(c.onig, subject, scratch.region),
          expectedMatches = spans[e].len,
        ).best
      of ePcre2:
        measure(
          warmup,
          iters,
          proc(): int =
            countPcre2(c.pcre2, subject, scratch.data),
          expectedMatches = spans[e].len,
        ).best
      of ePcre2Jit:
        measure(
          warmup,
          iters,
          proc(): int =
            countPcre2(c.pcre2Jit, subject, scratch.data),
          expectedMatches = spans[e].len,
        ).best

  result.comparable = result.agree.len == 0
  for e in Engine:
    if not have[e]:
      result.comparable = false

proc cell(r: ItemResult, e: Engine): string =
  if r.time[e] >= 0:
    fmtMs(r.time[e])
  else:
    $r.status[e]

# ----------------------------------------------------------------- benchmarks

proc runAll(corpora: array[Corpus, string], warmup, iters: int): seq[ItemResult] =
  let scratch = Scratch(ctx: newMatchContext(8), region: onig.newRegion())
  defer:
    onig.free(scratch.region)
  for b in Benchmarks:
    result.add runItem(b, corpora[b.corpus], scratch, warmup, iters)

proc printSummary(results: seq[ItemResult], markdown: bool) =
  ## The headline: one row per engine over every comparable item.
  var
    total: array[Engine, int64]
    bytes = 0
    counted = 0
  for r in results:
    if not r.comparable:
      continue
    inc counted
    bytes += r.bytes
    for e in Engine:
      total[e] += r.time[e]
  if counted == 0:
    return

  var fastest = 0.0
  for e in Engine:
    fastest = max(fastest, 1.0 / total[e].float)

  echo ""
  echo fmt"## Summary ({counted} of {results.len} items comparable across all engines)"
  echo ""
  let table = initTableWriter(
    [("engine", 12), ("total", TimeCol), ("scan rate", 14), ("", 32)], markdown
  )
  for e in Engine:
    table.row(
      $e, fmtMs(total[e]), fmtMiBs(bytes, total[e]), bar(1.0 / total[e].float, fastest)
    )

proc printByCategory(results: seq[ItemResult], markdown: bool) =
  ## Where the time goes, per benchmark category.
  echo ""
  echo "## By category"
  echo ""
  var cols = @[("category", 14), ("items", 6)]
  cols.add engineColumns()
  let table = initTableWriter(cols, markdown)

  var seen: seq[string]
  for r in results:
    if r.bench.category notin seen:
      seen.add r.bench.category
  for category in seen:
    var
      total: array[Engine, int64]
      items = 0
      included = 0
    for r in results:
      if r.bench.category != category:
        continue
      inc items
      if not r.comparable:
        continue
      inc included
      for e in Engine:
        total[e] += r.time[e]
    let itemCount =
      if included == items:
        $items
      else:
        $included & "/" & $items
    var cells = @[category, itemCount]
    for e in Engine:
      cells.add fmtMs(total[e])
    table.row(cells)
  echo ""
  echo "Item counts give comparable/total when any pattern is unsupported or " &
    "disagrees. Every engine column sums the same comparable items."

proc printItems(results: seq[ItemResult], iters: int, markdown: bool) =
  echo ""
  echo fmt"## Per item (best of {iters})"
  echo ""
  var cols = @[("category", 14), ("item", 18), ("corpus", 7)]
  cols.add engineColumns()
  cols.add [("matches", 8), ("agree", 5)]
  let table = initTableWriter(cols, markdown)
  for r in results:
    var cells = @[r.bench.category, r.bench.label, $r.bench.corpus]
    for e in Engine:
      cells.add cell(r, e)
    cells.add $r.matches
    cells.add(
      if r.disagreeing.len == 0:
        "yes"
      else:
        "no (" & r.disagreeing.join(", ") & ")"
    )
    table.row(cells)

  for r in results:
    if r.disagreeing.len == 0:
      continue
    echo ""
    let engines = r.disagreeing.join(", ")
    echo fmt"`{r.bench.category}/{r.bench.label}`: {engines} disagree " &
      fmt"({r.agree}); the item is left out of the summary."

proc benchCompile(iters: int, markdown: bool) =
  ## Pattern compilation cost, per compile.
  echo ""
  echo fmt"## Compile, per item ({iters} compiles, time per compile)"
  echo ""
  var cols = @[("category", 14), ("item", 18)]
  cols.add engineColumns()
  let table = initTableWriter(cols, markdown)

  var total: array[Engine, int64]
  var comparable = 0
  for b in Benchmarks:
    let pattern = b.pattern
    let pcrePattern = pcre2Pattern(pattern)
    var best: array[Engine, int64]
    for e in Engine:
      best[e] = -1

    var reniBox = newSeq[Regex](iters)
    try:
      best[eReni] = measure(
        1,
        5,
        proc(): int =
          for i in 0 ..< iters:
            reniBox[i] = re(pattern)
          iters,
      ).best
    except CatchableError:
      discard

    var nimRegexBox = newSeq[nimregex.Regex2](iters)
    let nimPattern = nimRegexPattern(pattern)
    try:
      best[eNimRegex] = measure(
        1,
        5,
        proc(): int =
          for i in 0 ..< iters:
            nimRegexBox[i] = nimregex.re2(nimPattern, {nimregex.regexMultiline})
          iters,
      ).best
    except nimregex.RegexError:
      discard

    var onigBox = newSeq[onig.OnigRegex](iters)
    try:
      best[eOnig] = measure(
        1,
        5,
        proc(): int =
          for i in 0 ..< iters:
            onigBox[i] = onig.compile(pattern)
          for i in 0 ..< iters:
            onig.free(onigBox[i])
          iters,
      ).best
    except onig.OnigError:
      discard

    var pcreBox = newSeq[pcre2.Pcre2Code](iters)
    for jit in [false, true]:
      let jitEnabled = jit
      let e = if jitEnabled: ePcre2Jit else: ePcre2
      try:
        best[e] = measure(
          1,
          5,
          proc(): int =
            for i in 0 ..< iters:
              pcreBox[i] = pcre2.compile(pcrePattern, jit = jitEnabled)
            for i in 0 ..< iters:
              pcre2.free(pcreBox[i])
            iters,
        ).best
      except pcre2.Pcre2Error:
        discard

    var shared = true
    for e in Engine:
      if best[e] < 0:
        shared = false
    if shared:
      inc comparable
      for e in Engine:
        total[e] += best[e]
    var cells = @[b.category, b.label]
    for e in Engine:
      if best[e] >= 0:
        cells.add fmtUs(best[e] div iters)
      else:
        cells.add $stUnsupported
    table.row(cells)

  var cells = @["TOTAL", $comparable & " shared items"]
  for e in Engine:
    cells.add fmtUs(total[e] div iters)
  table.row(cells)

proc printPatterns(markdown: bool) =
  ## The workload itself, so a reader can see what each item stands for.
  echo ""
  echo "## Patterns"
  echo ""
  let table = initTableWriter([("category", 14), ("item", 18), ("regex", 0)], markdown)
  for b in Benchmarks:
    table.row(b.category, b.label, "`" & b.pattern & "`")

proc main() =
  let (lineCount, iters, markdown) = parseArgs()
  let warmup = 2

  onig.initOniguruma()
  defer:
    onig.finalizeOniguruma()

  let corpora = subjects(lineCount)
  let jitState = if pcre2.jitAvailable(): "available" else: "unavailable"

  echo fmt"# reni vs nim-regex {NimRegexRevision} vs Oniguruma {onig.onigVersionString()} vs PCRE2"
  echo ""
  echo fmt"{Benchmarks.len} benchmark items across " &
    "literals, character classes, alternation, quantifiers, anchors, captures, " &
    "lookaround, Unicode, no-match scans and backtracking. Each item finds " &
    fmt"every match in a ~{corpora[cCode].len div 1024} KiB subject: `code` is " &
    fmt"{lineCount} lines of synthetic Nim source, `text` is UTF-8 " &
    "Japanese/ASCII prose of the same size. Best of " & $iters & " runs."
  echo ""
  echo "Same subjects and non-overlapping matching semantics, same process. UTF-8 throughout: " &
    "`ONIG_SYNTAX_ONIGURUMA` for Oniguruma, " &
    "`PCRE2_UTF | PCRE2_UCP | PCRE2_MULTILINE` for PCRE2 " &
    fmt"(JIT {jitState}), so `\w`, `\d`, `\b` and `^` mean the same thing " &
    "in these corpora. nim-regex uses `re2` with `regexMultiline` and its " &
    "capture-producing `findAll` iterator. Its named groups use `(?P<name>...)`; " &
    "PCRE2 uses `\\p{sc=Han}` for Reni/Oniguruma script semantics. " &
    "The `agree` column compares every full-match and capture span; only " &
    "supported items where all five agree feed the summary and category totals."
  echo ""
  echo environmentNote()

  let results = runAll(corpora, warmup, iters)
  printSummary(results, markdown)
  printByCategory(results, markdown)
  printItems(results, iters, markdown)
  benchCompile(200, markdown)
  printPatterns(markdown)

when isMainModule:
  main()
