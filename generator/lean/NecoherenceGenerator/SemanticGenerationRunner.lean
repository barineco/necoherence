-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: AGPL-3.0-only

import NecoherenceGenerator.SignatureFailureJson

def main (args : List String) : IO UInt32 := do
  let some exchange := args[0]? | throw (IO.userError "signature exchange path required")
  let some trusted := args[1]? | throw (IO.userError "trusted basis path required")
  let some destination := args[2]? | throw (IO.userError "Lean output path required")
  let .ok input := Necoherence.SignatureGeneration.decodeInput (← IO.FS.readFile (System.FilePath.mk exchange)) |
    throw (IO.userError "invalid signature exchange")
  let .ok basisJson := Necoherence.SignatureJson.parse (← IO.FS.readFile (System.FilePath.mk trusted)) | throw (IO.userError "invalid trusted basis")
  let .ok expected := Necoherence.SignatureWire.decode (α := Necoherence.SignatureGeneration.ExpectedBasis) basisJson |
    throw (IO.userError "invalid trusted basis shape")
  match NecoherenceTools.SignatureComposition.generate input expected with
  | .error failure =>
    IO.eprintln (NecoherenceTools.SignatureFailureJson.generationFailureJson failure).compress
    pure 1
  | .ok generated =>
    IO.FS.writeFile (System.FilePath.mk destination) generated
    IO.println s!"generated signature nodes={input.signatures.nodes.length}"
    pure 0
