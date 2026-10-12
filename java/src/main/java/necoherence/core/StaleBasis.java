// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.core;

/**
 * Conflict payload when the commanded revision differs from owned state.
 *
 * <p>{@code expected} is the revision carried by the command basis.
 * {@code actual} is the revision currently held by the world.
 */
public record StaleBasis(Revision expected, Revision actual) {
}
