// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

//! Provenance of calls as data.
//! An edge exists where a later input carries the basis an earlier product settled.

use crate::core::Basis;

/// One call: which declaration ran, on what input, and what settled.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CallRecord<Input, Product> {
    pub declaration: String,
    pub input: Input,
    pub product: Product,
    pub basis: Option<Basis>,
}

/// Build a [`CallRecord`] without a basis.
pub fn record_of<Input, Product>(
    declaration: impl Into<String>,
    input: Input,
    product: Product,
) -> CallRecord<Input, Product> {
    CallRecord {
        declaration: declaration.into(),
        input,
        product,
        basis: None,
    }
}

/// Build a [`CallRecord`] that carries the basis its command was situated on.
pub fn record_on_basis<Input, Product>(
    declaration: impl Into<String>,
    input: Input,
    product: Product,
    basis: Basis,
) -> CallRecord<Input, Product> {
    CallRecord {
        declaration: declaration.into(),
        input,
        product,
        basis: Some(basis),
    }
}

/// Hold where `later` reads the resource `earlier` settled.
pub fn has_edge<IA, PA, IB, PB>(earlier: &CallRecord<IA, PA>, later: &CallRecord<IB, PB>) -> bool {
    match (&earlier.basis, &later.basis) {
        (Some(settled), Some(read)) => settled.resource == read.resource,
        _ => false,
    }
}
