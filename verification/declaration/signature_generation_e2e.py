# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: AGPL-3.0-only

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
GENERATOR = ROOT / "verification/declaration/signature_generator/Cargo.toml"


def generate(command: str) -> str:
    result = subprocess.run(
        ["cargo", "run", "--quiet", "--manifest-path", str(GENERATOR), "--bin", "signatures", "--", command],
        cwd=ROOT, env=os.environ, check=True, capture_output=True, text=True,
    )
    return result.stdout


CONSUMER = r'''
mod declaration { include!("declaration.rs"); }
mod composed { include!("composed.rs"); }
mod synthetic { include!("synthetic.rs"); }
use necoherence::semantic_codegen_runtime as rt;
use necoherence::network_effect as network;
use necoherence::request_progression::{ExecutionHandle, RequestIdentity};
use necoherence::semantic_composition::OutcomeId;
use necoherence::semantic_execution as execution;
use std::sync::{Arc, Mutex};
use std::sync::atomic::{AtomicUsize, Ordering};
use composed::composed as composition;

fn example_binding(mode: u8, encodes: Arc<AtomicUsize>, decodes: Arc<AtomicUsize>) -> execution::NetworkBinding<declaration::ExampleOperationInput, declaration::ExampleOperationResult> {
 execution::NetworkBinding {
  transport: execution::NetworkTransport {
   encode: Arc::new(move |_| { encodes.fetch_add(1, Ordering::SeqCst); panic!("synchronous completion encoded an effect") }),
   decode: Arc::new(move |_| { decodes.fetch_add(1, Ordering::SeqCst); panic!("synchronous completion decoded an effect") }),
  },
  prepare: Arc::new(move |_| {
   let result = if mode == 0 {
    declaration::ExampleOperationResult::Outcome1(declaration::ExampleOperationOutcome1 { reason: Some(rt::JsonValue::Null) })
   } else {
    declaration::ExampleOperationResult::Outcome0(declaration::ExampleOperationOutcome0 { output: Some(rt::JsonValue::Bool(true)) })
   };
   let outcome = if mode == 2 { "refused" } else { result.outcome_id() };
   Ok(execution::BindingPreparedCall::Completed(OutcomeId(outcome.into()), result))
  }),
 }
}

fn refused_binding() -> execution::NetworkBinding<composition::Function0Input, composition::Function0Outcome> {
 execution::NetworkBinding {
  transport: execution::NetworkTransport {
   encode: Arc::new(|attempt| Ok(attempt.clone())),
   decode: Arc::new(|_| unreachable!()),
  },
  prepare: Arc::new(|_| Ok(execution::BindingPreparedCall::Completed(
   OutcomeId("refused".into()),
   composition::Function0Outcome::Outcome1(composition::Function0Outcome1 { reason: composed::unit }),
  ))),
 }
}

struct Recovery { calls: Arc<Mutex<Vec<String>>> }
impl composition::Providers for Recovery {
 fn call_0(&mut self) -> execution::NetworkBinding<composition::Function0Input, composition::Function0Outcome> {
  self.calls.lock().unwrap().push("ExampleOperation".into());
  refused_binding()
 }
 fn call_1(&mut self, input: composition::Function1Input) -> Result<composition::Function1Outcome, execution::ExecutionFailure> {
  self.calls.lock().unwrap().push("handler".into());
  assert!(input.reason == composed::unit);
  Ok(composition::Function1Outcome::Outcome0(composition::Function1Outcome0 { output: composed::truth(false) }))
 }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
 let generation = declaration::initialize()?;
 let expected_graph = necoherence::signature_admission::check_type_signatures(&generation.input().signatures)?;
 assert!(declaration::graph(&generation) == &expected_graph);
 let cx = declaration::Context::new(&generation);
 for value in [false, true] {
  let encoded = declaration::WireValue::write_wire(&declaration::truth(value), &cx)?;
  let reference = &declaration::graph(&generation).nodes.iter().find(|node| node.reference.definition_name.as_ref() == "truth").ok_or("truth reference")?.reference;
  let decoded = declaration::decode::<declaration::truth>(&cx, reference, &rt::encode_json(&encoded)?)?;
  assert!(decoded.0 == value);
 }
 let annotation = declaration::annotations(&generation).first().ok_or("group annotation")?;
 assert!(annotation.value == necoherence::semantic_types::JsonValue::Str("generated group description".into()));
let encodes = Arc::new(AtomicUsize::new(0));
let decodes = Arc::new(AtomicUsize::new(0));
let execution::BindingPreparedCall::Completed(outcome, _) = declaration::exampleoperation_prepare(example_binding(0, encodes.clone(), decodes.clone()), declaration::ExampleOperationInput { input: Some(rt::JsonValue::Bool(true)) }).map_err(|failure| format!("{failure:?}"))? else { return Err("external completion started an effect".into()) };
assert!(outcome.0 == "refused");
let success_rejected = declaration::exampleoperation_prepare(example_binding(1, encodes.clone(), decodes.clone()), declaration::ExampleOperationInput { input: Some(rt::JsonValue::Bool(false)) }).is_err();
assert!(success_rejected);
let mismatch_rejected = declaration::exampleoperation_prepare(example_binding(2, encodes.clone(), decodes.clone()), declaration::ExampleOperationInput { input: Some(rt::JsonValue::Bool(false)) }).is_err();
assert!(mismatch_rejected);
assert!((encodes.load(Ordering::SeqCst), decodes.load(Ordering::SeqCst)) == (0, 0));

 let generation = composed::initialize()?;
 let calls = Arc::new(Mutex::new(Vec::new()));
 let recovery = Recovery { calls: calls.clone() };
 let prepared = composition::prepare(&generation).map_err(|failure| format!("{failure:?}"))?;
 let composition::RunProgress::Completed(composition::Result::Success(output), _) = composition::run(&prepared, recovery, composition::Arguments {}, Default::default()).map_err(|failure| format!("{failure:?}"))? else { return Err("handler did not produce success".into()) };
 assert!(output.result == composed::truth(false));
 assert!(*calls.lock().unwrap() == ["ExampleOperation", "handler"]);

 let generation = synthetic::initialize()?;
 let cx = synthetic::Context::new(&generation);
 let reference = &synthetic::graph(&generation).nodes.iter().find(|node| node.reference.definition_name.as_ref() == "truth").ok_or("truth reference")?.reference;
 for (key, text) in [("kind", "example.test#main"), ("label", "preserved")] {
  let wire = rt::JsonValue::Obj(vec![(key.into(), rt::JsonValue::Str(text.into()))]);
  let value = synthetic::decode::<synthetic::truth>(&cx, reference, &rt::encode_json(&wire)?)?;
  assert!(synthetic::WireValue::write_wire(&value, &cx)? == wire);
 }
 let extra = rt::JsonValue::Obj(vec![("other".into(), rt::JsonValue::Bool(true))]);
 assert!(synthetic::decode::<synthetic::truth>(&cx, reference, &rt::encode_json(&extra)?).is_err());
 Ok(())
}
'''


