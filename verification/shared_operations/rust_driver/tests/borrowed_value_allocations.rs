// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

#[path = "../../../../packages/rust/adapter/tests/semantic_value_samples.rs"]
mod semantic_value_samples;

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::{Cell, RefCell};

use necoherence::exact_json::JsonValue;
use necoherence::exact_json_view::JsonValueView;
use necoherence::semantic_types::*;
use necoherence::semantic_validation::FormatWorkspace;
use necoherence::semantic_validation::PreparedValidator;
use necoherence::semantic_validation::*;
use necoherence::signature_admission::check_type_signatures;
use necoherence::signature_admission::*;
use necoherence::type_signatures::*;
use num_bigint::{BigInt, BigUint};

fn required_slot(reference: &TypeRef) -> SlotContract {
    SlotContract {
        type_ref: reference.clone(),
        required: true,
        nullable: false,
    }
}

fn borrowed_slot_view(value: SlotValue<&JsonValue>) -> SlotValue<JsonValueView<'_>> {
    match value {
        SlotValue::Absent => SlotValue::Absent,
        SlotValue::Null => SlotValue::Null,
        SlotValue::Present(value) => SlotValue::Present(JsonValueView::from_json(value)),
    }
}

fn decide_present<'a>(
    graph: &'a SemanticGraph,
    slot: &'a SlotContract,
    value: &'a JsonValue,
) -> BorrowedValueDecision<'a, 'a> {
    PreparedValidator::new(graph, FormatWorkspace::empty())
        .decide_view_slot(slot, SlotValue::Present(JsonValueView::from_json(value)))
}

fn decide_present_view<'a>(
    graph: &'a SemanticGraph,
    slot: &'a SlotContract,
    value: JsonValueView<'a>,
) -> BorrowedValueDecision<'a, 'a> {
    PreparedValidator::new(graph, FormatWorkspace::empty())
        .decide_view_slot(slot, SlotValue::Present(value))
}

fn decide_slot_value<'a>(
    graph: &'a SemanticGraph,
    slot: &'a SlotContract,
    value: SlotValue<&'a JsonValue>,
) -> BorrowedValueDecision<'a, 'a> {
    PreparedValidator::new(graph, FormatWorkspace::empty())
        .decide_view_slot(slot, borrowed_slot_view(value))
}
use semantic_value_samples::{format_cases, v2a_library, v2a_reference};

thread_local! {
    static COUNTING: Cell<bool> = const { Cell::new(false) };
    static ALLOCATIONS: Cell<usize> = const { Cell::new(0) };
    static SITES: RefCell<Vec<String>> = const { RefCell::new(Vec::new()) };
}

struct ProbeAllocator;

fn note_allocation() {
    if !COUNTING
        .try_with(|counting| counting.get())
        .unwrap_or(false)
    {
        return;
    }
    let _ = COUNTING.try_with(|counting| counting.set(false));
    let _ = ALLOCATIONS.try_with(|count| count.set(count.get() + 1));
    let trace = std::backtrace::Backtrace::force_capture().to_string();
    let site = first_necoherence_frame(&trace);
    let _ = SITES.try_with(|sites| sites.borrow_mut().push(site));
    let _ = COUNTING.try_with(|counting| counting.set(true));
}

fn first_necoherence_frame(trace: &str) -> String {
    let mut lines = trace.lines();
    while let Some(line) = lines.next() {
        let Some((_, symbol)) = line.split_once(": ") else {
            continue;
        };
        let symbol = symbol.trim();
        if !symbol.starts_with("necoherence::") {
            continue;
        }
        let location = lines
            .next()
            .map(|next| next.trim().trim_start_matches("at ").to_string())
            .unwrap_or_default();
        return format!("{symbol} @ {location}");
    }
    let top: Vec<&str> = trace
        .lines()
        .filter(|line| line.contains(": "))
        .filter(|line| {
            !line.contains("backtrace")
                && !line.contains("note_allocation")
                && !line.contains("__rust_")
                && !line.contains("GlobalAlloc")
        })
        .take(4)
        .collect();
    format!("outside necoherence: {}", top.join(" | "))
}

unsafe impl GlobalAlloc for ProbeAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        note_allocation();
        unsafe { System.alloc(layout) }
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        unsafe { System.dealloc(ptr, layout) }
    }
    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        note_allocation();
        unsafe { System.alloc_zeroed(layout) }
    }
    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        note_allocation();
        unsafe { System.realloc(ptr, layout, new_size) }
    }
}

#[global_allocator]
static GLOBAL: ProbeAllocator = ProbeAllocator;

fn counted<T>(window: impl FnOnce() -> T) -> (T, usize) {
    ALLOCATIONS.with(|count| count.set(0));
    SITES.with(|sites| sites.borrow_mut().clear());
    COUNTING.with(|counting| counting.set(true));
    let result = window();
    COUNTING.with(|counting| counting.set(false));
    let count = ALLOCATIONS.with(|count| count.get());
    for site in SITES.with(|sites| std::mem::take(&mut *sites.borrow_mut())) {
        println!("allocation site: {site}");
    }
    (result, count)
}

fn expect_rejected(decision: BorrowedValueDecision<'_, '_>, expected: ValueCondition) {
    let BorrowedValueDecision::Rejected(recipe) = decision else {
        panic!("expected a rejected decision")
    };
    let ValueDecision::Rejected(failure) = recipe.materialize() else {
        panic!("expected an owned rejection")
    };
    assert_eq!(failure.condition, expected);
}

