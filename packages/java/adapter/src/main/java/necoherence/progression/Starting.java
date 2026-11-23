// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.progression;

/** Typed token produced after a start command has advanced an entry to preparing. */
public record Starting(RequestIdentity identity, AdapterCommand command) {
}
