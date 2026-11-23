// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.admission;

import necoherence.progression.ExecutionHandle;
import necoherence.progression.RequestIdentity;

/** One adapter signal not yet folded into a terminal entry's own record. */
public record AdmissionSignal(RequestIdentity identity, ExecutionHandle handle, SignalKind kind) {
}
