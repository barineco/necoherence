// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.core;

/** Closed outcome of public value validation. */
public sealed interface Validation<A> permits Validation.Valid, Validation.Invalid {
    record Valid<A>(A value) implements Validation<A> {}
    record Invalid<A>(String detail) implements Validation<A> {}
}
