// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use necoherence::{
    closure_output, fold_output, immediate_of, recurse_output, ClosureOutcome, FoldOutcome, Nat,
    RecurseOutcome, Request, StepOutcome,
};
use std::collections::BTreeSet;

use proptest::prelude::*;

fn nat(n: u64) -> Nat {
    Nat::from(n)
}

proptest! {
    #[test]
    fn fold_runs_count_rounds(count in 0u64..30) {
        let step = immediate_of::<u64, u64, _>("test.increment", vec!["value".to_string()], |x| x + 1);
        let outcome = fold_output(&step, &["value".to_string()], 0u64, &nat(count));
        match outcome {
            FoldOutcome::Trace(states) => {
                prop_assert_eq!(states.len() as u64, count + 1);
                prop_assert_eq!(states.last().copied(), Some(count));
            }
            FoldOutcome::Stopped(..) => prop_assert!(false, "fold should not stop"),
        }
    }

    #[test]
    fn recurse_settles_with_strictly_decreasing_measure(start in 1u64..50) {
        let step = immediate_of::<u64, StepOutcome<u64>, _>("test.decrement", vec!["value".to_string()], |x| {
            if *x == 0 {
                StepOutcome::Settled(0)
            } else {
                StepOutcome::Advance(x - 1, Nat::from(*x))
            }
        });
        match recurse_output(&step, &["value".to_string()], start) {
            RecurseOutcome::Settled(value, steps) => {
                prop_assert_eq!(value, 0);
                prop_assert_eq!(steps, nat(start));
            }
            other => prop_assert!(false, "unexpected {other:?}"),
        }
    }

    #[test]
    fn recurse_reports_did_not_decrease(_x in 0u64..5) {
        let step = immediate_of::<u64, StepOutcome<u64>, _>("test.stuck", vec!["value".to_string()], |x| {
            StepOutcome::Advance(x + 1, nat(5))
        });
        match recurse_output(&step, &["value".to_string()], 0u64) {
            RecurseOutcome::DidNotDecrease(position, _, measure, previous_measure) => {
                prop_assert_eq!(position, nat(1));
                prop_assert_eq!(measure, nat(5));
                prop_assert_eq!(previous_measure, nat(5));
            }
            other => prop_assert!(false, "unexpected {other:?}"),
        }
    }

    #[test]
    fn closure_reaches_fixpoint(seed_size in 1usize..3) {
        let edges: Vec<(u64, Vec<u64>)> = vec![(1, vec![2]), (2, vec![3]), (3, vec![])];
        let step = immediate_of::<necoherence::ClosureState<u64>, BTreeSet<u64>, _>(
            "test.reach",
            vec!["elements".to_string()],
            move |state| {
                let mut grown = state.elements.clone();
                for node in &state.elements {
                    if let Some((_, outs)) = edges.iter().find(|(n, _)| n == node) {
                        for next in outs {
                            grown.insert(*next);
                        }
                    }
                }
                grown
            },
        );
        let carrier: BTreeSet<u64> = [1u64, 2, 3].into_iter().collect();
        let seed: BTreeSet<u64> = [1u64].into_iter().take(seed_size.min(1)).collect();
        match closure_output(&step, &["elements".to_string()], carrier.clone(), seed) {
            ClosureOutcome::Fixpoint(elements, _) => {
                prop_assert!(elements.is_subset(&carrier));
                prop_assert_eq!(elements, carrier);
            }
            other => prop_assert!(false, "unexpected {other:?}"),
        }
    }

    #[test]
    fn closure_reports_violation_when_not_extensive(_x in 0u64..3) {
        let step = immediate_of::<necoherence::ClosureState<u64>, BTreeSet<u64>, _>(
            "test.shrinks",
            vec!["elements".to_string()],
            |_state| BTreeSet::new(),
        );
        let carrier: BTreeSet<u64> = [1u64, 2].into_iter().collect();
        let seed: BTreeSet<u64> = [1u64].into_iter().collect();
        match closure_output(&step, &["elements".to_string()], carrier, seed) {
            ClosureOutcome::Violation(position, current, produced) => {
                prop_assert_eq!(position, nat(0));
                prop_assert_eq!(current, [1u64].into_iter().collect());
                prop_assert!(produced.is_empty());
            }
            other => prop_assert!(false, "unexpected {other:?}"),
        }
    }

    #[test]
    fn fold_projection_failure_stops_at_missing_fields(_x in 0u64..3) {
        let step = immediate_of::<u64, u64, _>("test.increment", vec!["value".to_string()], |x| x + 1);
        let outcome = fold_output(&step, &[], 0u64, &nat(3));
        match outcome {
            FoldOutcome::Stopped(states, stopped) => {
                prop_assert_eq!(states, vec![0u64]);
                prop_assert_eq!(stopped.position, nat(0));
            }
            FoldOutcome::Trace(_) => prop_assert!(false, "fold should stop"),
        }
    }
}

#[test]
fn request_field_projection_smoke() {
    let step = immediate_of::<u64, u64, _>("test.identity", vec!["value".to_string()], |x| *x);
    let request = Request {
        payload: 1u64,
        fields: vec!["value".to_string()],
    };
    assert_eq!(
        necoherence::io(&step, &request),
        necoherence::CallResult::Ok(1u64)
    );
}
