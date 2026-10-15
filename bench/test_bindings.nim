import std/unittest
import onig, pcre2

proc onigGetRetryLimitInMatch(): culong {.
  importc: "onig_get_retry_limit_in_match", header: "<oniguruma.h>"
.}

proc onigSetRetryLimitInMatch(
  limit: culong
): cint {.importc: "onig_set_retry_limit_in_match", header: "<oniguruma.h>".}

suite "benchmark C binding error contracts":
  test "Oniguruma raw errors remain available to the differential fuzzer":
    initOniguruma()
    defer:
      finalizeOniguruma()
    let regex = onig.compile(r"(a+)+$")
    defer:
      onig.free(regex)
    let region = newRegion()
    defer:
      onig.free(region)
    let oldLimit = onigGetRetryLimitInMatch()
    defer:
      discard onigSetRetryLimitInMatch(oldLimit)
    discard onigSetRetryLimitInMatch(1)
    check onig.search(regex, "aaaaaaaaaaaab", region) < OnigMismatch
    expect OnigError:
      discard onig.checkedSearch(regex, "aaaaaaaaaaaab", region)
    check onig.search(regex, "b", region) == OnigMismatch
    check onig.checkedSearch(regex, "b", region) == OnigMismatch

  test "PCRE2 raw errors remain available to the differential fuzzer":
    let regex = pcre2.compile("a", jit = false)
    defer:
      pcre2.free(regex)
    let data = newMatchData(regex)
    defer:
      pcre2.free(data)
    check pcre2.match(regex, "a", data, start = 2) < Pcre2ErrorNoMatch
    expect Pcre2Error:
      discard pcre2.checkedMatch(regex, "a", data, start = 2)
    check pcre2.match(regex, "b", data) == Pcre2ErrorNoMatch
    check pcre2.checkedMatch(regex, "b", data) == Pcre2ErrorNoMatch
