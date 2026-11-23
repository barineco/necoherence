// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/option.{None, Some}
import necoherence/exact_json as json
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation
import semantic_test_support as support

fn with_tag(tag: option.Option(types.TagModel)) -> types.SemanticProfile {
  types.SemanticProfile(..support.profile(), tag: tag)
}

fn with_wrappers(wrappers: List(types.Wrapper)) -> types.SemanticProfile {
  types.SemanticProfile(..support.profile(), wrappers: wrappers)
}

pub fn tag_value_accepts_members_without_a_tag_model_test() {
  let profile = with_tag(None)
  let assert True =
    validation.tag_value_accepts(profile, [#("tag", json.JsonValueNum(1))])
}

pub fn tag_value_accepts_an_absent_tag_member_test() {
  let profile = with_tag(Some(types.TagModel("tag", Some("key-x"), [])))
  let assert True = validation.tag_value_accepts(profile, [])
}

pub fn tag_value_accepts_a_string_matching_the_tag_format_test() {
  let profile = with_tag(Some(types.TagModel("tag", Some("key-x"), [])))
  let assert True =
    validation.tag_value_accepts(profile, [#("tag", json.JsonValueStr("x"))])
}

pub fn tag_value_rejects_a_string_outside_the_tag_format_test() {
  let profile = with_tag(Some(types.TagModel("tag", Some("key-x"), [])))
  let assert False =
    validation.tag_value_accepts(profile, [#("tag", json.JsonValueStr("y"))])
}

pub fn tag_value_rejects_a_non_string_tag_member_test() {
  let profile = with_tag(Some(types.TagModel("tag", None, [])))
  let assert False =
    validation.tag_value_accepts(profile, [#("tag", json.JsonValueNum(1))])
}

pub fn text_wrapper_is_the_first_text_wrapper_test() {
  let profile =
    with_wrappers([
      types.Wrapper("bytes", "bytes", types.WrapperBytes),
      types.Wrapper("first", "first", types.WrapperText(None)),
      types.Wrapper("second", "second", types.WrapperText(None)),
    ])
  let assert Some(types.Wrapper(name, _, _)) = validation.text_wrapper(profile)
  let assert "first" = name
}

pub fn text_wrapper_is_absent_without_a_text_wrapper_test() {
  let profile =
    with_wrappers([types.Wrapper("bytes", "bytes", types.WrapperBytes)])
  let assert None = validation.text_wrapper(profile)
}

pub fn wrapper_text_accepts_the_payload_under_the_text_wrapper_key_test() {
  let value = json.JsonValueObj([#("text", json.JsonValueStr("abc"))])
  let assert True = validation.wrapper_text_accepts(support.profile(), value)
}

pub fn wrapper_text_rejects_a_payload_under_another_key_test() {
  let value = json.JsonValueObj([#("other", json.JsonValueStr("abc"))])
  let assert False = validation.wrapper_text_accepts(support.profile(), value)
}

pub fn wrapper_text_rejects_every_value_without_a_text_wrapper_test() {
  let profile =
    with_wrappers([types.Wrapper("bytes", "bytes", types.WrapperBytes)])
  let value = json.JsonValueObj([#("bytes", json.JsonValueStr("abc"))])
  let assert False = validation.wrapper_text_accepts(profile, value)
}

pub fn data_value_accepts_a_string_in_the_data_model_test() {
  let assert True =
    validation.data_value_accepts(support.profile(), json.JsonValueStr("abc"))
}

pub fn data_value_accepts_an_integer_in_the_unbounded_domain_test() {
  let assert True =
    validation.data_value_accepts(support.profile(), json.JsonValueNum(1))
}

pub fn data_value_rejects_an_object_with_a_duplicate_key_test() {
  let value =
    json.JsonValueObj([
      #("a", json.JsonValueNum(1)),
      #("a", json.JsonValueNum(2)),
    ])
  let assert False = validation.data_value_accepts(support.profile(), value)
}