fn expect_accepted(decision: BorrowedValueDecision<'_, '_>) {
    assert!(matches!(decision, BorrowedValueDecision::Accepted));
}

fn assert_positive_control() {
    let (boxed, count) = counted(|| std::hint::black_box(Box::new(7u64)));
    assert!(count >= 1, "allocation control was not observed");
    assert_eq!(*boxed, 7);
}

#[test]
fn borrowed_paths_keep_their_conditions_through_free_api() {
    assert_positive_control();
    let graph = check_type_signatures(&v2a_library()).unwrap();
    let plain = v2a_reference(&graph, "plain");
    let konst = v2a_reference(&graph, "konst");
    let flag = v2a_reference(&graph, "flag");
    let sealed = v2a_reference(&graph, "sealed");
    let wrapped = v2a_reference(&graph, "wrapped");
    let bytes = v2a_reference(&graph, "bytes");

    let text = JsonValue::Str("abc".into());
    let mismatch = JsonValue::Str("x".into());
    let boolean_expected = JsonValue::Str("x".into());
    let duplicate = JsonValue::Obj(vec![
        ("kind".into(), JsonValue::Str("sealed".into())),
        ("name".into(), JsonValue::Str("a".into())),
        ("name".into(), JsonValue::Str("b".into())),
    ]);
    let wrapper_valid = JsonValue::Obj(vec![("$value".into(), JsonValue::Str("abc".into()))]);
    let wrapper_invalid = JsonValue::Obj(vec![("$value".into(), JsonValue::Num(5.into()))]);
    let bytes_valid = JsonValue::Obj(vec![("$bytes".into(), JsonValue::Str("YWJj".into()))]);
    let bytes_invalid = JsonValue::Obj(vec![("$bytes".into(), JsonValue::Str("YWJjZ".into()))]);
    let slot = SlotContract {
        type_ref: flag.clone(),
        required: true,
        nullable: false,
    };

    let slot_c31 = required_slot(&plain);
    let (plain_decision, _) = counted(|| decide_present(&graph, &slot_c31, &text));
    let slot_c30 = required_slot(&konst);
    let (konst_decision, _) = counted(|| decide_present(&graph, &slot_c30, &mismatch));
    let slot_c29 = required_slot(&flag);
    let (kind_decision, _) = counted(|| decide_present(&graph, &slot_c29, &boolean_expected));
    let slot_c28 = required_slot(&sealed);
    let (dup_decision, _) = counted(|| decide_present(&graph, &slot_c28, &duplicate));
    let slot_c27 = required_slot(&wrapped);
    let (wrap_ok, _) = counted(|| decide_present(&graph, &slot_c27, &wrapper_valid));
    let slot_c26 = required_slot(&wrapped);
    let (wrap_bad, _) = counted(|| decide_present(&graph, &slot_c26, &wrapper_invalid));
    let slot_c25 = required_slot(&bytes);
    let (bytes_ok, _) = counted(|| decide_present(&graph, &slot_c25, &bytes_valid));
    let slot_c24 = required_slot(&bytes);
    let (bytes_bad, _) = counted(|| decide_present(&graph, &slot_c24, &bytes_invalid));
    let (slot_decision, _) = counted(|| decide_slot_value(&graph, &slot, SlotValue::Absent));

    expect_accepted(plain_decision);
    expect_rejected(konst_decision, ValueCondition::ConstMismatch);
    expect_rejected(
        kind_decision,
        ValueCondition::WrongValueKind("boolean".into()),
    );
    expect_rejected(dup_decision, ValueCondition::DuplicateField("name".into()));
    expect_accepted(wrap_ok);
    expect_rejected(
        wrap_bad,
        ValueCondition::WrongValueKind("wrapper text".into()),
    );
    expect_accepted(bytes_ok);
    expect_rejected(bytes_bad, ValueCondition::InvalidBytes);
    expect_rejected(slot_decision, ValueCondition::MissingRequired);
}

#[test]
fn prepared_format_cases_do_not_allocate() {
    assert_positive_control();
    let cases = format_cases();
    let prepared: Vec<_> = cases
        .iter()
        .map(|(_, rule, _, _)| prepare_format(rule, None))
        .collect();
    let mut workspace = FormatWorkspace::try_new(4096).expect("reservation");
    let mut observed = Vec::with_capacity(cases.len());
    let mut counts = Vec::with_capacity(cases.len());
    for ((_, _, text, _), prepared) in cases.iter().zip(prepared.iter()) {
        let (decision, count) = counted(|| {
            recognize_prepared_format(
                std::hint::black_box(prepared),
                std::hint::black_box(text.as_str()),
                &mut workspace,
            )
        });
        observed.push(decision);
        counts.push(count);
    }
    for (((label, _, _, expected), decision), count) in
        cases.iter().zip(observed.iter()).zip(counts.iter())
    {
        assert_eq!(decision, expected, "{label}");
        assert_eq!(*count, 0, "{label} allocated");
    }
}

