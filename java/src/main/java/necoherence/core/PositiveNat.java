// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.core;

import java.math.BigInteger;

/** Strictly positive arbitrary-precision natural number with closed validation. */
public final class PositiveNat implements Comparable<PositiveNat> {
    private final Nat value;

    private PositiveNat(Nat value) { this.value = value; }

    public static Validation<PositiveNat> of(BigInteger value) {
        return switch (Nat.of(value)) {
            case Validation.Invalid<Nat> invalid -> new Validation.Invalid<>(invalid.detail());
            case Validation.Valid<Nat> valid -> valid.value().isZero()
                    ? new Validation.Invalid<>("integer must be positive")
                    : new Validation.Valid<>(new PositiveNat(valid.value()));
        };
    }

    public static Validation<PositiveNat> of(Nat value) {
        if (value == null) return new Validation.Invalid<>("integer is required");
        return value.isZero()
                ? new Validation.Invalid<>("integer must be positive")
                : new Validation.Valid<>(new PositiveNat(value));
    }

    public Nat asNat() { return value; }
    @Override public int compareTo(PositiveNat other) { return value.compareTo(other.value); }
    @Override public boolean equals(Object other) { return other instanceof PositiveNat positive && value.equals(positive.value); }
    @Override public int hashCode() { return value.hashCode(); }
    @Override public String toString() { return value.toString(); }
}
