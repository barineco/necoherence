//// Shared general boundary composition package (`necoherence`).
//// Public capabilities: `README.md`.

// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import necoherence/network_effect

pub fn package_name() -> String {
  "necoherence"
}

pub fn network_effect_empty_state() -> network_effect.NetworkState {
  network_effect.empty_state()
}
