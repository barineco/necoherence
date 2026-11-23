-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SemanticInvariantWire

namespace Necoherence.SignatureCompositionStateWire
open Lean Necoherence.SemanticTypes Necoherence.SemanticComposition Necoherence.SignatureWire

instance : Wire AvailableValue where
  encode value := Json.mkObj [("producer", encode value.producer), ("contract", encode value.contract), ("resource", encode value.resource)]
  decode json := do
    keys json ["producer", "contract", "resource"]
    pure { producer := ← get json "producer", contract := ← get json "contract", resource := ← get json "resource" }

instance : Wire BranchFact where
  encode value := Json.mkObj [("guard", encode value.guard), ("inspected", encode value.inspected), ("arm", encode value.arm), ("refinement", encode value.refinement), ("assumptions", encode value.assumptions), ("exact", encode value.exact)]
  decode json := do
    keys json ["guard", "inspected", "arm", "refinement", "assumptions", "exact"]
    pure { guard := ← get json "guard", inspected := ← get json "inspected", arm := ← get json "arm", refinement := ← get json "refinement", assumptions := ← get json "assumptions", exact := ← get json "exact" }

instance : Wire ResourceLotCorrespondence where
  encode value := Json.mkObj [("lot", encode value.lot), ("place", encode value.place), ("producer", encode value.producer), ("token_target", encode value.tokenTarget), ("token_type", encode value.tokenType), ("revision", encode value.revision), ("quantity", encode value.quantity), ("provenance", encode value.provenance)]
  decode json := do
    keys json ["lot", "place", "producer", "token_target", "token_type", "revision", "quantity", "provenance"]
    pure { lot := ← get json "lot", place := ← get json "place", producer := ← get json "producer", tokenTarget := ← get json "token_target", tokenType := ← get json "token_type", revision := ← get json "revision", quantity := ← get json "quantity", provenance := ← get json "provenance" }

instance : Wire NormalizedResourceBinding where
  encode value := Json.mkObj [("transition", encode value.transition), ("lot", encode value.lot), ("read", encode value.read), ("consume", encode value.consume), ("required_revision", encode value.requiredRevision)]
  decode json := do
    keys json ["transition", "lot", "read", "consume", "required_revision"]
    pure { transition := ← get json "transition", lot := ← get json "lot", read := ← get json "read", consume := ← get json "consume", requiredRevision := ← get json "required_revision" }

end Necoherence.SignatureCompositionStateWire
