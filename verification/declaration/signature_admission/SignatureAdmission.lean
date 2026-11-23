-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: AGPL-3.0-only

import NecoherenceGenerator.SignatureFailureJson

open Lean
open Necoherence Necoherence.SignatureGeneration Necoherence.SignatureWire
open NecoherenceTools.SignatureFailureJson

namespace SignatureAdmission

def resultFailed (failure : AdmissionFailure) : Json :=
  Json.mkObj [("result", Json.str "failed"), ("failure", failureJson failure)]

def acceptedJson (input : Input) : Json :=
  let entrypoints := input.entrypoints.mergeSort (fun a b => a.identity ≤ b.identity)
  let composition := match input.composition with
    | none => Json.null
    | some _ => Json.mkObj [("problem_sha256", encode input.basis.problemSha256)]
  Json.mkObj [("result", Json.str "accepted"),
    ("checked", Json.mkObj [("basis", encode input.basis),
      ("library", Json.mkObj [("identity", Json.str input.signatures.identity),
        ("revision", Json.str input.signatures.revision)]),
      ("entrypoints", Json.arr (entrypoints.map encode).toArray),
      ("composition", composition)])]


def decodeFailureJson (reason : String) : Json :=
  Json.mkObj [("result", Json.str "failed"),
    ("failure", Json.mkObj [("kind", Json.str "decode"), ("reason", Json.str reason)])]

def requestFailureJson (reason : String) : Json :=
  Json.mkObj [("result", Json.str "failed"),
    ("failure", Json.mkObj [("kind", Json.str "request"), ("reason", Json.str reason)])]

def admissionOutputBy (check : Input → ExpectedBasis → Except AdmissionFailure Unit) (exchange : String)
    (expected : ExpectedBasis) : Json :=
  match decodeInput exchange with
  | .error (.json _) => decodeFailureJson "exchange_json"
  | .error (.wire (.unsupportedSchema _ schema)) => resultFailed (.unsupportedSchema schema)
  | .error (.wire failure) => decodeFailureJson ("exchange." ++ wireTagName failure)
  | .ok input =>
    match check input expected with
    | .ok _ => acceptedJson input
    | .error failure => resultFailed failure

def admissionOutput : String → ExpectedBasis → Json :=
  admissionOutputBy fun input expected => (admit input expected).map fun _ => ()

def derivationAdmissionOutput : String → ExpectedBasis → Json :=
  admissionOutputBy fun input expected => (admitWithComposition input expected).map fun _ => ()

def boundaryOf (outcome : Except NecoherenceTools.SignatureGeneration.GenerationFailure String) : Json :=
  match outcome with
  | .ok _ => Json.mkObj [("result", Json.str "accepted")]
  | .error failure =>
    let failureValue := match originalFailureJson? failure with
      | some original => original
      | none => generationFailureJson failure
    Json.mkObj [("result", Json.str "failed"), ("failure", failureValue)]

def propagation (exchange : String) (expected : ExpectedBasis) : Json :=
  let admission := derivationAdmissionOutput exchange expected
  let boundaries := match decodeInput exchange with
    | .ok input =>
      let outcome := NecoherenceTools.SignatureComposition.generate input expected
      Json.mkObj [("generation", boundaryOf outcome), ("generator", boundaryOf outcome)]
    | .error _ => Json.mkObj [("generation", admission), ("generator", admission)]
  Json.mkObj [("admission", admission), ("boundaries", boundaries)]

def requestMode (request : Json) : Except String String :=
  match request.getObjVal? "mode" with
  | .error _ => .ok "admission"
  | .ok (.str "admission") => .ok "admission"
  | .ok (.str "propagation") => .ok "propagation"
  | .ok _ => .error "request_mode"

def run (text : String) : Json :=
  match Json.parse text with
  | .error _ => requestFailureJson "request_json"
  | .ok request =>
    match request.getObjVal? "exchange" >>= Json.getStr? with
    | .error _ => requestFailureJson "request_exchange"
    | .ok exchange =>
      match request.getObjVal? "expected_basis" with
      | .error _ => requestFailureJson "request_expected_basis"
      | .ok expectedJson =>
        match decode (α := Necoherence.SignatureGeneration.ExpectedBasis) expectedJson with
        | .error failure => requestFailureJson ("expected_basis." ++ wireTagName failure)
        | .ok expected =>
          match requestMode request with
          | .error reason => requestFailureJson reason
          | .ok "propagation" => propagation exchange expected
          | .ok _ => admissionOutput exchange expected

def runBatch (stdin : IO.FS.Stream) (stdout : IO.FS.Stream) : IO Unit := do
  let mut line ← stdin.getLine
  while !line.isEmpty do
    let request := if line.back == '\n' then (line.dropEnd 1).toString else line
    stdout.putStrLn (run request).compress
    line ← stdin.getLine

end SignatureAdmission

def main (arguments : List String) : IO UInt32 := do
  let stdin ← IO.getStdin
  if arguments == ["--batch"] then
    SignatureAdmission.runBatch stdin (← IO.getStdout)
  else
    let text ← stdin.readToEnd
    IO.println (SignatureAdmission.run text).compress
  pure 0
