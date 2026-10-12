// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.core;

/** Rejection payload when the commanded resource is absent. */
public record UnknownResource(ResourceId resource) {
}