#[test]
fn virtual_product_view_keeps_conditions_through_free_api() {
    assert_positive_control();
    let graph = check_type_signatures(&semantic_value_samples::v3_product_library()).unwrap();
    let product = v2a_reference(&graph, "product");
    let payload = JsonValue::Str("dyn".into());
    let other = JsonValue::Str("a".into());
    let null = JsonValue::Null;
    let accepted_fields = [
        (
            "payload",
            SlotValue::Present(JsonValueView::from_json(&payload)),
        ),
        ("omitted", SlotValue::Absent),
        (
            "nullable",
            SlotValue::Present(JsonValueView::from_json(&null)),
        ),
    ];
    let duplicate_fields = [
        (
            "payload",
            SlotValue::Present(JsonValueView::from_json(&other)),
        ),
        (
            "payload",
            SlotValue::Present(JsonValueView::from_json(&payload)),
        ),
    ];
    let missing_fields = [
        ("payload", SlotValue::Absent),
        ("omitted", SlotValue::Absent),
        (
            "nullable",
            SlotValue::Present(JsonValueView::from_json(&null)),
        ),
    ];
    let slot_c22 = required_slot(&product);
    let (accepted, _) = counted(|| {
        decide_present_view(
            &graph,
            &slot_c22,
            JsonValueView::object(std::hint::black_box(&accepted_fields)),
        )
    });
    let slot_c21 = required_slot(&product);
    let (duplicate, _) = counted(|| {
        decide_present_view(
            &graph,
            &slot_c21,
            JsonValueView::object(std::hint::black_box(&duplicate_fields)),
        )
    });
    let slot_c20 = required_slot(&product);
    let (missing, _) = counted(|| {
        decide_present_view(
            &graph,
            &slot_c20,
            JsonValueView::object(std::hint::black_box(&missing_fields)),
        )
    });
    assert!(matches!(accepted, BorrowedValueDecision::Accepted));
    assert!(matches!(duplicate, BorrowedValueDecision::Rejected(_)));
    assert!(matches!(missing, BorrowedValueDecision::Rejected(_)));
}

fn prepared_check(
    validator: &mut PreparedValidator<'_>,
    graph: &SemanticGraph,
    reference: &TypeRef,
    value: &JsonValue,
) -> usize {
    let owned =
        PreparedValidator::new(graph, FormatWorkspace::empty()).accepts_value(reference, value);
    let slot_c19 = required_slot(reference);
    let (decision, count) = counted(|| {
        validator.decide_view_slot(
            &slot_c19,
            SlotValue::Present(JsonValueView::from_json(value)),
        )
    });
    match decision {
        BorrowedValueDecision::Accepted => assert!(matches!(owned, ValueDecision::Accepted)),
        BorrowedValueDecision::Rejected(recipe) => {
            assert!(matches!(owned, ValueDecision::Rejected(_)));
            assert_eq!(recipe.materialize(), owned);
        }
        BorrowedValueDecision::Unresolved(recipe) => {
            assert!(matches!(owned, ValueDecision::Unresolved(_)));
            assert_eq!(recipe.materialize(), owned);
        }
    }
    count
}

#[test]
fn prepared_validator_v2a_and_v3_paths_match_owned_without_allocation() {
    assert_positive_control();
    let graph = check_type_signatures(&v2a_library()).unwrap();
    let mut validator = PreparedValidator::new(&graph, FormatWorkspace::empty());
    let cases: Vec<(TypeRef, JsonValue)> = vec![
        (v2a_reference(&graph, "plain"), JsonValue::Str("abc".into())),
        (v2a_reference(&graph, "konst"), JsonValue::Str("x".into())),
        (v2a_reference(&graph, "flag"), JsonValue::Str("x".into())),
        (
            v2a_reference(&graph, "sealed"),
            JsonValue::Obj(vec![
                ("kind".into(), JsonValue::Str("sealed".into())),
                ("name".into(), JsonValue::Str("a".into())),
                ("name".into(), JsonValue::Str("b".into())),
            ]),
        ),
        (
            v2a_reference(&graph, "wrapped"),
            JsonValue::Obj(vec![("$value".into(), JsonValue::Str("abc".into()))]),
        ),
        (
            v2a_reference(&graph, "wrapped"),
            JsonValue::Obj(vec![("$value".into(), JsonValue::Num(5.into()))]),
        ),
        (
            v2a_reference(&graph, "bytes"),
            JsonValue::Obj(vec![("$bytes".into(), JsonValue::Str("YWJj".into()))]),
        ),
        (
            v2a_reference(&graph, "bytes"),
            JsonValue::Obj(vec![("$bytes".into(), JsonValue::Str("YWJjZ".into()))]),
        ),
    ];
    for (reference, value) in &cases {
        assert_eq!(prepared_check(&mut validator, &graph, reference, value), 0);
    }

    let product_graph =
        check_type_signatures(&semantic_value_samples::v3_product_library()).unwrap();
    let product = v2a_reference(&product_graph, "product");
    let mut product_validator = PreparedValidator::new(&product_graph, FormatWorkspace::empty());
    let payload = JsonValue::Str("dyn".into());
    let other = JsonValue::Str("a".into());
    let null = JsonValue::Null;
    let accepted_fields = [
        (
            "payload",
            SlotValue::Present(JsonValueView::from_json(&payload)),
        ),
        ("omitted", SlotValue::Absent),
        (
            "nullable",
            SlotValue::Present(JsonValueView::from_json(&null)),
        ),
    ];
    let duplicate_fields = [
        (
            "payload",
            SlotValue::Present(JsonValueView::from_json(&other)),
        ),
        (
            "payload",
            SlotValue::Present(JsonValueView::from_json(&payload)),
        ),
    ];
    let slot_c18 = required_slot(&product);
    let (accepted, a) = counted(|| {
        product_validator.decide_view_slot(
            &slot_c18,
            SlotValue::Present(JsonValueView::object(&accepted_fields)),
        )
    });
    let slot_c17 = required_slot(&product);
    let (duplicate, d) = counted(|| {
        product_validator.decide_view_slot(
            &slot_c17,
            SlotValue::Present(JsonValueView::object(&duplicate_fields)),
        )
    });
    let accepted_owned_input = JsonValue::Obj(vec![
        ("payload".into(), payload.clone()),
        ("nullable".into(), JsonValue::Null),
    ]);
    let accepted_owned = PreparedValidator::new(&product_graph, FormatWorkspace::empty())
        .accepts_value(&product, &accepted_owned_input);
    assert!(matches!(accepted, BorrowedValueDecision::Accepted));
    assert!(matches!(accepted_owned, ValueDecision::Accepted));
    let duplicate_owned_input = JsonValue::Obj(vec![
        ("payload".into(), other.clone()),
        ("payload".into(), payload.clone()),
    ]);
    let duplicate_owned = PreparedValidator::new(&product_graph, FormatWorkspace::empty())
        .accepts_value(&product, &duplicate_owned_input);
    assert!(matches!(
        &duplicate_owned,
        ValueDecision::Rejected(ValueFailure { condition: ValueCondition::DuplicateField(key), .. })
            if key == "payload"
    ));
    let BorrowedValueDecision::Rejected(recipe) = duplicate else {
        panic!("duplicate view is not rejected");
    };
    assert_eq!(recipe.materialize(), duplicate_owned);
    assert_eq!([a, d], [0, 0]);
}

