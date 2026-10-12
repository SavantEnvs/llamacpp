#!/usr/bin/env bash
#
# llamacpp/mayhem/build.sh — build ALL OSS-Fuzz harnesses as sanitized libFuzzer targets
# (+ standalone reproducers) so the Mayhem integration matches OSS-Fuzz parity (§6.2 item 12).
#
# Harnesses (from https://github.com/google/oss-fuzz/tree/master/projects/llamacpp/fuzzers):
#   fuzz_grammar             — drives llama_grammar_parser::parse() on raw GBNF input.
#   fuzz_json_to_grammar     — parses JSON then runs json_schema_to_grammar() (schema path).
#   fuzz_load_model          — writes input to a temp file; runs GGUF model loader.
#   fuzz_apply_template      — drives llama_chat_apply_template() (chat-template surface).
#   fuzz_inference           — writes a fuzzed GGUF model, loads + runs minimal inference.
#   fuzz_structured          — writes a fuzzed GGUF with kv-overrides, loads model.
#   fuzz_structurally_created— creates a syntactically-valid GGUF via gguf_* API, then loads it.
#   fuzz_tokenizer_{tok}     — loads a vocab-only model from an embedded header, tokenizes input.
#     variants: aquila, baichuan, bge, bpe, command_r, deepseek_coder, falcon, gpt_2, qwen2, spm
#
# Build contract: CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/OUT/STANDALONE_FUZZ_MAIN from base ENV.
# Libraries compiled WITH $SANITIZER_FLAGS+$DEBUG_FLAGS (instrumented code, not just harness).
# x86-64 BASELINE: GGML_NATIVE=OFF, advanced ISA extensions OFF (portable baseline; ggml does dispatch).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Parallelism: `nproc` reports the host's cores under `docker --cpus N`, so a 64-core host would start
# 64 sanitized clang/ld jobs on a 16-CPU quota (memory pressure, throttling). Cap at the cgroup quota.
cpu_jobs() {
  local n q p
  n="$(nproc)"
  if [ -r /sys/fs/cgroup/cpu.max ]; then
    read -r q p < /sys/fs/cgroup/cpu.max || true
  elif [ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]; then
    q="$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us)"; p="$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)"
  fi
  if [[ "${q:-max}" =~ ^[0-9]+$ ]] && [[ "${p:-0}" =~ ^[0-9]+$ ]] && [ "${p:-0}" -gt 0 ]; then
    q=$(( (q + p - 1) / p ))
    [ "$q" -ge 1 ] && [ "$q" -lt "$n" ] && n="$q"
  fi
  echo "$n"
}

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${OUT:=/mayhem}"
: "${MAYHEM_JOBS:=$(cpu_jobs)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE OUT MAYHEM_JOBS

cd "$SRC"

HARNESS_DIR="$SRC/mayhem/harnesses"

# ── 1) Configure + build the llama.cpp static libraries WITH sanitizers (CPU-only, baseline x86-64) ─
# Coverage instrumentation for libFuzzer: -fsanitize=fuzzer-no-link on the library objects so the
# parser objects carry edge coverage; the harness link supplies the libFuzzer runtime itself.
BUILD="$SRC/mayhem-build"
COVFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link"
cmake -S "$SRC" -B "$BUILD" -G Ninja \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_NO_OPENMP=1 \
  -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TOOLS=OFF \
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_CURL=OFF \
  -DGGML_NATIVE=OFF \
  -DGGML_AVX=OFF -DGGML_AVX2=OFF -DGGML_FMA=OFF -DGGML_F16C=OFF -DGGML_BMI2=OFF -DGGML_SSE42=OFF \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="$COVFLAGS" -DCMAKE_CXX_FLAGS="$COVFLAGS"

# The harnesses reference only these members of llama-common (arg/chat/jinja/download/httplib/... are
# never linked), so compile just them and archive them ourselves instead of building the whole target.
COMMON_SRCS="common fit json-schema-to-grammar json log ngram-cache ngram-map ngram-mod \
             reasoning-budget sampling speculative trie unicode"
COMMON_OBJS=""
for src in $COMMON_SRCS; do COMMON_OBJS="$COMMON_OBJS common/CMakeFiles/llama-common.dir/$src.cpp.o"; done
ninja -C "$BUILD" -j"$MAYHEM_JOBS" llama llama-common-base $COMMON_OBJS

