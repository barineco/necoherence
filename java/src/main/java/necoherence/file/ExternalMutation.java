// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.file;

/**
 * Conflict payload when a file's digest no longer matches what was observed. {@code expected} is the
 * digest recorded at the last observation, {@code actual} is the digest {@code replace} finds at the
 * path when it is applied.
 */
public record ExternalMutation(ContentDigest expected, ContentDigest actual) {
}
