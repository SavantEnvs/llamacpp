// gguf_seedgen.cpp — emit a minimal but well-formed GGUF file to seed fuzz_load_model.
//
// llama.cpp's OSS-Fuzz build seeds fuzz_load_model with the output of `llama-gguf <f> w`
// (the examples/gguf/gguf.cpp writer). We don't enable the examples tree, so this tiny
// standalone writer reproduces the same shape using the public ggml/gguf API: the "GGUF"
// magic, a few KV pairs, and a couple of small F32 tensors. That gets the fuzzer past the
// magic/header gate and into the real GGUF metadata + tensor-info parser on the first input.
#include "ggml.h"
#include "gguf.h"

#include <cstdio>
#include <cstdint>
#include <string>
#include <vector>

int main(int argc, char ** argv) {
    const char * out = argc > 1 ? argv[1] : "dummy.gguf";

    struct gguf_context * ctx = gguf_init_empty();

    // A handful of representative metadata keys (architecture + scalars of each type).
    gguf_set_val_str (ctx, "general.architecture", "llama");
    gguf_set_val_str (ctx, "general.name",         "seed");
    gguf_set_val_u32 (ctx, "llama.block_count",    1);
    gguf_set_val_u32 (ctx, "llama.context_length", 16);
    gguf_set_val_f32 (ctx, "llama.rope.freq_base", 10000.0f);
    gguf_set_val_bool(ctx, "general.quantized",    false);

    struct ggml_init_params params = {
        /*.mem_size   =*/ 16ull * 1024ull * 1024ull,
        /*.mem_buffer =*/ NULL,
        /*.no_alloc   =*/ false,
    };
    struct ggml_context * data = ggml_init(params);

    for (int i = 0; i < 2; ++i) {
        const std::string name = "tensor_" + std::to_string(i);
        int64_t ne[1] = { 4 };
        struct ggml_tensor * cur = ggml_new_tensor(data, GGML_TYPE_F32, 1, ne);
        ggml_set_name(cur, name.c_str());
        float * d = (float *) cur->data;
        for (int j = 0; j < 4; ++j) d[j] = (float)(i + j);
        gguf_add_tensor(ctx, cur);
    }

    if (!gguf_write_to_file(ctx, out, /*only_meta=*/false)) {
        fprintf(stderr, "gguf_seedgen: failed to write %s\n", out);
        return 1;
    }

    ggml_free(data);
    gguf_free(ctx);
    fprintf(stderr, "gguf_seedgen: wrote %s\n", out);
    return 0;
}