# ── 2) Link flags shared by every harness ──────────────────────────────────────────────────────
# Lib order matters: llama-common (and its build-info base) before llama, llama before ggml.
LIBS="-L$BUILD/common -lllama-common -lllama-common-base \
      -L$BUILD/src -lllama \
      -L$BUILD/ggml/src -lggml -lggml-cpu -lggml-base"
# Include roots: fuzz_grammar pulls private internals (llama-grammar.h); others need gguf.h, common.h.
FLAGS="-std=c++17 -Iggml/include -Iggml/src -Iinclude -Isrc -Icommon -Ivendor -I./ \
       -DNDEBUG -Wno-deprecated-declarations -include cstring -include cstdio"

# lld links these ~100 MB sanitized binaries ~5x faster than GNU ld (34 links, one per fuzzer/standalone).
LDFLAGS_FAST=""
if command -v ld.lld >/dev/null 2>&1; then LDFLAGS_FAST="-fuse-ld=lld"; fi

# ── 3) Harness graph, driven by ninja so a re-run only redoes what changed ─────────────────────────
# Every harness is compiled and linked twice: libFuzzer (-> $OUT/<name>) + standalone reproducer
# (-> $OUT/<name>-standalone, linked against $STANDALONE_FUZZ_MAIN, no libFuzzer runtime). Rebuilding
# all 34 binaries on every build.sh run (~100 MB each) dominated an empty-diff rebuild; with the graph
# below an unchanged tree costs a no-op and a changed library relinks only what depends on it.
# NOTE: leak detection is disabled per-target via the Mayhemfile cmd's `-detect_leaks=0` libFuzzer
# flag. Mayhem alone owns the ASAN/LSan runtime option set, so no compiled-in default-options
# override is linked in here.
HNINJA="$BUILD/harness.ninja"
HOBJ="$BUILD/harness-obj"
mkdir -p "$HOBJ" "$BUILD/harness-log"
LIBFILES="$BUILD/common/libllama-common.a $BUILD/common/libllama-common-base.a $BUILD/src/libllama.a \
          $BUILD/ggml/src/libggml.a $BUILD/ggml/src/libggml-cpu.a $BUILD/ggml/src/libggml-base.a"

# The tokenizer harness embeds a vocab .gguf, selected by a #define (one binary per vocab type). The
# model headers are generated with an assembler .incbin instead of a C array: a ~10 MB model as
# "0x..," text takes minutes to compile, once per harness. Rewritten only when their content changes,
# so an unchanged tree keeps the objects that include them.
MODEL_HDRS="$BUILD/model_headers"
mkdir -p "$MODEL_HDRS"
gen_model_header() {
  local name="$1" file="$2"
  # The harness expects variable names like models_ggml_vocab_bert_bge_gguf (what `xxd -i` derives
  # from "models/ggml-vocab-bert-bge.gguf").
  local basename var
  basename="$(basename "$file")"
  var="$(printf 'models/%s' "$basename" | sed 's/[^A-Za-z0-9]/_/g')"
  cat > "$MODEL_HDRS/${name}.h.new" <<HDR
__asm__(".section .rodata\n.balign 16\n.globl ${var}\n${var}:\n.incbin \"${file}\"\n.previous");
extern unsigned char ${var}[];
unsigned int ${var}_len = $(stat -c %s "$file");
HDR
  if cmp -s "$MODEL_HDRS/${name}.h.new" "$MODEL_HDRS/${name}.h" 2>/dev/null; then
    rm -f "$MODEL_HDRS/${name}.h.new"
  else
    mv -f "$MODEL_HDRS/${name}.h.new" "$MODEL_HDRS/${name}.h"
  fi
}

# Generate model headers from the committed mayhem/models/ directory.
# The upstream models/ is excluded by .dockerignore; vocab files are committed to mayhem/models/
# so they are available in the Docker build context.
gen_model_header model_header_bge         "$SRC/mayhem/models/ggml-vocab-bert-bge.gguf"
gen_model_header model_header_bpe         "$SRC/mayhem/models/ggml-vocab-llama-bpe.gguf"
gen_model_header model_header_spm         "$SRC/mayhem/models/ggml-vocab-llama-spm.gguf"
gen_model_header model_header_qwen2       "$SRC/mayhem/models/ggml-vocab-qwen2.gguf"
gen_model_header model_header_command_r   "$SRC/mayhem/models/ggml-vocab-command-r.gguf"
gen_model_header model_header_aquila      "$SRC/mayhem/models/ggml-vocab-aquila.gguf"
gen_model_header model_header_gpt_2       "$SRC/mayhem/models/ggml-vocab-gpt-2.gguf"
gen_model_header model_header_baichuan    "$SRC/mayhem/models/ggml-vocab-baichuan.gguf"
gen_model_header model_header_deepseek_coder "$SRC/mayhem/models/ggml-vocab-deepseek-coder.gguf"
gen_model_header model_header_falcon      "$SRC/mayhem/models/ggml-vocab-falcon.gguf"

