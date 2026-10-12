// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.file;

import java.util.List;
import necoherence.core.ResourceId;

/** Immutable map from resource identity to the digest of its last observed contents. */
public record Digests(List<Entry> entries) {

    public Digests {
        entries = List.copyOf(entries);
    }

    public record Entry(ResourceId resource, ContentDigest digest) {
    }
}
