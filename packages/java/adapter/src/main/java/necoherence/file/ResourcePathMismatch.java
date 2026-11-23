// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.file;

import necoherence.core.ResourceId;

/** Rejection payload when {@code command.basis.resource} does not name {@code path}. */
public record ResourcePathMismatch(ResourceId resource, NormalizedPath path) {
}
