// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.core;

import java.math.BigInteger;

/** Ordered generation identifier for owned state. Its value is an arbitrary-precision Nat. */
public final class Revision implements Comparable<Revision> {
    private final Nat value;

    private Revision(Nat value) { this.value = value; }

    public static Validation<Revision> of(BigInteger value) {
        return switch (Nat.of(value)) {
            case Validation.Valid<Nat> valid -> new Validation.Valid<>(new Revision(valid.value()));
            case Validation.Invalid<Nat> invalid -> new Validation.Invalid<>(invalid.detail());
        };
    }

    public static Revision fromNat(Nat value) { return new Revision(value); }
    public static Revision zero() { return new Revision(Nat.zero()); }
    public Revision successor() { return new Revision(value.plus(Nat.one())); }
    public Nat value() { return value; }
    @Override public int compareTo(Revision other) { return value.compareTo(other.value); }
    @Override public boolean equals(Object other) { return other instanceof Revision revision && value.equals(revision.value); }
    @Override public int hashCode() { return value.hashCode(); }
    @Override public String toString() { return value.toString(); }
}
