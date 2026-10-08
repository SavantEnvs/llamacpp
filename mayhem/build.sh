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

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${OUT:=/mayhem}"
: "${MAYHEM_JOBS:=$(nproc)}"
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

cmake --build "$BUILD" -j"$MAYHEM_JOBS" --target llama llama-common

# ── 2) Link flags shared by every harness ──────────────────────────────────────────────────────
# Lib order matters: llama-common (and its build-info base) before llama, llama before ggml.
LIBS="-L$BUILD/common -lllama-common -lllama-common-base \
      -L$BUILD/src -lllama \
      -L$BUILD/ggml/src -lggml -lggml-cpu -lggml-base"
# Include roots: fuzz_grammar pulls private internals (llama-grammar.h); others need gguf.h, common.h.
FLAGS="-std=c++17 -Iggml/include -Iggml/src -Iinclude -Isrc -Icommon -Ivendor -I./ \
       -DNDEBUG -Wno-deprecated-declarations -include cstring -include cstdio"

# Standalone driver object (reads one input file; no libFuzzer runtime). Provided by the base image.
# Compile it as C with $CC so its LLVMFuzzerTestOneInput reference stays unmangled and resolves
# against the harness's extern "C" definition (compiling the .c as C++ would mangle it).
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$BUILD/standalone_main.o"

# ── 3) Build each harness twice: libFuzzer (-> $OUT/<name>) + standalone reproducer (-standalone) ──
# NOTE: leak detection is disabled per-target via the Mayhemfile cmd's `-detect_leaks=0` libFuzzer
# flag. Mayhem alone owns the ASAN/LSan runtime option set, so no compiled-in default-options
# override is linked in here.
build_one() {
  local name="$1" wrap="${2:-}" extra_flags="${3:-}"
  $CXX $LIB_FUZZING_ENGINE $SANITIZER_FLAGS $DEBUG_FLAGS $FLAGS $extra_flags $wrap \
      "$HARNESS_DIR/$name.cpp" -o "$OUT/$name" $LIBS
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $FLAGS $extra_flags $wrap \
      "$HARNESS_DIR/$name.cpp" "$BUILD/standalone_main.o" -o "$OUT/$name-standalone" $LIBS
  echo "built $name (+ standalone)"
}

# Grammar + JSON-schema parsers (no --wrap,abort needed; no model required).
build_one fuzz_grammar
build_one fuzz_json_to_grammar
# GGUF model loader harness — traps abort() via longjmp.
build_one fuzz_load_model "" "-Wl,--wrap,abort"
# Chat template surface — no model load, FuzzedDataProvider only.
build_one fuzz_apply_template
# Inference harness — writes fuzzed GGUF to /tmp, loads it, runs minimal decode.
build_one fuzz_inference "" "-Wl,--wrap,abort"
# Structured kv-override harness — writes fuzzed GGUF to /tmp, loads with kv-overrides.
build_one fuzz_structured "" "-Wl,--wrap,abort"
# Structurally-created GGUF harness — constructs a syntactically-valid GGUF, loads it.
build_one fuzz_structurally_created "" "-Wl,--wrap,abort"

# ── 4) Tokenizer harnesses — require model headers generated from in-repo vocab .gguf files ────────
# The fuzz_tokenizer.cpp harness uses #if FUZZ_BGE / FUZZ_BPE / ... to select which embedded vocab
# model to use; each define is compiled separately to produce one binary per vocab type.
# The model headers are generated with `xxd -i` into a tmp dir and included at compile time.
MODEL_HDRS="$BUILD/model_headers"
mkdir -p "$MODEL_HDRS"

gen_model_header() {
  local name="$1" file="$2"
  # The harness expects variable names like models_ggml_vocab_bert_bge_gguf (what `xxd -i` derives
  # from "models/ggml-vocab-bert-bge.gguf"). The header embeds the file with an assembler .incbin
  # instead of a C array: a ~10 MB model as "0x..," text takes minutes to compile, once per harness.
  local basename var
  basename="$(basename "$file")"
  var="$(printf 'models/%s' "$basename" | sed 's/[^A-Za-z0-9]/_/g')"
  cat > "$MODEL_HDRS/${name}.h" <<HDR
__asm__(".section .rodata\n.balign 16\n.globl ${var}\n${var}:\n.incbin \"${file}\"\n.previous");
extern unsigned char ${var}[];
unsigned int ${var}_len = $(stat -c %s "$file");
HDR
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

# Build tokenizer variant for each vocab type.
# fuzz_tokenizer.cpp uses a shared static init() that loads the embedded model; each define selects
# which model to embed. The harness is compiled without --wrap,abort because it uses its own setjmp.
build_tokenizer() {
  local variant="$1" define="$2"
  local name="fuzz_tokenizer_${variant}"
  $CXX $LIB_FUZZING_ENGINE $SANITIZER_FLAGS $DEBUG_FLAGS $FLAGS \
      -D"${define}" -I"$MODEL_HDRS" -Wl,--wrap,abort \
      "$HARNESS_DIR/fuzz_tokenizer.cpp" -o "$OUT/$name" $LIBS
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $FLAGS \
      -D"${define}" -I"$MODEL_HDRS" -Wl,--wrap,abort \
      "$HARNESS_DIR/fuzz_tokenizer.cpp" "$BUILD/standalone_main.o" -o "$OUT/$name-standalone" $LIBS
  echo "built $name (+ standalone)"
}

build_tokenizer aquila       FUZZ_AQUILA
build_tokenizer baichuan     FUZZ_BAICHUAN
build_tokenizer bge          FUZZ_BGE
build_tokenizer bpe          FUZZ_BPE
build_tokenizer command_r    FUZZ_COMMAND_R
build_tokenizer deepseek_coder FUZZ_DEEPSEEK_CODER
build_tokenizer falcon       FUZZ_FALCON
build_tokenizer gpt_2        FUZZ_GPT_2
build_tokenizer qwen2        FUZZ_QWEN2
build_tokenizer spm          FUZZ_SPM

# ── 5) Craft a minimal valid GGUF seed for fuzz_load_model / fuzz_inference / fuzz_structured ──────
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $FLAGS "$HARNESS_DIR/gguf_seedgen.cpp" -o "$BUILD/gguf_seedgen" $LIBS
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
