// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

pub fn json(value: &necoherence::network_effect::NetworkFailure) -> serde_json::Value {
    serde_json::to_value(value).expect("NetworkFailure serialization")
}