# Harness builds are heavy (~100 MB sanitized binaries): cap concurrent links.
LINK_DEPTH=$(( MAYHEM_JOBS < 8 ? MAYHEM_JOBS : 8 ))

cat > "$HNINJA" <<NINJA
ninja_required_version = 1.7
builddir = $BUILD/harness-log
pool link_pool
  depth = $LINK_DEPTH

rule cc
  command = $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $FLAGS \$cflags -MD -MF \$out.d -c \$in -o \$out
  depfile = \$out.d
  deps = gcc
  description = CXX \$out

rule cc_c
  command = $CC $SANITIZER_FLAGS $DEBUG_FLAGS -c \$in -o \$out
  description = CC \$out

rule ld
  pool = link_pool
  command = $CXX $LDFLAGS_FAST \$ldflags $SANITIZER_FLAGS $DEBUG_FLAGS \$in -o \$out $LIBS
  description = LINK \$out

rule ar
  command = rm -f \$out && ar rcs \$out \$in
  description = AR \$out

build $BUILD/common/libllama-common.a: ar $(for o in $COMMON_OBJS; do printf '%s ' "$BUILD/$o"; done)
build $HOBJ/standalone_main.o: cc_c $STANDALONE_FUZZ_MAIN

NINJA

# harness_targets <name> <source> [<extra compile flags>] [<extra link flags>] [<implicit input>]
harness_targets() {
  local name="$1" src="$2" cflags="${3:-}" ldflags="${4:-}" implicit="${5:-}"
  cat >> "$HNINJA" <<NINJA
build $HOBJ/$name.o: cc $src | $implicit
  cflags = $LIB_FUZZING_ENGINE $cflags
build $OUT/$name: ld $HOBJ/$name.o | $LIBFILES
  ldflags = $LIB_FUZZING_ENGINE $ldflags
build $HOBJ/$name-standalone.o: cc $src | $implicit
  cflags = $cflags
build $OUT/$name-standalone: ld $HOBJ/$name-standalone.o $HOBJ/standalone_main.o | $LIBFILES
  ldflags = $ldflags

NINJA
}

# Grammar + JSON-schema parsers (no --wrap,abort needed; no model required).
harness_targets fuzz_grammar "$HARNESS_DIR/fuzz_grammar.cpp"
harness_targets fuzz_json_to_grammar "$HARNESS_DIR/fuzz_json_to_grammar.cpp"
# GGUF model loader harness — traps abort() via longjmp.
harness_targets fuzz_load_model "$HARNESS_DIR/fuzz_load_model.cpp" "" "-Wl,--wrap,abort"
# Chat template surface — no model load, FuzzedDataProvider only.
harness_targets fuzz_apply_template "$HARNESS_DIR/fuzz_apply_template.cpp"
# Inference harness — writes fuzzed GGUF to /tmp, loads it, runs minimal decode.
harness_targets fuzz_inference "$HARNESS_DIR/fuzz_inference.cpp" "" "-Wl,--wrap,abort"
# Structured kv-override harness — writes fuzzed GGUF to /tmp, loads with kv-overrides.
harness_targets fuzz_structured "$HARNESS_DIR/fuzz_structured.cpp" "" "-Wl,--wrap,abort"
# Structurally-created GGUF harness — constructs a syntactically-valid GGUF, loads it.
harness_targets fuzz_structurally_created "$HARNESS_DIR/fuzz_structurally_created.cpp" "" "-Wl,--wrap,abort"

