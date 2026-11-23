// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use necoherence::semantic_exchange::GenerationFailure;
use serde_json::Value;

pub fn syntax_failure(path: &str, message: &str) -> GenerationFailure {
    GenerationFailure::Syntax {
        path: path.to_owned(),
        message: message.to_owned(),
    }
}

pub fn missing_field(object_path: &str, key: &str) -> GenerationFailure {
    syntax_failure(&format!("{object_path}.{key}"), "property not found")
}

pub fn required_field<'a>(
    object: &'a Value,
    object_path: &str,
    key: &str,
) -> Result<&'a Value, GenerationFailure> {
    object
        .get(key)
        .ok_or_else(|| missing_field(object_path, key))
}

pub fn required_lifted_field<'a>(
    object: &'a Value,
    object_path: &str,
    key: &str,
) -> Result<&'a Value, GenerationFailure> {
    object
        .get(key)
        .ok_or_else(|| syntax_failure(object_path, "property not found"))
}

pub fn required_str<'a>(
    object: &'a Value,
    object_path: &str,
    key: &str,
) -> Result<&'a str, GenerationFailure> {
    required_field(object, object_path, key)?
        .as_str()
        .ok_or_else(|| syntax_failure(&format!("{object_path}.{key}"), "String expected"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_missing_key_is_reported_under_its_object_path() {
        assert_eq!(
            required_field(&json!({}), "$.graph", "reference"),
            Err(GenerationFailure::Syntax {
                path: "$.graph.reference".into(),
                message: "property not found".into(),
            })
        );
    }

    #[test]
    fn a_lifted_key_is_reported_at_the_object_path() {
        assert_eq!(
            required_lifted_field(&json!({}), "$", "value"),
            Err(GenerationFailure::Syntax {
                path: "$".into(),
                message: "property not found".into(),
            })
        );
    }

    #[test]
    fn a_non_string_value_is_rejected_at_its_own_path() {
        assert_eq!(
            required_str(&json!({"id": 5}), "$", "id"),
            Err(GenerationFailure::Syntax {
                path: "$.id".into(),
                message: "String expected".into(),
            })
        );
    }

    #[test]
    fn a_present_string_is_returned_unchanged() {
        assert_eq!(
            required_str(&json!({"kind": "wire"}), "$", "kind"),
            Ok("wire")
        );
    }
}
