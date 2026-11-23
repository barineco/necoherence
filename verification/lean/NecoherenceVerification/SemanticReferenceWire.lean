-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: AGPL-3.0-only

import Necoherence.SignatureGeneration

namespace NecoherenceTools.SemanticReferenceWire
open Lean Necoherence Necoherence.SemanticTypes Necoherence.SemanticValidation
open Necoherence.SignatureWire

def typeRefDecode (json : Json) : Except WireFailure TypeRef := do
  keys json ["source", "definition_name", "pointer"]
  pure { source := ← get json "source", definitionName := ← get json "definition_name", pointer := ← get json "pointer" }

def occurrenceRefDecode (json : Json) : Except WireFailure OccurrenceRef := do
  keys json ["source", "pointer"]
  pure { source := ← get json "source", pointer := ← get json "pointer" }

def slotContractDecode (json : Json) : Except WireFailure SlotContract := do
  keys json ["type_ref", "required", "nullable"]
  pure { typeRef := ← getWith typeRefDecode json "type_ref", required := ← get json "required", nullable := ← get json "nullable" }

end NecoherenceTools.SemanticReferenceWire
