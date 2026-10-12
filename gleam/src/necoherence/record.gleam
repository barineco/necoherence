// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import necoherence/core.{type Basis}

/// One call: which declaration ran, on what input, and what settled. The
/// basis is an immutable value the caller carries; there is no mutable sink
/// or internal counter here.
pub type CallRecord(input, product) {
  CallRecord(
    declaration: String,
    input: input,
    product: product,
    basis: BasisPresence,
  )
}

/// Closed value distinguishing whether a record carries a basis.
pub type BasisPresence {
  NoBasis
  WithBasis(Basis)
}

/// Build a record without a basis.
pub fn record_of(
  declaration: String,
  input: input,
  product: product,
) -> CallRecord(input, product) {
  CallRecord(declaration, input, product, NoBasis)
}

/// Build a record that carries the basis its command was situated on.
pub fn record_on_basis(
  declaration: String,
  input: input,
  product: product,
  basis: Basis,
) -> CallRecord(input, product) {
  CallRecord(declaration, input, product, WithBasis(basis))
}

/// Hold where `later` reads the resource `earlier` settled on.
pub fn has_edge(earlier: CallRecord(a, b), later: CallRecord(c, d)) -> Bool {
  case earlier.basis, later.basis {
    WithBasis(settled), WithBasis(read) -> settled.resource == read.resource
    _, _ -> False
  }
}
