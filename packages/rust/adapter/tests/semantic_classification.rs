// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use necoherence::semantic_types::*;

#[test]
fn dispositions_classify_like_the_lean_definition() {
    use ReasonDisposition::{Failed, Residual, Stopped};
    assert_eq!(classify_dispositions(&[]), Failed);
    assert_eq!(classify_dispositions(&[Residual]), Residual);
    assert_eq!(classify_dispositions(&[Residual, Stopped]), Stopped);
    assert_eq!(classify_dispositions(&[Stopped, Failed]), Failed);
    assert_eq!(classify_dispositions(&[Residual, Failed, Stopped]), Failed);
}
