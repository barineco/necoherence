// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.progression;

import necoherence.core.Nat;

/** Fixed limit declared by the configuration. */
public record ConfiguredSafetyLimit(String resource, Nat maximum) {}
