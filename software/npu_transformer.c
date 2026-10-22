#include <stdint.h>

#include "gelu_lut.h"
#include "model_weights.h"
#include "quantization_config.h"

/* Every intermediate activation has scale 2^-4. */
#define ACT_SHIFT (-4)
#define CONTROL      0x00060000u
#define STATUS       0x00060004u
#define WEIGHT_ADDR  0x00060010u
#define WEIGHT_DATA  0x00060014u
#define SCALE        0x00060020u
#define OUTPUT_ADDR  0x00060024u
#define SOFTMAX_DATA 0x0006002cu
#define SHIFT_REG    0x00060030u
#define ACCUM_DATA   0x00060034u
#define INPUT_BASE   0x00061000u
#define LED_REG      0x00040000u
#define MMIO32(a) (*(volatile uint32_t *)(uintptr_t)(a))
#define MMIO8(a)  (*(volatile int8_t *)(uintptr_t)(a))

/* Sixteen characters from the training corpus. */
static const char prompt[17] = "THE SMALL FPGA L";

#ifdef NPU_TRACE
static void trace8(unsigned stage, const int8_t *values, unsigned count)
{
    unsigned i;
    for (i = 0; i < count; ++i)
        MMIO32(LED_REG) = 0x80000000u | (stage << 24) | (i << 16)
            | (uint16_t)(int16_t)values[i];
}
static void trace16(unsigned stage, const uint16_t *values, unsigned count)
{
    unsigned i;
    for (i = 0; i < count; ++i)
        MMIO32(LED_REG) = 0x80000000u | (stage << 24) | (i << 16) | values[i];
}
#else
#define trace8(stage, values, count) ((void)0)
#define trace16(stage, values, count) ((void)0)
#endif

static int8_t clamp8(int32_t x)
{
    if (x > 127) return 127;
    if (x < -128) return -128;
    return (int8_t)x;
}

static int32_t rescale(int32_t x, int shift)
{
    return shift >= 0 ? x * (1 << shift) : x >> -shift;
}

static int8_t activation(int32_t raw, int8_t bias, int b_shift, int w_shift)
{
    int raw_shift = ACT_SHIFT + w_shift;
    int32_t bias_raw = rescale(bias, b_shift - raw_shift);
    return clamp8(rescale(raw + bias_raw, raw_shift - ACT_SHIFT));
}

static void load_weights(const int8_t *w)
{
    unsigned i;
    MMIO32(WEIGHT_ADDR) = 0;
    for (i = 0; i < 256; i += 4)
        MMIO32(WEIGHT_DATA) = (uint8_t)w[i]
            | ((uint32_t)(uint8_t)w[i + 1] << 8)
            | ((uint32_t)(uint8_t)w[i + 2] << 16)
            | ((uint32_t)(uint8_t)w[i + 3] << 24);
}

static void project(const int8_t *input, int32_t *raw, unsigned softmax)
{
    unsigned i;
    for (i = 0; i < 16; ++i) MMIO8(INPUT_BASE + i) = input[i];
    MMIO32(SHIFT_REG) = 0;
    MMIO32(CONTROL) = 1u | softmax;
    while ((MMIO32(STATUS) & 2u) == 0) { }
    for (i = 0; i < 16; ++i) {
        MMIO32(OUTPUT_ADDR) = i;
        raw[i] = (int32_t)MMIO32(ACCUM_DATA);
    }
}

static void dense(const int8_t *input, const int8_t *w, const int8_t *b,
                  int w_shift, int b_shift, int8_t *output)
{
    int32_t raw[16];
    unsigned i;
    load_weights(w);
    project(input, raw, 0);
    for (i = 0; i < 16; ++i)
        output[i] = activation(raw[i], b[i], b_shift, w_shift);
}

static void hidden_at(unsigned position, int8_t *hidden)
{
    unsigned i, token = (unsigned)prompt[position] - 32u;
    for (i = 0; i < 16; ++i) {
        int8_t embedding = MODEL_TOKEN_EMBEDDING[token * 16 + i];
        int8_t position_embedding = MODEL_POSITION_EMBEDDING[position * 16 + i];
        hidden[i] = clamp8(rescale(embedding, NPU_TOKEN_EMBEDDING_SCALE_SHIFT - ACT_SHIFT)
            + rescale(position_embedding, NPU_POSITION_EMBEDDING_SCALE_SHIFT - ACT_SHIFT));
    }
}

