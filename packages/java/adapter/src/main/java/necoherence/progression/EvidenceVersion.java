// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.progression;

/** Versioned evidence identified by a name, digest, and artifact path. */
public record EvidenceVersion(String identifier, String digest, String artifactPath) {
}
