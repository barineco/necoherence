// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.progression;

import necoherence.core.Nat;

/** Identity that retains the input basis for each request kind. */
public record RequestIdentity(String kind, String provenance, Nat revision) {}
