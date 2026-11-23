// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import necoherence.composition.SemanticComposition.PreparedCompositionInput;
import necoherence.composition.SemanticExecution.AdmittedComposition;
import necoherence.composition.SignatureCompositionWire;
import necoherence.semantic.SemanticValues.WireValue;

/** Test access to the admission authority of this package. */
public final class AdmissionTestAccess {
    private AdmissionTestAccess() {}

    public static AdmittedComposition admit(WireValue library, WireValue problem,
            PreparedCompositionInput prepared, WireValue derivation) throws WireFailure.WireException {
        return SignatureCompositionWire.admitDerivation(AdmissionAuthority.INSTANCE, library, problem, prepared, derivation);
    }
}