#[test]
fn prepared_validator_format_cases_match_expectations_for_each_budget() {
    assert_positive_control();
    for (label, rule, text, expected) in format_cases() {
        for budget in [0usize, 4096] {
            let mut graph = check_type_signatures(&v2a_library()).unwrap();
            let node = graph
                .nodes
                .iter_mut()
                .find(|node| &*node.reference.definition_name == "plain")
                .expect("plain node");
            if let TypeShape::String(spec) = &mut node.shape {
                spec.format = Some(FormatUse::Inline(rule.clone()));
            }
            let plain = v2a_reference(&graph, "plain");
            let value = JsonValue::Str(text.clone());
            let workspace = FormatWorkspace::try_new(budget).expect("reservation");
            let mut validator = PreparedValidator::new(&graph, workspace);
            let owned = PreparedValidator::new(&graph, FormatWorkspace::empty())
                .accepts_value(&plain, &value);
            let slot_c16 = required_slot(&plain);
            let (decision, count) = counted(|| {
                validator.decide_view_slot(
                    &slot_c16,
                    SlotValue::Present(JsonValueView::from_json(&value)),
                )
            });
            let accepted = matches!(decision, BorrowedValueDecision::Accepted);
            assert_eq!(accepted, expected, "{label} budget {budget}");
            assert_eq!(
                accepted,
                matches!(owned, ValueDecision::Accepted),
                "{label} owned"
            );
            assert_eq!(count, 0, "{label} budget {budget} allocated");
        }
    }
}

#[test]
fn prepared_validator_memo_repetition_is_independent_of_budget() {
    assert_positive_control();
    let rule = FormatRule::Literal("cd".into());
    let mut graph = check_type_signatures(&v2a_library()).unwrap();
    let node = graph
        .nodes
        .iter_mut()
        .find(|node| &*node.reference.definition_name == "plain")
        .expect("plain node");
    if let TypeShape::String(spec) = &mut node.shape {
        spec.format = Some(FormatUse::Inline(rule));
    }
    let plain = v2a_reference(&graph, "plain");
    let texts = ["cd", "ab", "cd"];
    let expected = [true, false, true];
    for budget in [1usize, 4096] {
        let mut validator = PreparedValidator::new(
            &graph,
            FormatWorkspace::try_new(budget).expect("reservation"),
        );
        for (text, want) in texts.iter().zip(expected) {
            let value = JsonValue::Str((*text).into());
            let slot_c15 = required_slot(&plain);
            let decision = validator.decide_view_slot(
                &slot_c15,
                SlotValue::Present(JsonValueView::from_json(&value)),
            );
            assert_eq!(
                matches!(decision, BorrowedValueDecision::Accepted),
                want,
                "{text} budget {budget}"
            );
        }
    }
    let mut zero = PreparedValidator::new(&graph, FormatWorkspace::empty());
    for (text, want) in texts.iter().zip(expected) {
        let value = JsonValue::Str((*text).into());
        let slot_c14 = required_slot(&plain);
        let decision = zero.decide_view_slot(
            &slot_c14,
            SlotValue::Present(JsonValueView::from_json(&value)),
        );
        assert_eq!(
            matches!(decision, BorrowedValueDecision::Accepted),
            want,
            "{text} budget 0"
        );
    }
}

#[test]
fn prepared_validator_unresolved_virtual_product_keeps_the_obligation() {
    assert_positive_control();
    let graph =
        semantic_value_samples::recursive_graph(vec![semantic_value_samples::recursive_node(
            "P",
            semantic_value_samples::recursive_product(&[("a", "Missing")]),
        )]);
    let product = semantic_value_samples::recursive_ref("P");
    let missing = semantic_value_samples::recursive_ref("Missing");
    let payload = JsonValue::Bool(true);
    let fields = [("a", SlotValue::Present(JsonValueView::from_json(&payload)))];
    let mut validator = PreparedValidator::new(&graph, FormatWorkspace::empty());
    let slot_c13 = required_slot(&product);
    let (decision, count) = counted(|| {
        validator.decide_view_slot(
            &slot_c13,
            SlotValue::Present(JsonValueView::object(&fields)),
        )
    });
    let BorrowedValueDecision::Unresolved(recipe) = decision else {
        panic!("unresolved field is not unresolved");
    };
    let expected = ValueDecision::Unresolved(vec![SemanticObligation {
        type_ref: missing.clone(),
        origin: (&missing).into(),
        value_path: vec![],
        profile: graph.profile.reference.clone(),
        reason: SemanticReason::UnresolvedType,
    }]);
    let owned_input = JsonValue::Obj(vec![("a".into(), payload.clone())]);
    assert_eq!(
        PreparedValidator::new(&graph, FormatWorkspace::empty())
            .accepts_value(&product, &owned_input),
        expected
    );
    assert_eq!(recipe.materialize(), expected);
    assert_eq!(count, 0, "unresolved view path allocated");
}

