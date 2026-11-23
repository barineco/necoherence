// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.core;

/** Identity and revision that situate an observation or command. */
public record Basis(ResourceId resource, Revision revision) {
}
