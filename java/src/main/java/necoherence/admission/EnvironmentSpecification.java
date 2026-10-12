// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.admission;

import necoherence.core.Nat;

/** Declares the maximum age a capacity observation stays usable. */
public record EnvironmentSpecification(Nat maxObservationAge) {}