#[test]
fn prepared_validator_missing_required_slot_keeps_owned_fields() {
    assert_positive_control();
    let graph = check_type_signatures(&v2a_library()).unwrap();
    let flag = v2a_reference(&graph, "flag");
    let slot = SlotContract {
        type_ref: flag.clone(),
        required: true,
        nullable: false,
    };
    let owned = PreparedValidator::new(&graph, FormatWorkspace::empty())
        .accepts_slot(&slot, SlotValue::Absent);
    assert!(matches!(
        &owned,
        ValueDecision::Rejected(ValueFailure {
            condition: ValueCondition::MissingRequired,
            ..
        })
    ));
    let mut validator = PreparedValidator::new(&graph, FormatWorkspace::empty());
    let (decision, count) =
        counted(|| validator.decide_view_slot(&slot, borrowed_slot_view(SlotValue::Absent)));
    let BorrowedValueDecision::Rejected(recipe) = decision else {
        panic!("missing required slot is accepted");
    };
    assert_eq!(recipe.materialize(), owned);
    assert_eq!(count, 0, "slot window allocated");
}

#[test]
fn prepared_validator_v3_missing_field_window_keeps_owned_fields() {
    assert_positive_control();
    let graph = check_type_signatures(&semantic_value_samples::v3_product_library()).unwrap();
    let product = v2a_reference(&graph, "product");
    let null = JsonValue::Null;
    let missing_fields = [
        ("payload", SlotValue::Absent),
        ("omitted", SlotValue::Absent),
        (
            "nullable",
            SlotValue::Present(JsonValueView::from_json(&null)),
        ),
    ];
    let owned_input = JsonValue::Obj(vec![("nullable".into(), JsonValue::Null)]);
    let owned = PreparedValidator::new(&graph, FormatWorkspace::empty())
        .accepts_value(&product, &owned_input);
    assert!(matches!(&owned, ValueDecision::Rejected(_)));
    let mut validator = PreparedValidator::new(&graph, FormatWorkspace::empty());
    let slot_c11 = required_slot(&product);
    let (decision, count) = counted(|| {
        validator.decide_view_slot(
            &slot_c11,
            SlotValue::Present(JsonValueView::object(&missing_fields)),
        )
    });
    let BorrowedValueDecision::Rejected(recipe) = decision else {
        panic!("missing payload is accepted");
    };
    assert_eq!(recipe.materialize(), owned);
    assert_eq!(count, 0, "missing-field window allocated");
}

#[test]
fn prepared_validator_missing_named_format_samples_keep_static_expectations() {
    assert_positive_control();
    let (string_graph, string_ref, tag_graph, tag_ref) =
        semantic_value_samples::missing_named_format_inputs();
    let mut string_validator = PreparedValidator::new(&string_graph, FormatWorkspace::empty());
    let ok = JsonValue::Str("ok".into());
    let slot_c10 = required_slot(&string_ref);
    let (decision, count) = counted(|| {
        string_validator
            .decide_view_slot(&slot_c10, SlotValue::Present(JsonValueView::from_json(&ok)))
    });
    assert!(matches!(decision, BorrowedValueDecision::Unresolved(_)));
    assert_eq!(count, 0, "string sample allocated");
    let BorrowedValueDecision::Unresolved(recipe) = decision else {
        panic!("missing named format is not unresolved");
    };
    let ValueDecision::Unresolved(obligations) = recipe.materialize() else {
        panic!("missing named format did not materialize as unresolved");
    };
    assert!(obligations.iter().any(|obligation| obligation.reason
        == SemanticReason::UnknownFormat("pval-missing-format".into())));

    let value = JsonValue::Obj(vec![("$tag".into(), JsonValue::Str("v".into()))]);
    let expected = ValueDecision::Rejected(ValueFailure {
        definition_ref: DefinitionRef {
            source: tag_ref.source.clone(),
            name: "value".into(),
        },
        origin: OccurrenceRef::from(&tag_ref),
        type_ref: tag_ref.clone(),
        value_path: vec![PathStep::Field("$tag".into())],
        condition: ValueCondition::InvalidTag,
        observed: SlotValue::Present(JsonValue::Str("v".into())),
        reference_trace: vec![],
    });
    assert_eq!(
        PreparedValidator::new(&tag_graph, FormatWorkspace::empty())
            .accepts_value(&tag_ref, &value),
        expected
    );
    let mut tag_validator = PreparedValidator::new(&tag_graph, FormatWorkspace::empty());
    let slot_c9 = required_slot(&tag_ref);
    let (decision, count) = counted(|| {
        tag_validator.decide_view_slot(
            &slot_c9,
            SlotValue::Present(JsonValueView::from_json(&value)),
        )
    });
    let BorrowedValueDecision::Rejected(recipe) = decision else {
        panic!("tag sample is accepted");
    };
    assert_eq!(recipe.materialize(), expected);
    assert_eq!(count, 0, "tag sample allocated");
}

