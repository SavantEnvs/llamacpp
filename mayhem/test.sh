#!/usr/bin/env bash
#
# llamacpp/mayhem/test.sh — run the ctest parse-surface tests, verify their BEHAVIORAL OUTPUT,
# and emit a CTRF summary. exit 0 iff no test failed.
#
# PATCH-grade oracle covering exactly the harnessed parsers:
#   test-grammar-parser          — asserts GBNF grammar parser produces expected rule sets.
#   test-json-schema-to-grammar  — asserts json_schema_to_grammar() emits expected GBNF;
#                                  prints "All resolves_to_string tests passed!" on success.
#   test-gguf                    — round-trips GGUF read/write; asserts parsed metadata.
#
# Anti-reward-hack: we run the test binaries DIRECTLY (not via ctest) and grep each for a
# known-answer string from its output. A neutered exit(0) stub produces NO output, so the
# grep fails → test fails → oracle fails → CTRF emits failed>0 → verify-repo FAIL.
# This makes the oracle sabotage-proof: the test.sh cannot pass if the test programs are no-ops.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

BUILDDIR="$SRC/mayhem-tests"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if ! command -v cmake >/dev/null 2>&1 || ! command -v ctest >/dev/null 2>&1; then
  echo "cmake/ctest not available — cannot run the test suite" >&2
  emit_ctrf "llamacpp-ctest" 0 1 0; exit 2
fi

# Configure a clean NORMAL-flags tree (no sanitizers / fuzzer instrumentation) and build only the
# three parse-surface tests that exercise the harnessed parsers.
env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
  cmake -S "$SRC" -B "$BUILDDIR" -G Ninja \
    -DBUILD_SHARED_LIBS=OFF -DGGML_NO_OPENMP=1 \
    -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TOOLS=OFF \
    -DLLAMA_BUILD_TESTS=ON -DLLAMA_CURL=OFF -DGGML_NATIVE=OFF \
    -DGGML_AVX=OFF -DGGML_AVX2=OFF -DGGML_FMA=OFF -DGGML_F16C=OFF -DGGML_BMI2=OFF -DGGML_SSE42=OFF \
    -DCMAKE_BUILD_TYPE=Release >/dev/null 2>&1 \
  || { echo "cmake configure failed" >&2; emit_ctrf "llamacpp-ctest" 0 1 0; exit 2; }

env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
  cmake --build "$BUILDDIR" -j"$MAYHEM_JOBS" \
    --target test-grammar-parser test-json-schema-to-grammar test-gguf >/dev/null 2>&1 \
  || { echo "test build failed" >&2; emit_ctrf "llamacpp-ctest" 0 1 0; exit 2; }

# llama.cpp cmake places binaries in $BUILDDIR/bin/ (CMAKE_RUNTIME_OUTPUT_DIRECTORY = bin/).
BINDIR="$BUILDDIR/bin"

# Verify test binaries are actually built (not stubs).
for bin in "$BINDIR/test-grammar-parser" \
           "$BINDIR/test-json-schema-to-grammar" \
           "$BINDIR/test-gguf"; do
  if [ ! -x "$bin" ]; then
    echo "ERROR: test binary missing: $bin" >&2
    emit_ctrf "llamacpp-ctest" 0 1 0; exit 2
  fi
done

PASSED=0; FAILED=0

# ── test-grammar-parser ──
# Output (stderr): "Testing grammar: ..." for each grammar case.
# A real run prints many "Testing grammar:" lines. An exit(0) stub prints nothing.
run_grammar() {
  out2=$("$BINDIR/test-grammar-parser" 2>&1); rc=$?
  # Verify BOTH: the binary exits 0 AND its stderr contains a behavioral marker.
  if [ "$rc" -eq 0 ] && printf '%s\n' "$out2" | grep -q "Testing grammar:"; then
    echo "PASS: test-grammar-parser (exit=$rc, output verified)"; return 0
  else
    echo "FAIL: test-grammar-parser (exit=$rc, behavioral output missing or exit non-zero)"
    printf '%s\n' "$out2" | tail -5; return 1
  fi
}
if run_grammar; then PASSED=$(( PASSED + 1 )); else FAILED=$(( FAILED + 1 )); fi

# ── test-json-schema-to-grammar ──
# Prints "All resolves_to_string tests passed!" on stderr when the resolves_to_string tests pass.
# A neutered exit(0) stub would produce no output → grep fails.
run_json_schema() {
  out2=$("$BINDIR/test-json-schema-to-grammar" 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && printf '%s\n' "$out2" | grep -q "All resolves_to_string tests passed"; then
    echo "PASS: test-json-schema-to-grammar (exit=$rc, output verified)"; return 0
  else
    echo "FAIL: test-json-schema-to-grammar (exit=$rc, expected output not found)"
    printf '%s\n' "$out2" | tail -5; return 1
  fi
}
if run_json_schema; then PASSED=$(( PASSED + 1 )); else FAILED=$(( FAILED + 1 )); fi

# ── test-gguf ──
# Prints "N/M tests passed" to stdout on success (and "OK" on success / "FAIL" on failure).
# A neutered exit(0) stub would produce no output → grep fails.
run_gguf() {
  out2=$("$BINDIR/test-gguf" 42 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && printf '%s\n' "$out2" | grep -qE "[0-9]+/[0-9]+ tests passed"; then
    echo "PASS: test-gguf (exit=$rc, output verified)"; return 0
  else
    echo "FAIL: test-gguf (exit=$rc, expected 'N/M tests passed' output not found)"
    printf '%s\n' "$out2" | tail -10; return 1
  fi
}
if run_gguf; then PASSED=$(( PASSED + 1 )); else FAILED=$(( FAILED + 1 )); fi

emit_ctrf "llamacpp-ctest" "$PASSED" "$FAILED" 0
