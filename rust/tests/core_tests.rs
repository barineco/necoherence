// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

#![allow(clippy::panic)]
#![allow(clippy::indexing_slicing)]
#![allow(clippy::unwrap_used)]
use necoherence::{
    apply, bump, command_of, lookup, world_of, Basis, Command, Lookup, Nat, Observation, Outcome,
    ResourceId, Revision, StaleBasis, UnknownResource,
};
use proptest::prelude::*;

fn rid(name: u32) -> ResourceId {
    ResourceId {
        kind: "test".to_string(),
        name: name.to_string(),
    }
}

fn nat(n: u64) -> Nat {
    Nat::from(n)
}

proptest! {
    #[test]
    fn outcome_closure(n1 in 0u32..5, r1 in 0u64..10, n2 in 0u32..5, r2 in 0u64..10) {
        let w = world_of([(rid(n1), Revision { value: nat(r1) })]);
        let outcome = apply(
            &w,
            Command {
                intent: "x".to_string(),
                basis: Basis { resource: rid(n2), revision: Revision { value: nat(r2) } },
            },
        );
        let closed = matches!(
            outcome,
            Outcome::Applied(_) | Outcome::Rejected(_) | Outcome::Conflicted(_) | Outcome::BoundaryFailed(_)
        );
        prop_assert!(closed);
    }

    #[test]
    fn basis_retention(r in 0u64..10, payload in 0u64..100) {
        let observation = Observation {
            payload,
            basis: Basis { resource: rid(0), revision: Revision { value: nat(r) } },
            observed_at: nat(0),
        };
        let command = command_of(&observation, "intent".to_string());
        prop_assert_eq!(command.basis, observation.basis);
    }

    #[test]
    fn stale_conflict(held in 1u64..10, requested_delta in 1u64..10) {
        let held_rev = nat(held);
        let requested = nat(held + requested_delta);
        let w = world_of([(rid(0), Revision { value: held_rev.clone() })]);
        let outcome = apply(
            &w,
            Command { intent: "x".to_string(), basis: Basis { resource: rid(0), revision: Revision { value: requested.clone() } } },
        );
        prop_assert_eq!(
            outcome,
            Outcome::Conflicted(StaleBasis { expected: Revision { value: requested }, actual: Revision { value: held_rev } })
        );
    }

    #[test]
    fn apply_disjoint_comm(r0 in 0u64..10, r1 in 0u64..10, r2 in 0u64..10) {
        let w = world_of([
            (rid(0), Revision { value: nat(r0) }),
            (rid(1), Revision { value: nat(r1) }),
            (rid(2), Revision { value: nat(r2) }),
        ]);
        let c1 = Command { intent: "a".to_string(), basis: Basis { resource: rid(0), revision: Revision { value: nat(r0) } } };
        let c2 = Command { intent: "b".to_string(), basis: Basis { resource: rid(1), revision: Revision { value: nat(r1) } } };

        let Outcome::Applied((_, w1)) = apply(&w, c1.clone()) else { unreachable!() };
        let Outcome::Applied((_, w12)) = apply(&w1, c2.clone()) else { unreachable!() };
        let Outcome::Applied((_, w2)) = apply(&w, c2) else { unreachable!() };
        let Outcome::Applied((_, w21)) = apply(&w2, c1) else { unreachable!() };

        for resource in [rid(0), rid(1), rid(2), rid(99)] {
            prop_assert_eq!(lookup(&w12, &resource), lookup(&w21, &resource));
        }
    }

    #[test]
    fn bump_locality(r0 in 0u64..10, r1 in 0u64..10) {
        let w = world_of([(rid(0), Revision { value: nat(r0) }), (rid(1), Revision { value: nat(r1) })]);
        let bumped = bump(&w, &rid(0));
        prop_assert_eq!(lookup(&bumped, &rid(0)), Lookup::Found(Revision { value: nat(r0 + 1) }));
        prop_assert_eq!(lookup(&bumped, &rid(1)), Lookup::Found(Revision { value: nat(r1) }));
    }

    #[test]
    fn world_lookup_is_closed(present in prop::bool::ANY, r in 0u64..10) {
        let w = if present { world_of([(rid(0), Revision { value: nat(r) })]) } else { world_of([]) };
        match lookup(&w, &rid(0)) {
            Lookup::Found(rev) => {
                let expected = Revision { value: nat(r) };
                prop_assert!(present && rev == expected);
            }
            Lookup::Unknown(UnknownResource { resource }) => {
                let expected = rid(0);
                prop_assert!(!present && resource == expected);
            }
        }
    }
}
