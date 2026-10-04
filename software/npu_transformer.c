#include <stdint.h>

#include "model_weights.h"
#include "quantization_config.h"

#define NPU_CONTROL      0x00060000u
#define NPU_STATUS       0x00060004u
#define NPU_WEIGHT_ADDR  0x00060010u
#define NPU_WEIGHT_DATA  0x00060014u
#define NPU_SCALE        0x00060020u
#define NPU_SHIFT_REG    0x00060030u
#define NPU_INPUT_BASE   0x00061000u
#define NPU_OUTPUT_BASE  0x00062000u
#define LED_REG          0x00040000u

#define NPU_START 1u
#define NPU_DONE  2u
#define NPU_GELU  4u

#define MMIO32(address) (*(volatile uint32_t *)(uintptr_t)(address))
#define MMIO8(address)  (*(volatile int8_t *)(uintptr_t)(address))

#define W_EMBED  MODEL_TOKEN_EMBEDDING
#define W_FF1_A  (&MODEL_W_FF1[0])
#define W_FF1_B  (&MODEL_W_FF1[NPU_D_MODEL * NPU_D_MODEL])
#define W_FF2_A  (&MODEL_W_FF2[0])
#define W_FF2_B  (&MODEL_W_FF2[NPU_D_MODEL * NPU_D_MODEL])

void load_weights(const int8_t *weights, uint32_t len)
{
    uint32_t index;

    MMIO32(NPU_WEIGHT_ADDR) = 0;
    for (index = 0; index < len; index += 4) {
        uint32_t packed = (uint8_t)weights[index]
            | ((uint32_t)(uint8_t)weights[index + 1] << 8)
            | ((uint32_t)(uint8_t)weights[index + 2] << 16)
            | ((uint32_t)(uint8_t)weights[index + 3] << 24);
        MMIO32(NPU_WEIGHT_DATA) = packed;
    }
}

static void start_projection(const int8_t *in_vec, int32_t *out_vec,
                             int8_t shift_val, uint32_t control)
{
    uint32_t index;

    for (index = 0; index < NPU_D_MODEL; ++index)
        MMIO8(NPU_INPUT_BASE + index) = in_vec[index];
    MMIO32(NPU_SHIFT_REG) = (uint32_t)(int32_t)shift_val;
    MMIO32(NPU_CONTROL) = control;
    while ((MMIO32(NPU_STATUS) & NPU_DONE) == 0)
        ;
    for (index = 0; index < NPU_D_MODEL; ++index)
        out_vec[index] = MMIO8(NPU_OUTPUT_BASE + index);
}

void run_projection(const int8_t *in_vec, int32_t *out_vec, int8_t shift_val)
{
    start_projection(in_vec, out_vec, shift_val, NPU_START);
}

static void run_gelu_projection(const int8_t *in_vec, int32_t *out_vec,
                                int8_t shift_val)
{
    start_projection(in_vec, out_vec, shift_val, NPU_START | NPU_GELU);
}

static void narrow(const int32_t *source, int8_t *destination)
{
    uint32_t index;

    for (index = 0; index < NPU_D_MODEL; ++index)
        destination[index] = (int8_t)source[index];
}

int main(void)
{
    int8_t act_in[NPU_D_MODEL];
    int8_t ffn_tile[NPU_D_MODEL];
    int32_t act_q[NPU_D_MODEL], act_k[NPU_D_MODEL], act_v[NPU_D_MODEL];
    int32_t act_ff1[NPU_D_FF], act_ff2[NPU_D_MODEL], act_out32[NPU_D_MODEL];
    int32_t logits[NPU_VOCAB_SIZE];
    uint32_t index, tile, token = 0;

    for (index = 0; index < NPU_D_MODEL; ++index)
        act_in[index] = W_EMBED[token * NPU_D_MODEL + index];

    MMIO32(NPU_SCALE) = (uint32_t)NPU_SOFTMAX_INPUT_SHIFT;
    load_weights(MODEL_W_Q, sizeof(MODEL_W_Q));
    run_projection(act_in, act_q, NPU_SHIFT_Q);
    load_weights(MODEL_W_K, sizeof(MODEL_W_K));
    run_projection(act_in, act_k, NPU_SHIFT_K);
    load_weights(MODEL_W_V, sizeof(MODEL_W_V));
    run_projection(act_in, act_v, NPU_SHIFT_V);
    narrow(act_v, act_in);

    load_weights(W_FF1_A, NPU_D_MODEL * NPU_D_MODEL);
    run_gelu_projection(act_in, act_ff1, NPU_SHIFT_FF1);
    load_weights(W_FF1_B, NPU_D_MODEL * NPU_D_MODEL);
    run_gelu_projection(act_in, &act_ff1[NPU_D_MODEL], NPU_SHIFT_FF1);

    narrow(act_ff1, ffn_tile);
    load_weights(W_FF2_A, NPU_D_MODEL * NPU_D_MODEL);
    run_projection(ffn_tile, act_ff2, NPU_SHIFT_FF2);
    narrow(&act_ff1[NPU_D_MODEL], ffn_tile);
    load_weights(W_FF2_B, NPU_D_MODEL * NPU_D_MODEL);
    run_projection(ffn_tile, act_out32, NPU_SHIFT_FF2);
    for (index = 0; index < NPU_D_MODEL; ++index) {
        act_out32[index] += act_ff2[index];
        act_out32[index] += act_in[index];
    }

    narrow(act_out32, act_in);
    for (tile = 0; tile < NPU_VOCAB_SIZE / NPU_D_MODEL; ++tile) {
        load_weights(&MODEL_W_VOCAB[tile * NPU_D_MODEL * NPU_D_MODEL],
                     NPU_D_MODEL * NPU_D_MODEL);
        run_projection(act_in, &logits[tile * NPU_D_MODEL], NPU_SHIFT_VOCAB);
    }

    for (index = 1; index < NPU_VOCAB_SIZE; ++index)
        if (logits[index] > logits[token])
            token = index;
    MMIO32(LED_REG) = token;
    return 0;
}