#[test]
fn prepared_validator_decimal_string_integers_keep_lean_contract() {
    assert_positive_control();
    let mut library = semantic_value_samples::library();
    library.nodes.push(TypeNodeInput {
        id: "bounded".into(),
        shape: Shape::Integer(IntegerSpec {
            domain: Some("integer".into()),
            minimum: None,
            maximum: None,
            const_value: None,
            enum_values: None,
            default_value: None,
        }),
    });
    let graph = check_type_signatures(&library).unwrap();
    let bounded = signature_type_ref("bounded");
    let mut validator = PreparedValidator::new(&graph, FormatWorkspace::empty());
    for text in ["5", "1.0e1"] {
        let value = JsonValue::Str(text.into());
        let slot_c8 = required_slot(&bounded);
        let (decision, count) = counted(|| {
            validator.decide_view_slot(
                &slot_c8,
                SlotValue::Present(JsonValueView::from_json(&value)),
            )
        });
        assert!(
            matches!(decision, BorrowedValueDecision::Accepted),
            "{text}"
        );
        assert_eq!(count, 0, "{text} allocated");
        assert!(matches!(
            PreparedValidator::new(&graph, FormatWorkspace::empty())
                .accepts_value(&bounded, &value),
            ValueDecision::Accepted
        ));
    }
    let value = JsonValue::Str("1.5e1".into());
    let owned =
        PreparedValidator::new(&graph, FormatWorkspace::empty()).accepts_value(&bounded, &value);
    assert!(matches!(
        &owned,
        ValueDecision::Rejected(ValueFailure {
            condition: ValueCondition::IntegerDomain,
            ..
        })
    ));
    let slot_c7 = required_slot(&bounded);
    let (decision, count) = counted(|| {
        validator.decide_view_slot(
            &slot_c7,
            SlotValue::Present(JsonValueView::from_json(&value)),
        )
    });
    let BorrowedValueDecision::Rejected(recipe) = decision else {
        panic!("1.5e1 accepted");
    };
    assert_eq!(recipe.materialize(), owned);
    assert_eq!(count, 0);
    for invalid in ["+5", "05", " 5", "5 ", "1.5e0"] {
        let value = JsonValue::Str(invalid.into());
        let owned = PreparedValidator::new(&graph, FormatWorkspace::empty())
            .accepts_value(&bounded, &value);
        assert!(
            matches!(
                &owned,
                ValueDecision::Rejected(ValueFailure {
                    condition: ValueCondition::WrongValueKind(_),
                    ..
                })
            ),
            "{invalid}"
        );
        let slot_c6 = required_slot(&bounded);
        let (decision, count) = counted(|| {
            validator.decide_view_slot(
                &slot_c6,
                SlotValue::Present(JsonValueView::from_json(&value)),
            )
        });
        let BorrowedValueDecision::Rejected(recipe) = decision else {
            panic!("{invalid} accepted");
        };
        assert_eq!(recipe.materialize(), owned, "{invalid}");
        assert_eq!(count, 0, "{invalid} allocated");
    }
}

#[test]
fn prepared_validator_typed_decimal_bounds_keep_ordering_without_powers() {
    assert_positive_control();
    let mut library = semantic_value_samples::library();
    library.nodes.push(TypeNodeInput {
        id: "decimal-max-zero".into(),
        shape: Shape::Decimal(DecimalSpec {
            minimum: None,
            maximum: Some(DecimalBound {
                mantissa: BigInt::from(0),
                scale: BigUint::from(0u8),
                exclusive: false,
            }),
        }),
    });
    library.nodes.push(TypeNodeInput {
        id: "decimal-min-one".into(),
        shape: Shape::Decimal(DecimalSpec {
            minimum: Some(DecimalBound {
                mantissa: BigInt::from(1),
                scale: BigUint::from(0u8),
                exclusive: false,
            }),
            maximum: None,
        }),
    });
    let graph = check_type_signatures(&library).unwrap();
    let max_zero = signature_type_ref("decimal-max-zero");
    let min_one = signature_type_ref("decimal-min-one");
    let mut validator = PreparedValidator::new(&graph, FormatWorkspace::empty());
    let cases = [
        (&max_zero, "1e9999", ValueCondition::AboveMaximum),
        (&min_one, "1e-9999", ValueCondition::BelowMinimum),
        (&max_zero, "1e10000", ValueCondition::InvalidDataModel),
        (&min_one, "1e-10000", ValueCondition::InvalidDataModel),
        (&max_zero, "1e5000000000", ValueCondition::InvalidDataModel),
        (
            &min_one,
            "1e-99999999999999999999",
            ValueCondition::InvalidDataModel,
        ),
    ];
    for (reference, text, condition) in cases {
        let value = JsonValue::Dec(text.into());
        let owned = PreparedValidator::new(&graph, FormatWorkspace::empty())
            .accepts_value(reference, &value);
        assert!(
            matches!(&owned, ValueDecision::Rejected(ValueFailure { condition: c, .. }) if *c == condition),
            "{text}"
        );
        let slot_c5 = required_slot(reference);
        let (decision, count) = counted(|| {
            validator.decide_view_slot(
                &slot_c5,
                SlotValue::Present(JsonValueView::from_json(&value)),
            )
        });
        let BorrowedValueDecision::Rejected(recipe) = decision else {
            panic!("{text} accepted");
        };
        assert_eq!(recipe.materialize(), owned, "{text}");
        assert_eq!(count, 0, "{text} allocated");
    }
    let zero = JsonValue::Dec("0".into());
    let slot_c4 = required_slot(&max_zero);
    let (decision, count) = counted(|| {
        validator.decide_view_slot(
            &slot_c4,
            SlotValue::Present(JsonValueView::from_json(&zero)),
        )
    });
    assert!(matches!(decision, BorrowedValueDecision::Accepted));
    assert_eq!(count, 0);
}

