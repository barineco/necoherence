// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.core;

/**
 * Identity of an owned resource, determined by the resource's own name.
 *
 * <p>{@code kind} separates one domain of resources from another (files from
 * whatever else comes to be owned), so identically named resources in
 * different domains never compare equal. {@code name} is that domain's own
 * name for the resource. Two calls that name the same resource always build
 * an equal value; nothing here is issued by a counter or looked up in a
 * registry, so independently branched values never collide.
 */
public record ResourceId(String kind, String name) {
}
