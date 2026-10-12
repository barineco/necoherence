// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use necoherence::{deferred_of, immediate_of, io, issue, CallResult, Request};
use proptest::prelude::*;

proptest! {
    #[test]
    fn io_settles_when_fields_present(x in 0i64..1000) {
        let decl = immediate_of::<i64, i64, _>("test.increment", vec!["value".to_string()], |v| v + 1);
        let req = Request { payload: x, fields: vec!["value".to_string()] };
        prop_assert_eq!(io(&decl, &req), CallResult::Ok(x + 1));
    }

    #[test]
    fn io_fails_when_fields_missing(x in 0i64..1000) {
        let decl = immediate_of::<i64, i64, _>("test.increment", vec!["value".to_string()], |v| v + 1);
        let req = Request { payload: x, fields: vec![] };
        match io(&decl, &req) {
            CallResult::Failed(f) => {
                prop_assert_eq!(f.declaration, "test.increment");
                prop_assert_eq!(f.fields, vec!["value".to_string()]);
            }
            CallResult::Ok(_) => prop_assert!(false, "expected failure"),
        }
    }

    #[test]
    fn issue_settles_when_fields_present(x in 0i64..1000) {
        let decl = deferred_of::<i64, i64, _>("test.slot", vec!["value".to_string()], |v| v * 2);
        let req = Request { payload: x, fields: vec!["value".to_string()] };
        prop_assert_eq!(issue(&decl, &req), CallResult::Ok(x * 2));
    }
}