#[test]
fn prepared_validator_data_numbers_keep_lean_data_contract() {
    assert_positive_control();
    let mut library = semantic_value_samples::library();
    library.nodes.push(TypeNodeInput {
        id: "any".into(),
        shape: Shape::Unknown(UnknownKind::Any),
    });
    semantic_value_samples::fixture_item_mut(&mut library.profile.integer_domains, 0).forms =
        vec![IntegerForm::DecimalString];
    for decimals in [true, false] {
        library.profile.numbers.decimals = decimals;
        let graph = check_type_signatures(&library).unwrap();
        let any = signature_type_ref("any");
        let mut validator = PreparedValidator::new(&graph, FormatWorkspace::empty());
        let num = JsonValue::Num(BigInt::from(1));
        let owned =
            PreparedValidator::new(&graph, FormatWorkspace::empty()).accepts_value(&any, &num);
        let slot_c3 = required_slot(&any);
        let (decision, count) = counted(|| {
            validator.decide_view_slot(&slot_c3, SlotValue::Present(JsonValueView::from_json(&num)))
        });
        let BorrowedValueDecision::Rejected(recipe) = decision else {
            panic!("number 1 accepted");
        };
        assert_eq!(recipe.materialize(), owned);
        assert!(matches!(
            &owned,
            ValueDecision::Rejected(ValueFailure {
                condition: ValueCondition::IntegerDomain,
                ..
            })
        ));
        assert_eq!(count, 0);
        for text in ["1.5", " 1.5 "] {
            let value = JsonValue::Dec(text.into());
            let owned = PreparedValidator::new(&graph, FormatWorkspace::empty())
                .accepts_value(&any, &value);
            let slot_c2 = required_slot(&any);
            let (decision, count) = counted(|| {
                validator.decide_view_slot(
                    &slot_c2,
                    SlotValue::Present(JsonValueView::from_json(&value)),
                )
            });
            assert_eq!(count, 0, "{text}");
            match decision {
                BorrowedValueDecision::Accepted => {
                    assert!(decimals, "{text}");
                    assert!(matches!(owned, ValueDecision::Accepted), "{text}");
                }
                BorrowedValueDecision::Rejected(recipe) => {
                    assert!(!decimals, "{text}");
                    assert_eq!(recipe.materialize(), owned, "{text}");
                    assert!(
                        matches!(
                            &owned,
                            ValueDecision::Rejected(ValueFailure {
                                condition: ValueCondition::InvalidDataModel,
                                ..
                            })
                        ),
                        "{text}"
                    );
                }
                BorrowedValueDecision::Unresolved(_) => panic!("{text} unresolved"),
            }
        }
    }
}

#[test]
fn prepared_validator_same_owned_projection_inputs_accept_without_allocation() {
    assert_positive_control();
    let mut library = semantic_value_samples::library();
    *semantic_value_samples::fixture_item_mut(&mut library.profile.integer_domains, 0) =
        IntegerDomainBinding {
            name: "integer".into(),
            reference: ProfileRef {
                identity: "p".into(),
                revision: "1".into(),
                content_digest: "d".into(),
            },
            range: IntegerDomain::Unbounded,
            forms: vec![
                IntegerForm::Number,
                IntegerForm::IntegralDecimal,
                IntegerForm::DecimalString,
            ],
        };
    library.nodes.push(TypeNodeInput {
        id: "integer-node".into(),
        shape: Shape::Integer(IntegerSpec {
            domain: Some("integer".into()),
            minimum: None,
            maximum: None,
            const_value: None,
            enum_values: None,
            default_value: None,
        }),
    });
    let graph = check_type_signatures(&library).unwrap();
    let node = signature_type_ref("integer-node");
    let cases = [
        JsonValue::Num(BigInt::from(5)),
        JsonValue::Dec("120.0e-1".into()),
        JsonValue::Str("1.0e1".into()),
    ];
    let mut validator = PreparedValidator::new(&graph, FormatWorkspace::empty());
    for value in &cases {
        let owned =
            PreparedValidator::new(&graph, FormatWorkspace::empty()).accepts_value(&node, value);
        assert!(matches!(owned, ValueDecision::Accepted), "{value:?}");
        let slot_c1 = required_slot(&node);
        let (decision, count) = counted(|| {
            validator.decide_view_slot(
                &slot_c1,
                SlotValue::Present(JsonValueView::from_json(value)),
            )
        });
        assert!(
            matches!(decision, BorrowedValueDecision::Accepted),
            "{value:?}"
        );
        assert_eq!(count, 0, "{value:?} allocated");
    }
}

