// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use serde_json::{json, Value};

/// 合成の goal が実行結果として観測させる量の族の宣言。成功時の出力、失敗の埋め込み、最終的な資源の要求、中断とネットワーク指示の列、残余 ( residual ) の集合、型付き実行失敗の種類、結果の来歴を定める。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GoalObservations(Value);

const EXECUTION_FAILURES: [&str; 13] = [
    "argumentCoverage",
    "invalidOutcome",
    "invalidPlan",
    "missingArgument",
    "missingProvider",
    "missingValue",
    "network",
    "networkTerminal",
    "provider",
    "providerCoverage",
    "providerEffect",
    "resource",
    "value",
];

pub(crate) const KEYS: [&str; 7] = [
    "effects",
    "execution_failures",
    "failures",
    "final_resources",
    "outputs",
    "provenance",
    "residuals",
];

fn member(value: &Value, key: &str) -> Value {
    value.get(key).cloned().unwrap_or(Value::Null)
}

fn rows(value: &Value, keys: &[&str]) -> Value {
    Value::Array(
        value
            .as_array()
            .map(|items| {
                items
                    .iter()
                    .map(|item| {
                        Value::Object(
                            keys.iter()
                                .map(|key| ((*key).to_owned(), member(item, key)))
                                .collect(),
                        )
                    })
                    .collect()
            })
            .unwrap_or_default(),
    )
}

fn plan_returns(tree: &Value) -> Vec<Value> {
    let node = member(tree, "node");
    match node.get("tag").and_then(Value::as_str) {
        Some("Return") => vec![member(&node, "value")],
        Some("Invoke" | "Guard") => node
            .get("fields")
            .and_then(|fields| fields.get("arms"))
            .and_then(Value::as_array)
            .map(|arms| {
                arms.iter()
                    .filter_map(|arm| match arm.as_array().map(Vec::as_slice) {
                        Some([_, tree]) => Some(tree),
                        _ => None,
                    })
                    .flat_map(plan_returns)
                    .collect()
            })
            .unwrap_or_default(),
        _ => Vec::new(),
    }
}

fn returned_ports(value: &Value) -> Vec<String> {
    value
        .get("value")
        .and_then(Value::as_array)
        .map(|pairs| {
            pairs
                .iter()
                .filter_map(|pair| pair.as_array()?.first()?.as_str().map(str::to_owned))
                .collect()
        })
        .unwrap_or_default()
}

fn row_id(item: &Value) -> Option<&str> {
    item.get("id").and_then(Value::as_str)
}

fn row_ids(rows: &Value) -> Vec<String> {
    rows.as_array()
        .map(|items| items.iter().filter_map(row_id).map(str::to_owned).collect())
        .unwrap_or_default()
}

fn first_occurrences(values: impl Iterator<Item = String>) -> Vec<String> {
    let mut seen = Vec::new();
    for value in values {
        if !seen.contains(&value) {
            seen.push(value);
        }
    }
    seen
}

fn kept_rows(
    rows_value: &Value,
    keys: &[&str],
    kept: impl Fn(&str) -> bool,
    extra: &[String],
) -> Value {
    let declared: Vec<Value> = rows_value
        .as_array()
        .map(|items| {
            items
                .iter()
                .filter(|item| kept(row_id(item).unwrap_or("")))
                .cloned()
                .collect()
        })
        .unwrap_or_default();
    let Value::Array(mut projected) = rows(&Value::Array(declared), keys) else {
        unreachable!()
    };
    projected.extend(extra.iter().map(|id| {
        Value::Object(
            keys.iter()
                .map(|key| {
                    let value = if *key == "id" {
                        Value::String(id.clone())
                    } else {
                        Value::Null
                    };
                    ((*key).to_owned(), value)
                })
                .collect(),
        )
    }));
    Value::Array(projected)
}

impl GoalObservations {
    /// 合成の問題の `goal` から観測関数族を作る。
    pub fn of_composition(composition: &Value) -> Self {
        let goal = member(&member(composition, "problem"), "goal");
        Self(json!({
            "outputs": rows(&member(&goal, "outputs"), &["id", "contract"]),
            "failures": rows(&member(&goal, "failures"), &["id", "contract", "final_resources"]),
            "final_resources": member(&goal, "final_resources"),
            "effects": ["network_instruction", "pending"],
            "residuals": "residual_set",
            "execution_failures": EXECUTION_FAILURES,
            "provenance": "certificate_basis",
        }))
    }

    /// 合成の導出の Return 節点が出力する値と失敗の埋め込みから作る観測関数族。Return 節点の集まりが goal の宣言と一致する時に、goal から作る観測関数族と等しい。
    pub fn of_plan(composition: &Value) -> Self {
        let goal = member(&member(composition, "problem"), "goal");
        let returns = plan_returns(&member(
            &member(&member(composition, "derivation"), "plan"),
            "root",
        ));
        let is_success =
            |value: &Value| value.get("tag").and_then(Value::as_str) == Some("Success");
        let successes: Vec<Vec<String>> = returns
            .iter()
            .filter(|value| is_success(value))
            .map(returned_ports)
            .collect();
        let embeddings: Vec<String> = returns
            .iter()
            .filter(|value| !is_success(value))
            .filter_map(|value| {
                value
                    .get("fields")
                    .and_then(|fields| fields.get("embedding"))
                    .and_then(Value::as_str)
                    .map(str::to_owned)
            })
            .collect();
        let outputs = member(&goal, "outputs");
        let failures = member(&goal, "failures");
        let output_ids = row_ids(&outputs);
        let failure_ids = row_ids(&failures);
        let undeclared_ports = first_occurrences(
            successes
                .iter()
                .flatten()
                .filter(|port| !output_ids.contains(port))
                .cloned(),
        );
        let undeclared_embeddings = first_occurrences(
            embeddings
                .iter()
                .filter(|embedding| !failure_ids.contains(embedding))
                .cloned(),
        );
        let returned_output = |id: &str| {
            !successes.is_empty()
                && successes
                    .iter()
                    .all(|ports| ports.iter().any(|port| port == id))
        };
        Self(json!({
            "outputs": kept_rows(&outputs, &["id", "contract"], returned_output, &undeclared_ports),
            "failures": kept_rows(
                &failures,
                &["id", "contract", "final_resources"],
                |id| embeddings.iter().any(|embedding| embedding == id),
                &undeclared_embeddings,
            ),
            "final_resources": member(&goal, "final_resources"),
            "effects": ["network_instruction", "pending"],
            "residuals": "residual_set",
            "execution_failures": EXECUTION_FAILURES,
            "provenance": "certificate_basis",
        }))
    }

    pub fn value(&self) -> &Value {
        &self.0
    }

    pub(crate) fn from_wire(value: Value) -> Option<Self> {
        let object = value.as_object()?;
        (object.len() == KEYS.len() && KEYS.iter().all(|key| object.contains_key(*key)))
            .then_some(Self(value))
    }
}
