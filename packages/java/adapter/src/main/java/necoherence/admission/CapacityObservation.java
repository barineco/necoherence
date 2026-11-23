// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.admission;

import necoherence.core.Nat;
import necoherence.progression.ResourceBudget;

/** An observed resource budget and the instant it was taken at. */
public record CapacityObservation(ResourceBudget observed, Nat observedAt) {}
