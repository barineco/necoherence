// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.core;

import java.math.BigInteger;
import java.util.Objects;

/** Arbitrary-precision Lean {@code Nat}; external construction is a closed validation result. */
public final class Nat implements Comparable<Nat> {
    private final BigInteger value;
    private Nat(BigInteger value) { this.value = value; }
    public static Validation<Nat> of(BigInteger value) {
        if (value == null) return new Validation.Invalid<>("integer is required");
        if (value.signum() < 0) return new Validation.Invalid<>("integer must be non-negative: " + value);
        return new Validation.Valid<>(new Nat(value));
    }
    public static Nat zero() { return new Nat(BigInteger.ZERO); }
    public static Nat one() { return new Nat(BigInteger.ONE); }
    public static Nat fromLong(long value) {
        if (value < 0) throw new AssertionError("trusted Nat count must be nonnegative");
        return new Nat(BigInteger.valueOf(value));
    }
    /** Invariant-only construction; never accepts an external value. */
    public static Nat fromTrusted(BigInteger value) {
        if (value.signum() < 0) throw new AssertionError("Nat arithmetic must remain nonnegative");
        return new Nat(value);
    }
    /** Exact narrowing for adapters that have already proved an in-range external byte. */
    public int intValue() { return value.intValue(); }
    public Nat successor() { return new Nat(value.add(BigInteger.ONE)); }
    public Nat plus(Nat other) { return new Nat(value.add(Objects.requireNonNull(other).value)); }
    public Nat min(Nat other) { return compareTo(other) <= 0 ? this : other; }
    public Nat max(Nat other) { return compareTo(other) >= 0 ? this : other; }
    /** Difference when this is at least other; otherwise zero. */
    public Nat minusWhenOrdered(Nat other) { return compareTo(other) >= 0 ? new Nat(value.subtract(other.value)) : zero(); }
    public boolean isZero() { return value.signum() == 0; }
    @Override public int compareTo(Nat other) { return value.compareTo(other.value); }
    @Override public boolean equals(Object other) { return other instanceof Nat nat && value.equals(nat.value); }
    @Override public int hashCode() { return value.hashCode(); }
    @Override public String toString() { return value.toString(); }
}
