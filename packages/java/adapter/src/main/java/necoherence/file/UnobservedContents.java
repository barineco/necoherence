// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.file;

import necoherence.core.ResourceId;

/** Rejection payload when a resource has no recorded content digest. */
public record UnobservedContents(ResourceId resource) {
}