def run() -> None:
    without_handler = json.loads(generate("no-handler"))
    assert without_handler["status"] in {"Unreachable", "Unknown"}
    # The build guard accepts cargo packages only under the workspace root, so the package is made under ROOT and removed on exit.
    with tempfile.TemporaryDirectory(prefix="ncoh-signature-smoke-", dir=ROOT) as directory:
        path = Path(directory)
        (path / "src").mkdir()
        (path / "Cargo.toml").write_text(
            '[package]\nname="signature_generation_smoke"\nversion="0.1.0"\nedition="2021"\n'
            f'[dependencies]\nnecoherence={{path={json.dumps(str(ROOT / "packages/rust/adapter"))}}}\n', encoding="utf-8",
        )
        (path / "src/declaration.rs").write_text(generate("render"), encoding="utf-8")
        (path / "src/composed.rs").write_text(generate("render-composition"), encoding="utf-8")
        (path / "src/synthetic.rs").write_text(generate("render-synthetic"), encoding="utf-8")
        (path / "src/main.rs").write_text(CONSUMER, encoding="utf-8")
        result = subprocess.run(["cargo", "run", "--quiet", "--manifest-path", str(path / "Cargo.toml")], cwd=ROOT, env=os.environ, capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.stderr)
    print(json.dumps({"rust": "passed", "roundtrip": "identity", "metadata": "preserved", "completed": "external-only", "without_handler": without_handler["status"], "with_handler": "all-results-covered", "synthetic_discriminator": "profile-defined"}, sort_keys=True))


if __name__ == "__main__":
    run()