fn repeated_validation_allocations(filler: usize) -> usize {
    let mut library = semantic_value_samples::library();
    let string_shape = || {
        Shape::String(StringSpec {
            format: None,
            lengths: vec![],
            wrapper: None,
            const_value: None,
            enum_values: None,
            examples: vec![],
            default_value: None,
        })
    };
    library.nodes.push(TypeNodeInput {
        id: "target-node".into(),
        shape: string_shape(),
    });
    for index in 0..filler {
        library.nodes.push(TypeNodeInput {
            id: format!("filler-{index}"),
            shape: string_shape(),
        });
    }
    let graph = check_type_signatures(&library).unwrap();
    let target = signature_type_ref("target-node");
    let accepted = JsonValue::Str("abc".into());
    let rejected = JsonValue::Bool(true);
    let mut validator = PreparedValidator::new(&graph, FormatWorkspace::empty());
    assert_eq!(
        validator.accepts_value(&target, &accepted),
        ValueDecision::Accepted
    );
    let (decisions, count) = counted(|| {
        let mut accepted_count = 0;
        for _ in 0..8 {
            if validator.accepts_value(&target, &accepted) == ValueDecision::Accepted {
                accepted_count += 1;
            }
            std::hint::black_box(matches!(
                validator.accepts_value(&target, &accepted),
                ValueDecision::Accepted
            ));
        }
        accepted_count
    });
    assert_eq!(decisions, 8);
    assert!(matches!(
        validator.accepts_value(&target, &rejected),
        ValueDecision::Rejected(_)
    ));
    count
}

#[test]
fn prepared_validator_repeated_accepts_do_not_scale_with_graph_nodes() {
    assert_positive_control();
    let small = repeated_validation_allocations(50);
    let large = repeated_validation_allocations(500);
    println!("allocations: small={small} large={large}");
    assert_eq!(small, large);
    assert_eq!(large, 0);
}

fn repeated_expansion_and_default_allocations(filler: usize) -> (usize, usize) {
    let string_shape = |default_value: Option<String>| {
        Shape::String(StringSpec {
            format: None,
            lengths: vec![],
            wrapper: None,
            const_value: None,
            enum_values: None,
            examples: vec![],
            default_value,
        })
    };
    let mut library = semantic_value_samples::library();
    library.nodes.push(TypeNodeInput {
        id: "target-node".into(),
        shape: string_shape(None),
    });
    library.nodes.push(TypeNodeInput {
        id: "defaulted-node".into(),
        shape: string_shape(Some("fallback".into())),
    });
    library.nodes.push(TypeNodeInput {
        id: "holder-node".into(),
        shape: Shape::Product(SignatureProduct {
            fields: vec![SignatureField {
                wire_name: "slot".into(),
                slot: SignatureSlot {
                    type_id: "defaulted-node".into(),
                    required: false,
                    nullable: false,
                },
            }],
            extras: SignatureExtraMembers::Reject,
        }),
    });
    for index in 0..filler {
        library.nodes.push(TypeNodeInput {
            id: format!("filler-{index}"),
            shape: string_shape(None),
        });
    }
    let graph = check_type_signatures(&library).unwrap();
    let target = signature_type_ref("target-node");
    let holder = signature_type_ref("holder-node");
    let accepted = JsonValue::Str("abc".into());
    let missing = JsonValue::Obj(vec![]);
    let mut validator = PreparedValidator::new(&graph, FormatWorkspace::empty());
    assert!(matches!(
        validator.expand_value(&target, &[], &accepted),
        Expansion::Requirements(_)
    ));
    let defaulted = materialize_defaults(&validator, &holder, &missing).unwrap();
    assert_eq!(defaulted.applications().len(), 1);
    let (expansions, expansion_count) = counted(|| {
        let mut requirement_sets = 0;
        for _ in 0..8 {
            if matches!(
                validator.expand_value(&target, &[], &accepted),
                Expansion::Requirements(_)
            ) {
                requirement_sets += 1;
            }
        }
        requirement_sets
    });
    assert_eq!(expansions, 8);
    let (materialized, default_count) = counted(|| {
        let mut applied = 0;
        for _ in 0..8 {
            applied += materialize_defaults(&validator, &holder, &missing)
                .unwrap()
                .applications()
                .len();
        }
        applied
    });
    assert_eq!(materialized, 8);
    (expansion_count, default_count)
}

#[test]
fn prepared_validator_repeated_expansion_and_defaults_do_not_scale_with_graph_nodes() {
    assert_positive_control();
    let small = repeated_expansion_and_default_allocations(50);
    let large = repeated_expansion_and_default_allocations(500);
    println!("expansion/default allocations: small={small:?} large={large:?}");
    assert_eq!(small, large);
    assert_eq!(large.0, 0);
}

#[test]
fn prepared_validator_first_use_after_preparation_does_not_allocate() {
    assert_positive_control();
    let mut library = semantic_value_samples::library();
    let fields = (0..6)
        .map(|index| SignatureField {
            wire_name: format!("f{index}"),
            slot: SignatureSlot {
                type_id: "text".into(),
                required: true,
                nullable: false,
            },
        })
        .collect();
    library.nodes.push(TypeNodeInput {
        id: "wide".into(),
        shape: Shape::Product(SignatureProduct {
            fields,
            extras: SignatureExtraMembers::Reject,
        }),
    });
    let graph = check_type_signatures(&library).unwrap();
    let wide = signature_type_ref("wide");
    let value = JsonValue::Obj(
        (0..6)
            .map(|index| (format!("f{index}"), JsonValue::Str("ok".into())))
            .collect(),
    );
    let mut validator = PreparedValidator::new(&graph, FormatWorkspace::empty());
    let slot = required_slot(&wide);
    let (decision, count) = counted(|| {
        validator.decide_view_slot(&slot, SlotValue::Present(JsonValueView::from_json(&value)))
    });
    assert!(matches!(decision, BorrowedValueDecision::Accepted));
    assert_eq!(count, 0, "first use after preparation allocated");
}
