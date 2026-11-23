// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.record;

import necoherence.core.Basis;

/** Closed sum representing whether a call record carries a resource basis. */
public sealed interface RecordBasis permits RecordBasis.Situated, RecordBasis.Unsituated {

    record Situated(Basis basis) implements RecordBasis {
    }

    record Unsituated() implements RecordBasis {
    }
}
