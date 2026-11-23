// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

import necoherence/semantic_types as types

pub fn profile_predicate_code(predicate: types.ProfilePredicate) -> String {
  case predicate {
    types.Pr01 -> "pr01"
    types.Pr02 -> "pr02"
    types.Pr03 -> "pr03"
    types.Pr04 -> "pr04"
    types.Pr05 -> "pr05"
    types.Pr06 -> "pr06"
    types.Pr07 -> "pr07"
    types.Pr08 -> "pr08"
    types.Pr09 -> "pr09"
    types.Pr10 -> "pr10"
    types.Pr11 -> "pr11"
    types.Pr12 -> "pr12"
    types.Pr13 -> "pr13"
    types.Pr14 -> "pr14"
    types.Pr15 -> "pr15"
    types.Pr16 -> "pr16"
  }
}

pub fn library_predicate_code(predicate: types.LibraryPredicate) -> String {
  case predicate {
    types.Lb01 -> "lb01"
    types.Lb02 -> "lb02"
    types.Lb03 -> "lb03"
    types.Lb04 -> "lb04"
    types.Lb05 -> "lb05"
    types.Lb06 -> "lb06"
    types.Lb07 -> "lb07"
    types.Lb08 -> "lb08"
    types.Lb09 -> "lb09"
    types.Lb10 -> "lb10"
    types.Lb11 -> "lb11"
    types.Lb12 -> "lb12"
    types.Lb13 -> "lb13"
    types.Lb14 -> "lb14"
    types.Lb15 -> "lb15"
    types.Lb16 -> "lb16"
    types.Lb17 -> "lb17"
    types.Lb18 -> "lb18"
    types.Lb19 -> "lb19"
  }
}
