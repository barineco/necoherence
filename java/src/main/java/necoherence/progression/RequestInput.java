// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.progression;

/** Input surface for submit. It supplies the identity, footprint, demand, and permission together. */
public record RequestInput(
        RequestIdentity identity, RequestFootprint footprint, ResourceDemand demand, MeaningPermission permission) {
}
