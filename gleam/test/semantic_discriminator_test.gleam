// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/option.{None}
import necoherence/exact_json as json
import necoherence/semantic_generation_runtime as runtime
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation
import semantic_test_support as support

fn graph() -> types.SemanticGraph {
  let product =
    support.node(
      "product",
      types.ProductShape(types.ProductSpec([], types.RejectExtras)),
    )
  let text = support.node("text", types.StringShape(support.string_spec(None)))
  let flag =
    support.node("flag", types.BooleanShape(types.BooleanSpec(None, None)))
  support.graph([
    product,
    text,
    flag,
    support.node(
      "union",
      types.TaggedUnionShape(
        types.UnionSpec([
          types.UnionBranch(
            support.reference("product"),
            "internal",
            types.InternalTag,
            support.occurrence(),
          ),
          types.UnionBranch(
            support.reference("product"),
            "shape",
            types.MemberShape([#("shape", types.FormatMember("text"))]),
            support.occurrence(),
          ),
          types.UnionBranch(
            support.reference("text"),
            "string",
            types.Kind(types.StringKind),
            support.occurrence(),
          ),
          types.UnionBranch(
            support.reference("flag"),
            "otherwise",
            types.Otherwise,
            support.occurrence(),
          ),
        ]),
      ),
    ),
  ])
}

pub fn union_discriminator_selects_each_declared_branch_test() {
  let graph = graph()
  let profile = graph.profile
  let assert Ok(0) =
    runtime.select_branch(
      profile,
      [#("internal", types.InternalTag)],
      json.JsonValueObj([#("tag", json.JsonValueStr("internal"))]),
    )
  let assert Ok(0) =
    runtime.select_branch(
      profile,
      [#("shape", types.MemberShape([#("shape", types.FormatMember("text"))]))],
      json.JsonValueObj([#("shape", json.JsonValueStr("anything"))]),
    )
  let assert Ok(0) =
    runtime.select_branch(
      profile,
      [#("string", types.Kind(types.StringKind))],
      json.JsonValueStr("value"),
    )
  let assert Ok(0) =
    runtime.select_branch(
      profile,
      [#("otherwise", types.Otherwise)],
      json.JsonValueBool(True),
    )
}

pub fn otherwise_branch_preserves_selected_branch_failure_test() {
  let graph = graph()
  let assert types.RejectedValue(missing) =
    validation.declared_value_decision(
      graph,
      support.reference("union"),
      json.JsonValueObj([]),
    )
  let assert types.WrongValueKindCondition("boolean") = missing.condition
  let assert types.RejectedValue(unknown) =
    validation.declared_value_decision(
      graph,
      support.reference("union"),
      json.JsonValueObj([#("tag", json.JsonValueStr("unknown"))]),
    )
  let assert types.WrongValueKindCondition("boolean") = unknown.condition
}
