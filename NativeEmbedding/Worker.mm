#import <Foundation/Foundation.h>
#include "llama.h"
#include <algorithm>
#include <cmath>
#include <vector>
#include <stdexcept>

// Private JSON files keep transcript text out of arguments and diagnostic logs.
// One bounded batch per process; exiting releases all model/GPU allocations.
using Tokens = std::vector<llama_token>;
using Vector = std::vector<float>;
constexpr int tokenLimit = 512;
constexpr int sequenceLimit = 8;

static Tokens tokenize(const llama_model *model, NSString *text, bool last) {
    const auto *vocab = llama_model_get_vocab(model);
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    int count = -llama_tokenize(vocab, (const char *)data.bytes, (int)data.length, nullptr, 0, true, false);
    if (count <= 0 || count > 65536) throw std::runtime_error("Invalid input size");
    std::vector<llama_token> tokens(count);
    count = llama_tokenize(vocab, (const char *)data.bytes, (int)data.length, tokens.data(), count, true, false);
    if (count < 0) throw std::runtime_error("Tokenization failed");
    tokens.resize(count);
    auto end = last ? llama_vocab_eos(vocab) : llama_vocab_sep(vocab);
    if (end >= 0 && (tokens.empty() || tokens.back() != end)) tokens.push_back(end);
    return tokens;
}

static std::vector<Vector> decode(llama_context *ctx, const llama_model *model, const std::vector<Tokens> &sequences) {
    if (auto memory = llama_get_memory(ctx)) llama_memory_clear(memory, true);
    auto batch = llama_batch_init(tokenLimit, 0, 1);
    for (size_t seq = 0; seq < sequences.size(); ++seq) {
        for (size_t pos = 0; pos < sequences[seq].size(); ++pos) {
            int i = batch.n_tokens++;
            batch.token[i] = sequences[seq][pos];
            batch.pos[i] = (llama_pos)pos;
            batch.n_seq_id[i] = 1;
            batch.seq_id[i][0] = (llama_seq_id)seq;
            batch.logits[i] = true;
        }
    }
    int result = llama_decode(ctx, batch);
    llama_batch_free(batch);
    if (result != 0) throw std::runtime_error("Embedding evaluation failed");
    std::vector<Vector> outputs;
    for (size_t seq = 0; seq < sequences.size(); ++seq) {
        const float *values = llama_get_embeddings_seq(ctx, (llama_seq_id)seq);
        if (!values) throw std::runtime_error("No pooled embedding");
        Vector vector(values, values + llama_model_n_embd(model));
        double norm = 0;
        for (float v : vector) { if (!std::isfinite(v)) throw std::runtime_error("Invalid embedding"); norm += v * v; }
        if (!(norm > 0)) throw std::runtime_error("Empty embedding");
        for (float &v : vector) v /= std::sqrt(norm);
        outputs.push_back(std::move(vector));
    }
    return outputs;
}

static Vector embedSingle(llama_context *ctx, const llama_model *model, NSString *text, bool last, int depth = 0) {
    auto tokens = tokenize(model, text, last);
    // Unusual languages and long words can exceed the estimate used by the
    // chunker. Embed every part, never silently discard the end of a passage.
    if (tokens.size() > tokenLimit) {
        if (depth >= 12 || text.length < 2) throw std::runtime_error("Input cannot be split");
        NSUInteger split = text.length / 2;
        split = [text rangeOfComposedCharacterSequenceAtIndex:split].location;
        if (!split) throw std::runtime_error("Input cannot be split");
        auto a = embedSingle(ctx, model, [text substringToIndex:split], last, depth + 1);
        auto b = embedSingle(ctx, model, [text substringFromIndex:split], last, depth + 1);
        double norm = 0;
        for (size_t i = 0; i < a.size(); ++i) { a[i] = a[i] * split + b[i] * (text.length - split); norm += a[i] * a[i]; }
        if (!(norm > 0)) throw std::runtime_error("Invalid embedding");
        for (float &v : a) v /= std::sqrt(norm);
        return a;
    }
    return decode(ctx, model, {tokens}).front();
}

static void appendVector(NSMutableArray *output, const Vector &values) {
    NSMutableArray *vector = [NSMutableArray arrayWithCapacity:values.size()];
    for (float value : values) [vector addObject:@(value)];
    [output addObject:vector];
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        try {
            if (argc != 5) throw std::runtime_error("Expected model, pooling, input and output paths");
            NSData *input = [NSData dataWithContentsOfFile:@(argv[3])];
            if (!input || input.length > 2 * 1024 * 1024) throw std::runtime_error("Invalid request");
            id texts = [NSJSONSerialization JSONObjectWithData:input options:0 error:nil];
            if (![texts isKindOfClass:NSArray.class] || [texts count] > 32 || ![texts count]) throw std::runtime_error("Invalid batch");
            bool last = std::string(argv[2]) == "last";
            llama_backend_init();
            auto mp = llama_model_default_params(); mp.n_gpu_layers = 99;
            auto *model = llama_model_load_from_file(argv[1], mp);
            if (!model) throw std::runtime_error("Could not load embedding model");
            auto cp = llama_context_default_params();
            cp.n_ctx = tokenLimit; cp.n_batch = tokenLimit; cp.n_ubatch = tokenLimit;
            cp.kv_unified = true;
            cp.n_seq_max = (uint32_t)std::min<NSUInteger>(sequenceLimit, [texts count]);
            cp.n_threads = 4; cp.n_threads_batch = 4; cp.embeddings = true;
            cp.pooling_type = last ? LLAMA_POOLING_TYPE_LAST : LLAMA_POOLING_TYPE_CLS;
            auto *ctx = llama_init_from_model(model, cp);
            if (!ctx) throw std::runtime_error("Could not create embedding context");
            NSMutableArray *output = [NSMutableArray array];
            std::vector<Tokens> pending;
            size_t totalTokens = 0;
            auto flush = [&] {
                if (pending.empty()) return;
                for (const auto &vector : decode(ctx, model, pending)) appendVector(output, vector);
                pending.clear();
                totalTokens = 0;
            };
            for (id text in texts) {
                if (![text isKindOfClass:NSString.class] || [text length] > 32768) throw std::runtime_error("Invalid text");
                auto tokens = tokenize(model, text, last);
                if (pending.size() == sequenceLimit || totalTokens + tokens.size() > tokenLimit) flush();
                if (tokens.size() > tokenLimit) {
                    appendVector(output, embedSingle(ctx, model, text, last));
                } else {
                    totalTokens += tokens.size();
                    pending.push_back(std::move(tokens));
                }
            }
            flush();
            NSData *json = [NSJSONSerialization dataWithJSONObject:output options:0 error:nil];
            if (![json writeToFile:@(argv[4]) options:NSDataWritingAtomic error:nil]) throw std::runtime_error("Could not save embeddings");
            llama_free(ctx); llama_model_free(model); llama_backend_free();
            return 0;
        } catch (const std::exception &error) { fprintf(stderr, "Embedding worker: %s\n", error.what()); return 1; }
    }
}
