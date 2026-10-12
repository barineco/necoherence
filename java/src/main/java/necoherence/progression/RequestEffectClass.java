// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.progression;

/** Effect classification of a footprint. {@code ORDERED_EFFECT} does not grant automatic parallel execution. */
public enum RequestEffectClass {
    PURE,
    ORDERED_EFFECT
}
