// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.progression;

import java.util.List;

/** Request-specific footprint used to decide meaning-level permission. */
public record RequestFootprint(List<String> reads, List<String> writes, RequestEffectClass effectClass) {

    public RequestFootprint {
        reads = List.copyOf(reads);
        writes = List.copyOf(writes);
    }
}