static void attention_softmax(const int8_t *scores, uint16_t *probabilities)
{
    int8_t identity[256];
    int32_t raw[16];
    unsigned row, col;
    for (row = 0; row < 16; ++row)
        for (col = 0; col < 16; ++col)
            identity[row * 16 + col] = (row == col) ? 1 : 0;
    load_weights(identity);
    MMIO32(SCALE) = 0; /* Q4.4 scores: LUT index is delta, exp(-delta/16). */
    project(scores, raw, 8u);
    for (row = 0; row < 16; ++row) {
        MMIO32(OUTPUT_ADDR) = row;
        probabilities[row] = (uint16_t)MMIO32(SOFTMAX_DATA);
    }
}

int main(void)
{
    int8_t keys[16][16], values[16][16], query[16];
    int8_t hidden[16], scores[16], context[16], projected[16];
    int8_t ff[32], packed[256], final_hidden[16];
    int32_t raw[16], partial[16], logits[64];
    uint16_t probability[16];
    unsigned pos, col, tile, row, best = 0;

    for (pos = 0; pos < 16; ++pos) {
        hidden_at(pos, hidden);
        dense(hidden, MODEL_W_K, MODEL_B_K, NPU_W_K_SCALE_SHIFT,
              NPU_B_K_SCALE_SHIFT, keys[pos]);
        dense(hidden, MODEL_W_V, MODEL_B_V, NPU_W_V_SCALE_SHIFT,
              NPU_B_V_SCALE_SHIFT, values[pos]);
    }
    hidden_at(15, hidden);
    trace8(1, hidden, 16);
    dense(hidden, MODEL_W_Q, MODEL_B_Q, NPU_W_Q_SCALE_SHIFT,
          NPU_B_Q_SCALE_SHIFT, query);
    trace8(2, query, 16);
    trace8(3, keys[12], 16);
    trace8(4, values[12], 16);

    /* q*k/4 has scale 2^-10; shift six to the Q4.4 softmax input. */
    for (pos = 0; pos < 16; ++pos) {
        int32_t dot = 0;
        for (col = 0; col < 16; ++col)
            dot += (int32_t)query[col] * keys[pos][col];
        scores[pos] = clamp8(dot >> 6);
    }
    trace8(5, scores, 16);
    attention_softmax(scores, probability);
    trace16(6, probability, 16);
    for (col = 0; col < 16; ++col) {
        int32_t sum = 0;
        for (pos = 0; pos < 16; ++pos)
            sum += (int32_t)probability[pos] * values[pos][col];
        context[col] = clamp8(sum >> 16);
    }
    trace8(7, context, 16);

    dense(context, MODEL_W_O, MODEL_B_O, NPU_W_O_SCALE_SHIFT,
          NPU_B_O_SCALE_SHIFT, projected);
    trace8(8, projected, 16);
    for (col = 0; col < 16; ++col)
        hidden[col] = clamp8((int32_t)hidden[col] + projected[col]);
    trace8(9, hidden, 16);

    for (tile = 0; tile < 2; ++tile)
        dense(hidden, MODEL_W_FF1 + tile * 256, MODEL_B_FF1 + tile * 16,
              NPU_W_FF1_SCALE_SHIFT, NPU_B_FF1_SCALE_SHIFT, ff + tile * 16);
    trace8(10, ff, 32);
    for (col = 0; col < 32; ++col)
        ff[col] = MODEL_GELU_LUT[(uint8_t)ff[col]];
    trace8(11, ff, 32);

    /* FF2 is row-major [16][32]; repack each 16-column half. */
    for (tile = 0; tile < 2; ++tile) {
        for (row = 0; row < 16; ++row)
            for (col = 0; col < 16; ++col)
                packed[row * 16 + col] = MODEL_W_FF2[row * 32 + tile * 16 + col];
        load_weights(packed);
        project(ff + tile * 16, raw, 0);
        for (row = 0; row < 16; ++row) {
            if (tile == 0) partial[row] = raw[row];
            else partial[row] += raw[row];
        }
    }
    for (row = 0; row < 16; ++row)
        final_hidden[row] = clamp8((int32_t)hidden[row] + activation(
            partial[row], MODEL_B_FF2[row], NPU_B_FF2_SCALE_SHIFT,
            NPU_W_FF2_SCALE_SHIFT));
    trace8(12, final_hidden, 16);

    for (tile = 0; tile < 4; ++tile) {
        load_weights(MODEL_W_VOCAB + tile * 256);
        project(final_hidden, raw, 0);
        for (row = 0; row < 16; ++row) {
            int32_t bias_raw = rescale(MODEL_B_VOCAB[tile * 16 + row],
                NPU_B_VOCAB_SCALE_SHIFT - ACT_SHIFT - NPU_W_VOCAB_SCALE_SHIFT);
            logits[tile * 16 + row] = raw[row] + bias_raw;
        }
    }
    for (row = 1; row < 64; ++row)
        if (logits[row] > logits[best]) best = row;
    MMIO32(LED_REG) = best;
    return 0;
}
