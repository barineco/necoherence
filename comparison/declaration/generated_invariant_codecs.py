# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from __future__ import annotations

import json
from pathlib import Path
import re

from semantic_invariant_inputs import ROOT


RUST_MAIN = r'''
use std::io::{self, BufRead, Write};
use serde_json::{json, Value};
use necoherence::semantic_validation::ValidationFailure;
use necoherence::semantic_types::{PathStep, ValueCondition};
fn main() -> Result<(), Box<dyn std::error::Error>> {
 let generation = generation_context()?;
 let checked = necoherence::semantic_exchange::verify_generation(&generation)?;
 let context = Context::new(&checked)?;
 let mut output = io::BufWriter::new(io::stdout().lock());
 for line in io::stdin().lock().lines() {
  let case: Value = serde_json::from_str(&line?)?;
  let text = case["value"].to_string();
  let result = match case["type_id"].as_str().ok_or("type id")? {
__DISPATCH__
   _ => return Err("unknown generated type".into()),
  };
  let row = match result {
   Ok(encoded) => json!({"id":case["id"],"status":"Accepted","encoded":serde_json::from_str::<Value>(&encoded)?}),
   Err(RuntimeFailure::Value(ValidationFailure::Rejected(failure))) => {
    let path: Vec<Value> = failure.value_path.iter().map(|step| match step {
     PathStep::Field(name) | PathStep::Variant(name) => json!(name),
     PathStep::Index(index) => json!(index.to_string().parse::<usize>().unwrap()),
    }).collect();
    let condition = match failure.condition {
     ValueCondition::WrongValueKind(name) => format!("WrongValueKind:{name}"),
     ValueCondition::Format(name) => format!("Format:{name}"),
     ValueCondition::InvalidBlob(name) => format!("InvalidBlob:{name}"),
     ValueCondition::UnknownClosedVariant(name) => format!("UnknownClosedVariant:{name}"),
     ValueCondition::InvalidDiscriminator(name) => format!("InvalidDiscriminator:{name}"),
     other => format!("{other:?}"),
    };
    json!({"id":case["id"],"status":"Rejected","path":path,"condition":condition})
   },
   Err(failure) => return Err(failure.into()),
  };
  writeln!(output,"{row}")?;
 }
 Ok(())
}
'''


def rust_codec(rust, case, directory, execute, batch):
    rendered = batch([rust, "render-codec"], [case], directory, "rust-render-codec")[0]
    source = rendered["source"]
    names_text = source.split("pub const TYPE_NAMES:", 1)[1].split("];", 1)[0]
    names = {int(index): name for index, name in re.findall(r'\((\d+), "([A-Za-z0-9_]+)"\)', names_text)}
    dispatch = []
    for definition in case["library"]["definitions"]:
        type_id = definition["shape"]["value"]
        name = names[rendered["indices"][type_id]]
        dispatch.append(f'   {json.dumps(type_id)} => {name}::decode(&context, &text).and_then(|value| value.encode(&context)),')
    crate = directory / "rust-codec"
    (crate / "src").mkdir(parents=True)
    (crate / "src/main.rs").write_text(source + RUST_MAIN.replace("__DISPATCH__", "\n".join(dispatch)))
    manifest = '[package]\nname="ncoh-generated-invariant-codec"\nversion="0.0.0"\nedition="2021"\n[dependencies]\nnecoherence={path=' + json.dumps(str(ROOT / "rust")) + '}\nserde_json={version="1",features=["arbitrary_precision"]}\n'
    (crate / "Cargo.toml").write_text(manifest)
    output = execute(["cargo", "build", "--manifest-path", crate / "Cargo.toml", "--message-format=json"])
    return Path(next(json.loads(line)["executable"] for line in output.splitlines() if json.loads(line).get("executable")))
