// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use std::sync::Arc;

use necoherence::semantic_types::{
    type_children, ElementContract, ExtraMembers, ProductSpec, SourceRef, TypeRef, TypeShape,
};

#[test]
fn product_extras_value_type_is_a_child_of_the_product() {
    let source = Arc::new(SourceRef {
        repository: "fixture".into(),
        revision: "1".into(),
        path: "children".into(),
        content_digest: "a".repeat(64),
        document_id: "children".into(),
        declared_revision: None,
    });
    let extra_type = TypeRef::new(source, "extra", Vec::<String>::new());
    let shape = TypeShape::Product(ProductSpec {
        fields: vec![],
        extras: ExtraMembers::Allow {
            key_format: None,
            value: ElementContract {
                type_ref: extra_type.clone(),
                nullable: false,
            },
        },
    });
    assert_eq!(type_children(&shape), vec![&extra_type]);
}

#[test]
fn product_without_extras_has_no_extra_child() {
    let shape = TypeShape::Product(ProductSpec {
        fields: vec![],
        extras: ExtraMembers::Reject,
    });
    assert!(type_children(&shape).is_empty());
}
