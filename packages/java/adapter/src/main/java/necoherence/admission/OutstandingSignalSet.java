// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.admission;

import java.util.List;

/** Adapter signals still outstanding, read from {@link AdmissionProvenance}. */
public record OutstandingSignalSet(List<AdmissionSignal> signals) {

    public OutstandingSignalSet {
        signals = List.copyOf(signals);
    }
}
