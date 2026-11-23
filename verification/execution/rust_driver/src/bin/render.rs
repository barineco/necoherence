// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use necoherence::semantic_exchange::decode_signature_generation;
use std::io::{self, Read, Write};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut exchange = String::new();
    io::stdin().read_to_string(&mut exchange)?;
    let input = decode_signature_generation(&exchange)?;
    let expected = necoherence::type_signatures::ExpectedSignatureBasis::of_input(&input);
    let source = necoherence_generator::renderer::render_signature_exchange_for(
        &necoherence_generator::renderer::Target::Rust,
        &expected,
        &exchange,
    )?;
    io::stdout().write_all(source.as_bytes())?;
    Ok(())
}
