-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.ExactJson
import Necoherence.SignatureProfileWire

namespace Necoherence.SignatureJson

/-- Parse the text of a signature entry; the rules are those of `ExactJson.boundedJsonParse`, which the profile entry also uses. -/
def parse (text : String) : Except Necoherence.SignatureWire.WireFailure Lean.Json :=
  (Necoherence.ExactJson.boundedJsonParse text).mapError (Necoherence.SignatureWire.WireFailure.syntax "$")

end Necoherence.SignatureJson
