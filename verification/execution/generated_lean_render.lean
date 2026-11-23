-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: AGPL-3.0-only

import NecoherenceGenerator.SignatureGeneration

def main (args : List String) : IO UInt32 := do
  let some exchange := args[0]? | throw (IO.userError "signature exchange path required")
  let .ok input := Necoherence.SignatureGeneration.decodeInput
      (← IO.FS.readFile (System.FilePath.mk exchange)) |
    throw (IO.userError "invalid signature exchange")
  let generated ← match NecoherenceTools.SignatureComposition.generate input (Necoherence.SignatureGeneration.ExpectedBasis.ofInput input) with
    | .ok generated => pure generated
    | .error failure => throw (IO.userError (reprStr failure))
  IO.print generated
  return 0
