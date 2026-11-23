// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import necoherence/exact_json as json
import necoherence/semantic_generation_decode as decode
import necoherence/semantic_types as types

pub fn signature_slot_contract_reads_the_type_id_string_test() {
  let assert Ok(types.SlotContract(reference, True, False)) =
    decode.decode_signature_slot_contract(
      json.JsonValueObj([
        #("type_id", json.JsonValueStr("subject")),
        #("required", json.JsonValueBool(True)),
        #("nullable", json.JsonValueBool(False)),
      ]),
    )
  let assert True = reference.definition_name == "subject"
}
