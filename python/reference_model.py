"""Bit-exact model of rtl/mac_array_4x4.sv."""

from __future__ import annotations

import numpy as np


def _as_int8_array(values: np.ndarray | list[int], shape: tuple[int, ...]) -> np.ndarray:
    array = np.asarray(values, dtype=np.int8)
    if array.shape != shape:
        raise ValueError(f"expected shape {shape}, got {array.shape}")
    return array


def _wrap_int32(value: int) -> np.int32:
    value &= 0xFFFF_FFFF
    if value >= 0x8000_0000:
        value -= 0x1_0000_0000
    return np.int32(value)


def mac_array_4x4(
    activations: np.ndarray | list[int],
    weights: np.ndarray | list[list[int]],
    accumulators: np.ndarray | list[int] | None = None,
    enable: bool = True,
) -> np.ndarray:
    """Run one clock edge of the 4x4 signed INT8 MAC array.

    The result is signed INT32 and wraps exactly like the RTL register update.
    When ``enable`` is false, the input accumulator state is returned unchanged.
    """

    activation_vector = _as_int8_array(activations, (4,))
    weight_matrix = _as_int8_array(weights, (4, 4))
    accumulator_vector = (
        np.zeros(4, dtype=np.int32)
        if accumulators is None
        else np.asarray(accumulators, dtype=np.int32).copy()
    )
    if accumulator_vector.shape != (4,):
        raise ValueError(f"expected accumulator shape (4,), got {accumulator_vector.shape}")
    if not enable:
        return accumulator_vector

    result = np.empty(4, dtype=np.int32)
    for row in range(4):
        dot_product = sum(
            int(weight_matrix[row, column]) * int(activation_vector[column])
            for column in range(4)
        )
        result[row] = _wrap_int32(int(accumulator_vector[row]) + dot_product)
    return result


if __name__ == "__main__":
    activation = [1, -2, 3, -4]
    weight = [
        [1, 2, 3, 4],
        [-1, 0, -3, 2],
        [127, -128, 1, -1],
        [8, -6, 5, -5],
    ]
    print(mac_array_4x4(activation, weight).tolist())
