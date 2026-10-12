// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

#![allow(clippy::panic)]
#![allow(clippy::indexing_slicing)]
#![allow(clippy::unwrap_used)]
use necoherence::{step, Capacity, Consumption, Nat, PositiveLimit, StepFailure, StepTransition};
use proptest::prelude::*;

fn nat(n: u64) -> Nat {
    Nat::from(n)
}

proptest! {
    #[test]
    fn consuming_immediately_settles_after_one_application(outputs in 0usize..5) {
        let produced: Vec<u64> = (0..outputs as u64).collect();
        let limit = PositiveLimit::new(nat(3)).unwrap();
        let capacity = Capacity { value: nat(outputs as u64) };
        let produced_clone = produced.clone();
        let result = step(
            0u64,
            &(),
            move |s, _i| Consumption::Consumed(*s, produced_clone.clone()),
            &limit,
            &capacity,
        );
        match result {
            StepTransition::Settled(_, out, applications) => {
                prop_assert_eq!(out, produced);
                prop_assert_eq!(applications, nat(1));
            }
            StepTransition::Failed(..) => prop_assert!(false, "expected settled"),
        }
    }

    #[test]
    fn reprocess_limit_exhausted_reports_applications(limit_n in 1u64..6) {
        let limit = PositiveLimit::new(nat(limit_n)).unwrap();
        let capacity = Capacity { value: nat(100) };
        let result = step(0u64, &(), |s, _i| Consumption::Reprocess(*s, Vec::<u64>::new()), &limit, &capacity);
        match result {
            StepTransition::Failed(_, out, StepFailure::ReprocessLimitExhausted(applications)) => {
                prop_assert!(out.is_empty());
                prop_assert_eq!(applications, nat(limit_n));
            }
            other => prop_assert!(false, "unexpected {other:?}"),
        }
    }

    #[test]
    fn capacity_exceeded_reports_attempted(capacity_n in 0u64..3) {
        let limit = PositiveLimit::new(nat(5)).unwrap();
        let capacity = Capacity { value: nat(capacity_n) };
        let result = step(0u64, &(), |s, _i| Consumption::Consumed(*s, vec![1u64, 2, 3, 4]), &limit, &capacity);
        match result {
            StepTransition::Failed(_, _, StepFailure::CapacityExceeded(c, attempted)) => {
                prop_assert_eq!(c, nat(capacity_n));
                prop_assert_eq!(attempted, nat(4));
            }
            other => prop_assert!(false, "unexpected {other:?}"),
        }
    }

    #[test]
    fn zero_capacity_settles_with_no_output(_x in 0u64..3) {
        let limit = PositiveLimit::new(nat(3)).unwrap();
        let capacity = Capacity { value: nat(0) };
        let result = step(0u64, &(), |s, _i| Consumption::Consumed(*s, Vec::<u64>::new()), &limit, &capacity);
        match result {
            StepTransition::Settled(_, out, applications) => {
                prop_assert!(out.is_empty());
                prop_assert_eq!(applications, nat(1));
            }
            StepTransition::Failed(..) => prop_assert!(false, "expected settled"),
        }
    }
}

#[test]
fn zero_limit_is_invalid() {
    assert!(PositiveLimit::new(Nat::from(0u8)).is_none());
}
