// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.file;

/** Closed failure when the external state has declared {@code path}'s write unwritable. */
public record WriteFailure(NormalizedPath path) {
}
