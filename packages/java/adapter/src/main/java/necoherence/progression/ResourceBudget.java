// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.progression;

/** Fixed budget that retains a {@link ConfiguredSafetyLimit} for each of the three axes. */
public record ResourceBudget(
        ConfiguredSafetyLimit pendingMaximum,
        ConfiguredSafetyLimit inFlightMaximum,
        ConfiguredSafetyLimit concurrentMaximum) {
}
