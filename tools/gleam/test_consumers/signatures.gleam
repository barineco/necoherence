// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

import generated
import gleam/io
import necoherence/network_host as adapter
import necoherence/network_effect as network
import necoherence/semantic_generation_http as result
import necoherence/semantic_generation_runtime as runtime
import necoherence/semantic_signature_http as http
import necoherence/semantic_signatures as signatures
import necoherence/semantic_types as types

pub fn main() {
  let assert Ok(checked) =
    signatures.admit_generation("__BASIS__", "__EXCHANGE__")
  let assert Ok(context) = generated.initialize(checked)
  let assert Ok(success) = generated.new_successmain(context, 1)
  let assert Ok(failure) = generated.new_failure(context, 0)
  let assert "marker" = generated.wire_symbol
  let assert Ok(message_wire) = generated.encode_wire_message(context, failure)
  let assert Ok(message) = generated.decode_wire_message(context, message_wire)
  let assert True = message == failure
  let assert Error(_) = generated.new_successmain(context, 0)
  let assert Ok(wire) = generated.encode_successmain(context, success)
  let assert Ok(roundtrip) = generated.decode_successmain(context, wire)
  let assert True = roundtrip == success
  let external = generated.WireOperationOutcomeExternal(types.Present(failure))
  let assert Ok(wire) =
    generated.encode_wire_operation_outcome(context, external)
  let assert Ok(roundtrip) =
    generated.decode_wire_operation_outcome(context, wire)
  let assert True = roundtrip == external
  let assert [signatures.Annotation(signatures.Library, "description", _)] =
    generated.annotations(context, signatures.Library)
  let state = network.empty_state()
  let binding =
    http.Binding(
      fn(_) { Ok(http.Completed(external)) },
      fn(_, _, _) { Error(runtime.CallbackFailure("unexpected HTTP response")) },
      adapter.AdapterPorts(fn(_) { panic as "completed preparation issued HTTP" }),
    )
  let assert result.Completed(observed, output) =
    generated.call_wire_operation(
      context,
      generated.WireOperationInput,
      binding,
      state,
    )
  let assert True = output == external && observed == state
  let success_outcome =
    generated.WireOperationOutcomeSuccess(types.Present(success))
  let forbidden =
    http.Binding(
      fn(_) { Ok(http.Completed(success_outcome)) },
      binding.decode,
      binding.ports,
    )
  let assert result.Failed(
    observed,
    result.Callback(runtime.CallbackFailure(
      "prepare completed requires a declared external failure",
    )),
  ) =
    generated.call_wire_operation(
      context,
      generated.WireOperationInput,
      forbidden,
      state,
    )
  let assert True = observed == state
  io.println("signature generated codecs and external completion passed")
}