# Tokenizer harnesses: fuzz_tokenizer.cpp compiled once per vocab type; it uses its own setjmp, but the
# --wrap,abort trap is linked as in the other model harnesses.
tokenizer_target() {
  local variant="$1" define="$2" model="$3"
  harness_targets "fuzz_tokenizer_${variant}" "$HARNESS_DIR/fuzz_tokenizer.cpp" \
      "-D${define} -I$MODEL_HDRS" "-Wl,--wrap,abort" "$MODEL_HDRS/model_header_${variant}.h $SRC/mayhem/models/$model"
}
tokenizer_target aquila         FUZZ_AQUILA         ggml-vocab-aquila.gguf
tokenizer_target baichuan       FUZZ_BAICHUAN       ggml-vocab-baichuan.gguf
tokenizer_target bge            FUZZ_BGE            ggml-vocab-bert-bge.gguf
tokenizer_target bpe            FUZZ_BPE            ggml-vocab-llama-bpe.gguf
tokenizer_target command_r      FUZZ_COMMAND_R      ggml-vocab-command-r.gguf
tokenizer_target deepseek_coder FUZZ_DEEPSEEK_CODER ggml-vocab-deepseek-coder.gguf
tokenizer_target falcon         FUZZ_FALCON         ggml-vocab-falcon.gguf
tokenizer_target gpt_2          FUZZ_GPT_2          ggml-vocab-gpt-2.gguf
tokenizer_target qwen2          FUZZ_QWEN2          ggml-vocab-qwen2.gguf
tokenizer_target spm            FUZZ_SPM            ggml-vocab-llama-spm.gguf

# Seed generator for the GGUF harnesses (a plain executable; no libFuzzer runtime).
cat >> "$HNINJA" <<NINJA
build $HOBJ/gguf_seedgen.o: cc $HARNESS_DIR/gguf_seedgen.cpp
  cflags =
build $BUILD/gguf_seedgen: ld $HOBJ/gguf_seedgen.o | $LIBFILES
  ldflags =
NINJA

ninja -C "$SRC" -f "$HNINJA" -j"$MAYHEM_JOBS" -k1 \
  "$BUILD/gguf_seedgen" \
  "$OUT"/fuzz_grammar{,-standalone} "$OUT"/fuzz_json_to_grammar{,-standalone} \
  "$OUT"/fuzz_load_model{,-standalone} "$OUT"/fuzz_apply_template{,-standalone} \
  "$OUT"/fuzz_inference{,-standalone} "$OUT"/fuzz_structured{,-standalone} \
  "$OUT"/fuzz_structurally_created{,-standalone} \
  "$OUT"/fuzz_tokenizer_{aquila,baichuan,bge,bpe,command_r,deepseek_coder,falcon,gpt_2,qwen2,spm}{,-standalone}

# ── 5) Craft a minimal valid GGUF seed for fuzz_load_model / fuzz_inference / fuzz_structured ──────
for SEEDDIR in \
  "$SRC/mayhem/fuzz_load_model/testsuite" \
  "$SRC/mayhem/fuzz_inference/testsuite" \
  "$SRC/mayhem/fuzz_structured/testsuite" \
  "$SRC/mayhem/fuzz_structurally_created/testsuite"; do
  mkdir -p "$SEEDDIR"
  if [ ! -s "$SEEDDIR/dummy.gguf" ]; then
    ( cd "$BUILD" && ASAN_OPTIONS=detect_leaks=0 ./gguf_seedgen "$SEEDDIR/dummy.gguf" ) || \
      printf 'GGUF\3\0\0\0' > "$SEEDDIR/dummy.gguf"   # fall back to bare magic+version header
  fi
done

echo "build.sh complete:"
ls -la "$OUT"/fuzz_grammar "$OUT"/fuzz_json_to_grammar "$OUT"/fuzz_load_model \
       "$OUT"/fuzz_apply_template "$OUT"/fuzz_inference \
       "$OUT"/fuzz_structured "$OUT"/fuzz_structurally_created \
       "$OUT"/fuzz_tokenizer_aquila "$OUT"/fuzz_tokenizer_baichuan "$OUT"/fuzz_tokenizer_bge \
       "$OUT"/fuzz_tokenizer_bpe "$OUT"/fuzz_tokenizer_command_r "$OUT"/fuzz_tokenizer_deepseek_coder \
       "$OUT"/fuzz_tokenizer_falcon "$OUT"/fuzz_tokenizer_gpt_2 "$OUT"/fuzz_tokenizer_qwen2 \
       "$OUT"/fuzz_tokenizer_spm 2>&1 || true
