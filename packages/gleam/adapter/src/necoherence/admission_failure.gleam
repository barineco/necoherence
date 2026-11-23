// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import neco_quotient_certificate/failure.{type Mismatch}

pub type AdmissionFailure(
  library_failure,
  wire_failure,
  composition_input_failure,
  composition_failure,
  generation_failure,
) {
  UnsupportedSchema(schema: String)
  EntrypointsEmpty
  EntrypointIdentityEmpty
  EntrypointDuplicate(identity: String)
  EntrypointUnresolved(identity: String, definition: String)
  Library(failure: library_failure)
  Certificate(mismatch: Mismatch(String))
  Wire(failure: wire_failure)
  CompositionInput(failure: composition_input_failure)
  Composition(failure: composition_failure)
  Generation(failure: generation_failure)
}
