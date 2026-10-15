## Compare native mixed captures with the private-name workaround previously
## required by TextMate clients. Compile and search are timed separately;
## every numbered capture must agree before a case is measured.
##
## nim c -d:release bench/bench_textmate.nim
## ./bench/bench_textmate [rounds=10000] [samples=7]
import std/[os, strformat, strutils]
import ../reni
import bench_common

type CaptureCase = object
  label, native, workaround, subject: string

const Cases = [
  CaptureCase(
    label: "tag",
    native: r"(</?)(?<tag>[A-Za-z][\w:-]*)(\s*)",
    workaround: r"(?<private1></?)(?<tag>[A-Za-z][\w:-]*)(?<private3>\s*)",
    subject: "<section class=\"panel\">",
  ),
  CaptureCase(
    label: "quoted backref",
    native: "(['\"])(?<body>[^'\"]*)\\1",
    workaround: "(?<private1>['\"])(?<body>[^'\"]*)\\k<private1>",
    subject: "\"a quoted attribute value\"",
  ),
  CaptureCase(
    label: "paired backrefs",
    native: r"(a)(?<name>b)\1\2",
    workaround: r"(?<private1>a)(?<name>b)\k<private1>\k<name>",
    subject: "abab",
  ),
  CaptureCase(
    label: "relative backrefs",
    native: r"(a)(?<name>b)\k<-2>\k<-1>",
    workaround: r"(?<private1>a)(?<name>b)\k<private1>\k<name>",
    subject: "abab",
  ),
  CaptureCase(
    label: "capture conditional",
    native: r"(a)?(?<name>b)(?(1)c|d)",
    workaround: r"(?<private1>a)?(?<name>b)(?(<private1>)c|d)",
    subject: "abc",
  ),
]

proc main() =
  let rounds =
    if paramCount() > 0:
      parseInt(paramStr(1))
    else:
      10000
  let samples =
    if paramCount() > 1:
      parseInt(paramStr(2))
    else:
      7
  if rounds <= 0 or samples <= 0:
    quit("rounds and samples must be positive")
  let searchRounds = rounds * 10
  echo environmentNote()
  echo fmt"rounds={rounds}, samples={samples}, warmup=2; median wall times"
  echo fmt"Search uses {searchRounds} rounds to reduce short-subject noise."
  let table = initTableWriter(
    [("case", 20), ("mode", 12), ("compile", 15), ("search", 15)], false
  )
  for item in Cases:
    let subject = item.subject
    let native = re(item.native, {rfCaptureGroup})
    let workaround = re(item.workaround)
    let expected = search(item.subject, workaround)
    doAssert expected.found
    doAssert search(item.subject, native).boundaries == expected.boundaries
    for useNative in [false, true]:
      let source = if useNative: item.native else: item.workaround
      let flags: RegexFlags =
        if useNative:
          {rfCaptureGroup}
        else:
          {}
      let compileTime = measure(
        2,
        samples,
        proc(): int =
          for _ in 0 ..< rounds:
            result += re(source, flags).captureCount,
      )
      let regex = re(source, flags)
      let ctx = newMatchContext()
      var matched: Match
      let searchTime = measure(
        2,
        samples,
        proc(): int =
          for _ in 0 ..< searchRounds:
            searchIntoCtx(ctx, subject, regex, matched)
            result += matched.groupCount,
      )
      doAssert compileTime.matches == rounds * native.captureCount
      doAssert searchTime.matches == searchRounds * expected.groupCount
      table.row(
        item.label,
        if useNative: "native" else: "workaround",
        fmtMs(compileTime.median),
        fmtMs(searchTime.median),
      )

proc benchAnchors() =
  let rounds =
    if paramCount() > 0:
      parseInt(paramStr(1))
    else:
      10000
  let samples =
    if paramCount() > 1:
      parseInt(paramStr(2))
    else:
      7
  let searchRounds = rounds * 10
  const Sources = [
    r"(\A|\G)([a-z]+)|([0-9]+)", r"((?!)|\G)([a-z]+)|([0-9]+)",
    r"(\A|(?!))([a-z]+)|([0-9]+)", r"((?!)|(?!))([a-z]+)|([0-9]+)",
  ]
  const Options: array[4, MatchOptions] = [
    {}, {moNotBeginString}, {moNotBeginPosition}, {moNotBeginString, moNotBeginPosition}
  ]
  let regex = re(Sources[0])
  var variants: array[4, Regex]
  for i, source in Sources:
    variants[i] = re(source)
    doAssert search("foobar123", regex, options = Options[i]).boundaries ==
      search("foobar123", variants[i]).boundaries
  echo ""
  echo "Anchor options: compile one grammar rule; search cycles all four option sets."
  let table = initTableWriter([("mode", 20), ("compile", 15), ("search", 15)], false)
  for mode in 0 .. 1:
    let useOptions = mode == 1
    let compileTime = measure(
      2,
      samples,
      proc(): int =
        for _ in 0 ..< rounds:
          if useOptions:
            result += re(Sources[0]).captureCount
          else:
            for source in Sources:
              result += re(source).captureCount,
    )
    let ctx = newMatchContext()
    var matched: Match
    let searchTime = measure(
      2,
      samples,
      proc(): int =
        for _ in 0 ..< searchRounds:
          for i in 0 ..< Options.len:
            if useOptions:
              searchIntoCtx(ctx, "foobar123", regex, matched, options = Options[i])
            else:
              # Borrow immutable variants instead of deep-copying their tables.
              let variant {.cursor.} = variants[i]
              searchIntoCtx(ctx, "foobar123", variant, matched)
            doAssert matched.found
            result += matched.matchSpan.a + matched.matchSpan.b,
    )
    doAssert compileTime.matches == rounds * 3 * (if useOptions: 1 else: 4)
    doAssert searchTime.matches == searchRounds * 33
    table.row(
      if useOptions: "per-call options" else: "four variants",
      fmtMs(compileTime.median),
      fmtMs(searchTime.median),
    )

main()
benchAnchors()
