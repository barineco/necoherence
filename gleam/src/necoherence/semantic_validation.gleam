// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import necoherence/exact_json as kdl
import necoherence/semantic_base64 as base64
import necoherence/semantic_generation_values as generation_values
import necoherence/semantic_types as types

pub type ValidationFailure {
  Rejected(failure: types.ValueFailure)
  Unresolved(obligations: List(types.SemanticObligation))
  CertificateMismatchFailure(condition: String)
}

pub type MemberProof {
  MemberProof(children: List(MemberProof))
}

pub opaque type ValidatedValue {
  ValidatedValue(
    graph: types.SemanticGraph,
    type_ref: types.TypeRef,
    value: kdl.JsonValue,
    proof: MemberProof,
  )
}

pub opaque type ValidatedSlot {
  ValidatedSlot(
    graph: types.SemanticGraph,
    contract: types.SlotContract,
    value: types.SlotValue(kdl.JsonValue),
    proof: Option(MemberProof),
  )
}

pub type DefaultApplication {
  DefaultApplication(
    value_path: types.ValuePath,
    type_ref: types.TypeRef,
    origin: types.OccurrenceRef,
    value: kdl.JsonValue,
  )
}

pub opaque type DefaultedValue {
  DefaultedValue(
    graph: types.SemanticGraph,
    type_ref: types.TypeRef,
    value: kdl.JsonValue,
    applications: List(DefaultApplication),
    proof: MemberProof,
  )
}

pub type ProjectionAssumption {
  Present(path: types.ValuePath)
  NonNull(path: types.ValuePath)
  Variant(path: types.ValuePath, tag: String)
  IndexPresent(path: types.ValuePath, index: Int)
}

pub type ProjectionCertificate {
  ProjectionCertificate(
    profile: types.ProfileRef,
    source_refs: List(types.SourceRef),
    source: types.SlotContract,
    path: types.ValuePath,
    assumptions: List(ProjectionAssumption),
    destination: types.SlotContract,
  )
}

pub type ProjectionFailure {
  WrongShape(type_ref: types.TypeRef, path: types.ValuePath)
  MissingField(type_ref: types.TypeRef, name: String)
  MissingVariant(type_ref: types.TypeRef, tag: String)
  BranchAssumptionRequired(path: types.ValuePath, tag: String)
  ProjectionUnresolved(obligations: List(types.SemanticObligation))
  CertificateMismatch(condition: String)
}

pub type ProjectionValueFailure {
  Projection(failure: ProjectionFailure)
  Validation(failure: ValidationFailure)
  UnsatisfiedGuard
}

pub fn validated_value_graph(value: ValidatedValue) -> types.SemanticGraph {
  value.graph
}

pub fn validated_value_type_ref(value: ValidatedValue) -> types.TypeRef {
  value.type_ref
}

pub fn validated_value(value: ValidatedValue) -> kdl.JsonValue {
  value.value
}

pub fn validated_value_proof(value: ValidatedValue) -> MemberProof {
  value.proof
}

pub fn validated_slot_graph(value: ValidatedSlot) -> types.SemanticGraph {
  value.graph
}

pub fn validated_slot_contract(value: ValidatedSlot) -> types.SlotContract {
  value.contract
}

pub fn validated_slot_value(
  value: ValidatedSlot,
) -> types.SlotValue(kdl.JsonValue) {
  value.value
}

pub fn defaulted_value_graph(value: DefaultedValue) -> types.SemanticGraph {
  value.graph
}

pub fn defaulted_value_type_ref(value: DefaultedValue) -> types.TypeRef {
  value.type_ref
}

pub fn defaulted_value(value: DefaultedValue) -> kdl.JsonValue {
  value.value
}

pub fn defaulted_value_applications(
  value: DefaultedValue,
) -> List(DefaultApplication) {
  value.applications
}

type GraphemeState {
  GraphemeState(
    previous: Option(types.GraphemeProperty),
    regional_run: Int,
    ep_extend: Bool,
    previous_zwj_after_ep: Bool,
    indic_consonant: Bool,
    indic_linker: Bool,
  )
}

pub fn grapheme_count(rules: types.GraphemeRules, text: String) -> Int {
  segment_text(rules, text, 0, fn(count, _) { count + 1 }).1
}

pub fn grapheme_boundaries(
  rules: types.GraphemeRules,
  text: String,
) -> List(Int) {
  let #(length, boundaries) =
    segment_text(rules, text, [], fn(boundaries, offset) {
      [offset, ..boundaries]
    })
  case length {
    0 -> []
    _ -> list.reverse([length, ..boundaries])
  }
}

fn segment_text(
  rules: types.GraphemeRules,
  text: String,
  initial: a,
  boundary: fn(a, Int) -> a,
) -> #(Int, a) {
  let codepoints =
    list.map(string.to_utf_codepoints(text), string.utf_codepoint_to_int)
  segment_graphemes(
    rules,
    codepoints,
    GraphemeState(None, 0, False, False, False, False),
    0,
    initial,
    boundary,
  )
}

fn segment_graphemes(
  rules: types.GraphemeRules,
  codepoints: List(Int),
  state: GraphemeState,
  offset: Int,
  accumulated: a,
  boundary: fn(a, Int) -> a,
) -> #(Int, a) {
  case codepoints {
    [] -> #(offset, accumulated)
    [codepoint, ..rest] -> {
      let property = grapheme_property(rules, codepoint)
      let indic = indic_property(rules, codepoint)
      let pictographic =
        in_codepoint_ranges(rules.extended_pictographic, codepoint)
      let breaks = grapheme_break(state, property, indic, pictographic)
      let accumulated = case breaks {
        True -> boundary(accumulated, offset)
        False -> accumulated
      }
      let zwj_after_ep = property == types.Zwj && state.ep_extend
      let ep_extend =
        pictographic || property == types.Extend && state.ep_extend
      let #(indic_consonant, indic_linker) =
        next_indic_state(indic, state.indic_consonant, state.indic_linker)
      let regional_run = case property == types.RegionalIndicator {
        False -> 0
        True ->
          case state.previous {
            Some(types.RegionalIndicator) -> state.regional_run + 1
            _ -> 1
          }
      }
      segment_graphemes(
        rules,
        rest,
        GraphemeState(
          Some(property),
          regional_run,
          ep_extend,
          zwj_after_ep,
          indic_consonant,
          indic_linker,
        ),
        offset + 1,
        accumulated,
        boundary,
      )
    }
  }
}

fn grapheme_break(
  state: GraphemeState,
  current: types.GraphemeProperty,
  indic: types.IndicProperty,
  pictographic: Bool,
) -> Bool {
  case state.previous {
    None -> True
    Some(types.Cr) if current == types.Lf -> False
    Some(types.Cr) | Some(types.Lf) | Some(types.Control) -> True
    _
      if current == types.Cr || current == types.Lf || current == types.Control
    -> True
    Some(types.L)
      if current == types.L
      || current == types.V
      || current == types.Lv
      || current == types.Lvt
    -> False
    Some(types.Lv) | Some(types.V) if current == types.V || current == types.T ->
      False
    Some(types.Lvt) | Some(types.T) if current == types.T -> False
    _
      if current == types.Extend
      || current == types.Zwj
      || current == types.SpacingMark
    -> False
    Some(types.Prepend) -> False
    _
      if indic == types.Consonant && state.indic_consonant && state.indic_linker
    -> False
    Some(types.Zwj) if pictographic && state.previous_zwj_after_ep -> False
    Some(types.RegionalIndicator)
      if current == types.RegionalIndicator && state.regional_run % 2 == 1
    -> False
    _ -> True
  }
}

fn next_indic_state(
  indic: types.IndicProperty,
  has_consonant: Bool,
  has_linker: Bool,
) -> #(Bool, Bool) {
  case indic {
    types.Consonant -> #(True, False)
    types.Linker if has_consonant -> #(True, True)
    types.IndicExtend | types.Linker -> #(has_consonant, has_linker)
    types.IndicOther -> #(False, False)
  }
}

fn grapheme_property(
  rules: types.GraphemeRules,
  codepoint: Int,
) -> types.GraphemeProperty {
  case
    list.find(rules.properties, fn(range) {
      codepoint >= range.first && codepoint <= range.last
    })
  {
    Ok(range) -> range.property
    Error(_) -> types.Other
  }
}

fn indic_property(
  rules: types.GraphemeRules,
  codepoint: Int,
) -> types.IndicProperty {
  case
    list.find(rules.indic_conjunct, fn(range) {
      codepoint >= range.first && codepoint <= range.last
    })
  {
    Ok(range) -> range.property
    Error(_) -> types.IndicOther
  }
}

fn in_codepoint_ranges(
  ranges: List(types.CodepointRange),
  codepoint: Int,
) -> Bool {
  list.any(ranges, fn(range) {
    codepoint >= range.first && codepoint <= range.last
  })
}

pub fn recognizes(rule: types.FormatRule, text: String) -> Bool {
  let #(node, _) = compile_format_span(rule, 0)
  let #(offsets, count, _) =
    list.fold(
      string.to_utf_codepoints(text),
      #(dict.new(), 0, 0),
      fn(state, point) {
        let #(offsets, count, bytes) = state
        #(
          dict.insert(offsets, count, bytes),
          count + 1,
          bytes + string.byte_size(string.from_utf_codepoints([point])),
        )
      },
    )
  let context =
    FormatSpanContext(
      bit_array.from_string(text),
      dict.insert(offsets, count, string.byte_size(text)),
    )
  span_accepts(node, context, 0, count, dict.new()).0
}

type FormatSpanNode {
  SpanEpsilon(id: Int)
  SpanSequence(id: Int, left: FormatSpanNode, right: FormatSpanNode)
  SpanRule(id: Int, rule: types.FormatRule, children: List(FormatSpanNode))
}

type FormatSpanContext {
  FormatSpanContext(source: BitArray, offsets: Dict(Int, Int))
}

type FormatSpanMemo =
  Dict(#(Int, Int, Int), Bool)

fn compile_format_span(
  rule: types.FormatRule,
  next: Int,
) -> #(FormatSpanNode, Int) {
  let parts = case rule {
    types.Sequence(parts) | types.Choice(parts) -> parts
    types.Optional(child)
    | types.Not(child)
    | types.Bounded(_, _, child)
    | types.Labels(_, _, _, _, child) -> [child]
    _ -> []
  }
  let #(children, next) = compile_format_children(parts, next)
  case rule {
    types.Sequence(_) -> binary_format_sequence(children, next)
    _ -> #(SpanRule(next, rule, children), next + 1)
  }
}

fn compile_format_children(
  parts: List(types.FormatRule),
  next: Int,
) -> #(List(FormatSpanNode), Int) {
  case parts {
    [] -> #([], next)
    [part, ..rest] -> {
      let #(child, next) = compile_format_span(part, next)
      let #(children, next) = compile_format_children(rest, next)
      #([child, ..children], next)
    }
  }
}

fn binary_format_sequence(
  children: List(FormatSpanNode),
  next: Int,
) -> #(FormatSpanNode, Int) {
  case children {
    [] -> #(SpanEpsilon(next), next + 1)
    [child] -> #(child, next)
    [_, _, ..] -> {
      let #(left, right) = list.split(children, list.length(children) / 2)
      let #(left, next) = binary_format_sequence(left, next)
      let #(right, next) = binary_format_sequence(right, next)
      #(SpanSequence(next, left, right), next + 1)
    }
  }
}

fn span_text(context: FormatSpanContext, start: Int, end: Int) -> String {
  let assert Ok(first) = dict.get(context.offsets, start)
  let assert Ok(last) = dict.get(context.offsets, end)
  let assert Ok(bytes) = bit_array.slice(context.source, first, last - first)
  let assert Ok(text) = bit_array.to_string(bytes)
  text
}

fn span_accepts(
  node: FormatSpanNode,
  context: FormatSpanContext,
  start: Int,
  end: Int,
  memo: FormatSpanMemo,
) -> #(Bool, FormatSpanMemo) {
  let id = case node {
    SpanEpsilon(id) | SpanSequence(id, _, _) | SpanRule(id, _, _) -> id
  }
  let key = #(id, start, end)
  case dict.get(memo, key) {
    Ok(accepted) -> #(accepted, memo)
    Error(_) -> {
      let #(accepted, memo) = case node {
        SpanEpsilon(_) -> #(start == end, memo)
        SpanSequence(_, left, right) ->
          span_sequence(left, right, context, start, end, start, memo)
        SpanRule(_, rule, children) ->
          span_rule(rule, children, context, start, end, memo)
      }
      #(accepted, dict.insert(memo, key, accepted))
    }
  }
}

fn span_sequence(
  left: FormatSpanNode,
  right: FormatSpanNode,
  context: FormatSpanContext,
  start: Int,
  end: Int,
  split: Int,
  memo: FormatSpanMemo,
) -> #(Bool, FormatSpanMemo) {
  case split > end {
    True -> #(False, memo)
    False -> {
      let #(prefix, memo) = span_accepts(left, context, start, split, memo)
      let #(accepted, memo) = case prefix {
        True -> span_accepts(right, context, split, end, memo)
        False -> #(False, memo)
      }
      case accepted {
        True -> #(True, memo)
        False ->
          span_sequence(left, right, context, start, end, split + 1, memo)
      }
    }
  }
}

fn span_choices(
  children: List(FormatSpanNode),
  context: FormatSpanContext,
  start: Int,
  end: Int,
  memo: FormatSpanMemo,
) -> #(Bool, FormatSpanMemo) {
  case children {
    [] -> #(False, memo)
    [child, ..rest] -> {
      let #(accepted, memo) = span_accepts(child, context, start, end, memo)
      case accepted {
        True -> #(True, memo)
        False -> span_choices(rest, context, start, end, memo)
      }
    }
  }
}

fn span_labels(
  parts: List(String),
  child: FormatSpanNode,
  separator_length: Int,
  context: FormatSpanContext,
  cursor: Int,
  memo: FormatSpanMemo,
) -> #(Bool, FormatSpanMemo) {
  case parts {
    [] -> #(True, memo)
    [part, ..rest] -> {
      let end = cursor + list.length(string.to_utf_codepoints(part))
      let #(accepted, memo) = span_accepts(child, context, cursor, end, memo)
      case accepted {
        True ->
          span_labels(
            rest,
            child,
            separator_length,
            context,
            end + separator_length,
            memo,
          )
        False -> #(False, memo)
      }
    }
  }
}

fn span_rule(
  rule: types.FormatRule,
  children: List(FormatSpanNode),
  context: FormatSpanContext,
  start: Int,
  end: Int,
  memo: FormatSpanMemo,
) -> #(Bool, FormatSpanMemo) {
  case rule, children {
    types.Choice(_), _ -> span_choices(children, context, start, end, memo)
    types.Optional(_), [child] ->
      case start == end {
        True -> #(True, memo)
        False -> span_accepts(child, context, start, end, memo)
      }
    types.Not(_), [child] -> {
      let #(accepted, memo) = span_accepts(child, context, start, end, memo)
      #(!accepted, memo)
    }
    types.Bounded(unit, maximum, _), [child] ->
      case bounded_length(unit, maximum, span_text(context, start, end)) {
        True -> span_accepts(child, context, start, end, memo)
        False -> #(False, memo)
      }
    types.Labels(separator, minimum, maximum, total_maximum, _), [child] -> {
      let parts = string.split(span_text(context, start, end), separator)
      let count = list.length(parts)
      case
        separator != ""
        && count >= minimum
        && option_int_ok(maximum, count)
        && option_int_ok(total_maximum, end - start)
      {
        True ->
          span_labels(
            parts,
            child,
            list.length(string.to_utf_codepoints(separator)),
            context,
            start,
            memo,
          )
        False -> #(False, memo)
      }
    }
    _, _ -> #(recognizes_leaf(rule, span_text(context, start, end)), memo)
  }
}

fn recognizes_leaf(rule: types.FormatRule, text: String) -> Bool {
  case rule {
    types.Literal(value) -> value == text
    types.Identifier(first, rest, exact, minimum, maximum, forbidden) -> {
      let length = string.byte_size(text)
      let exact_length_valid = case exact {
        None -> True
        Some(expected) -> expected == length
      }
      length == string.length(text)
      && length >= minimum
      && option.unwrap(option.map(maximum, fn(upper) { length <= upper }), True)
      && exact_length_valid
      && !list.contains(forbidden, text)
      && ascii_alphabet(text, first, rest)
    }
    types.AbsoluteUri(maximum) -> absolute_uri(maximum, text)
    types.Timestamp(rule) -> timestamp(rule, text)
    types.LanguageTag(grandfathered) -> language_tag(grandfathered, text)
    types.AsciiDfa(spec) -> recognize_dfa(spec, text)
    types.Text -> True
    types.Sequence(_)
    | types.Optional(_)
    | types.Labels(_, _, _, _, _)
    | types.Bounded(_, _, _)
    | types.Choice(_)
    | types.Not(_) -> False
  }
}

fn option_int_ok(limit: Option(Int), value: Int) -> Bool {
  case limit {
    None -> True
    Some(maximum) -> value <= maximum
  }
}

fn bounded_length(
  unit: types.StringLengthUnit,
  maximum: Int,
  text: String,
) -> Bool {
  case unit {
    types.Utf8Bytes -> string.byte_size(text) <= maximum
    types.UnicodeScalars ->
      list.length(string.to_utf_codepoints(text)) <= maximum
    types.Graphemes -> list.length(string.to_graphemes(text)) <= maximum
  }
}

fn ascii_alphabet(text: String, first: String, rest: String) -> Bool {
  case string.to_graphemes(text) {
    [] -> False
    [head, ..tail] ->
      string.contains(first, head)
      && list.all(tail, fn(part) { string.contains(rest, part) })
  }
}

fn ascii_alphanumeric(text: String) -> Bool {
  ascii_alpha(text) || ascii_digit(text)
}

fn ascii_alpha(text: String) -> Bool {
  text != ""
  && list.all(string.to_graphemes(text), fn(char) {
    string.contains(
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz",
      char,
    )
  })
}

fn ascii_digit(text: String) -> Bool {
  text != ""
  && list.all(string.to_graphemes(text), fn(char) {
    string.contains("0123456789", char)
  })
}

fn recognize_dfa(spec: types.DfaSpec, text: String) -> Bool {
  case string.byte_size(text) == string.length(text) {
    False -> False
    True -> run_dfa(spec, string.to_graphemes(text), spec.initial_state)
  }
}

fn run_dfa(spec: types.DfaSpec, chars: List(String), state: Int) -> Bool {
  case chars {
    [] -> list.contains(spec.accepting_states, state)
    [char, ..rest] ->
      case ascii_byte(char) {
        None -> False
        Some(byte) ->
          case
            list.find(spec.transitions, fn(transition) {
              transition.from_state == state
              && byte >= transition.first
              && byte <= transition.last
            })
          {
            Error(_) -> False
            Ok(transition) -> run_dfa(spec, rest, transition.to_state)
          }
      }
  }
}

fn ascii_byte(char: String) -> Option(Int) {
  case string.to_utf_codepoints(char) {
    [codepoint] -> {
      let value = string.utf_codepoint_to_int(codepoint)
      case value < 128 {
        True -> Some(value)
        False -> None
      }
    }
    _ -> None
  }
}

fn absolute_uri(maximum: Int, text: String) -> Bool {
  case
    string.byte_size(text) <= maximum
    && string.byte_size(text) == string.length(text)
  {
    False -> False
    True ->
      case string.split_once(text, ":") {
        Error(_) -> False
        Ok(#(scheme, rest)) ->
          case valid_scheme(scheme) {
            False -> False
            True -> {
              let without_fragment = string.split_once(rest, "#")
              let fragment_valid = case without_fragment {
                Ok(#(_, fragment)) -> uri_component(fragment, "/?:@")
                Error(_) -> True
              }
              let hierarchy = case without_fragment {
                Ok(#(value, _)) -> value
                Error(_) -> rest
              }
              let without_query = string.split_once(hierarchy, "?")
              let query_valid = case without_query {
                Ok(#(_, query)) -> uri_component(query, "/?:@")
                Error(_) -> True
              }
              let path_or_authority = case without_query {
                Ok(#(value, _)) -> value
                Error(_) -> hierarchy
              }
              fragment_valid
              && query_valid
              && absolute_hierarchy(path_or_authority)
            }
          }
      }
  }
}

fn valid_scheme(scheme: String) -> Bool {
  case string.to_graphemes(scheme) {
    [first, ..rest] ->
      string.contains(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz",
        first,
      )
      && list.all(rest, fn(char) {
        ascii_alphanumeric(char) || string.contains("+-.", char)
      })
    _ -> False
  }
}

fn absolute_hierarchy(hierarchy: String) -> Bool {
  case string.starts_with(hierarchy, "//") {
    False -> uri_component(hierarchy, "/:@")
    True ->
      case string.split(string.drop_start(hierarchy, 2), "/") {
        [authority, ..path] ->
          valid_authority(authority)
          && uri_component(string.join(path, "/"), "/:@")
        _ -> False
      }
  }
}

fn valid_authority(authority: String) -> Bool {
  case string.split(authority, "@") {
    [host] -> valid_host_port(host)
    [userinfo, host] -> uri_component(userinfo, ":") && valid_host_port(host)
    _ -> False
  }
}

fn valid_host_port(host_port: String) -> Bool {
  case string.starts_with(host_port, "[") {
    True ->
      case string.split_once(host_port, "]") {
        Error(_) -> False
        Ok(#(address, port)) -> {
          let port_syntax_valid = port == "" || string.starts_with(port, ":")
          valid_ip_literal(string.remove_prefix(address, "["))
          && valid_port(string.remove_prefix(port, ":"))
          && port_syntax_valid
        }
      }
    False ->
      case string.split(host_port, ":") {
        [host] -> uri_component(host, "")
        [host, port] -> uri_component(host, "") && valid_port(port)
        _ -> False
      }
  }
}

fn valid_ip_literal(address: String) -> Bool {
  case string.to_graphemes(address) {
    [version, ..rest] ->
      case string.lowercase(version) == "v" {
        True -> valid_ipv_future(string.concat(rest))
        False -> valid_ipv6(address)
      }
    _ -> valid_ipv6(address)
  }
}

fn valid_ipv_future(text: String) -> Bool {
  case string.split_once(text, ".") {
    Ok(#(version, address)) ->
      version != ""
      && list.all(string.to_graphemes(version), hex_digit)
      && address != ""
      && uri_component(address, ":")
    _ -> False
  }
}

fn valid_ipv6(address: String) -> Bool {
  case string.split_once(address, "::") {
    Error(_) -> {
      let groups = string.split(address, ":")
      valid_ipv6_groups(groups, False) && ipv6_group_count(groups, []) == 8
    }
    Ok(#(left, right)) -> {
      let left_groups = string.split(left, ":")
      let right_groups = string.split(right, ":")
      !string.contains(left, "::")
      && !string.contains(right, "::")
      && !string.contains(left, ".")
      && valid_ipv6_groups(left_groups, True)
      && valid_ipv6_groups(right_groups, True)
      && ipv6_group_count(left_groups, right_groups) < 8
    }
  }
}

fn valid_ipv6_groups(groups: List(String), allow_empty_side: Bool) -> Bool {
  let nonempty = list.filter(groups, fn(group) { group != "" })
  let sides_valid = case allow_empty_side {
    True -> True
    False -> nonempty == groups
  }
  case sides_valid {
    False -> False
    True ->
      case nonempty {
        [] -> allow_empty_side
        _ -> {
          let ipv4_tail = list.last(nonempty) |> result.unwrap("")
          let ipv4_valid = case string.contains(ipv4_tail, ".") {
            True -> valid_ipv4(ipv4_tail)
            False -> False
          }
          let hex_groups = case ipv4_valid {
            True -> list.drop(nonempty, list.length(nonempty) - 1)
            False -> nonempty
          }
          let hex_valid =
            list.all(hex_groups, fn(group) {
              string.length(group) >= 1
              && string.length(group) <= 4
              && list.all(string.to_graphemes(group), hex_digit)
            })
          let ipv4_position_valid = case
            list.any(nonempty, fn(group) { string.contains(group, ".") })
          {
            True -> ipv4_valid && list.last(nonempty) == Ok(ipv4_tail)
            False -> True
          }
          hex_valid && ipv4_position_valid
        }
      }
  }
}

fn ipv6_group_count(left: List(String), right: List(String)) -> Int {
  let groups = list.append(left, right)
  let ipv4_extra = case
    list.any(groups, fn(group) { string.contains(group, ".") })
  {
    True -> 1
    False -> 0
  }
  list.length(list.filter(groups, fn(group) { group != "" })) + ipv4_extra
}

fn valid_ipv4(text: String) -> Bool {
  let octets = string.split(text, ".")
  list.length(octets) == 4
  && list.all(octets, fn(octet) {
    case int.parse(octet) {
      Ok(value) -> {
        let canonical = case octet {
          "0" -> True
          _ -> !string.starts_with(octet, "0")
        }
        value >= 0 && value <= 255 && canonical
      }
      Error(_) -> False
    }
  })
}

fn valid_port(port: String) -> Bool {
  port == "" || digits(port)
}

fn uri_component(text: String, extra: String) -> Bool {
  uri_component_chars(string.to_graphemes(text), extra)
}

fn uri_component_chars(chars: List(String), extra: String) -> Bool {
  case chars {
    [] -> True
    ["%", first, second, ..rest] ->
      hex_digit(first) && hex_digit(second) && uri_component_chars(rest, extra)
    [first, ..rest] ->
      uri_char(first, extra) && uri_component_chars(rest, extra)
  }
}

fn uri_char(char: String, extra: String) -> Bool {
  ascii_alphanumeric(char)
  || string.contains("-._~!$&'()*+,;=", char)
  || string.contains(extra, char)
}

fn hex_digit(char: String) -> Bool {
  string.contains("0123456789abcdefABCDEF", char)
}

fn timestamp(rule: types.CalendarRule, text: String) -> Bool {
  let chars = string.to_graphemes(text)
  let length = list.length(chars)
  let fixed =
    length >= 20
    && string.byte_size(text) == length
    && char_at(chars, 4) == "-"
    && char_at(chars, 7) == "-"
    && char_at(chars, 10) == "T"
    && char_at(chars, 13) == ":"
    && char_at(chars, 16) == ":"
  case
    fixed
    && digits(char_slice(chars, 0, 4))
    && digits(char_slice(chars, 5, 2))
    && digits(char_slice(chars, 8, 2))
    && digits(char_slice(chars, 11, 2))
    && digits(char_slice(chars, 14, 2))
    && digits(char_slice(chars, 17, 2))
  {
    False -> False
    True -> {
      let year = parse_digits(char_slice(chars, 0, 4))
      let month = parse_digits(char_slice(chars, 5, 2))
      let day = parse_digits(char_slice(chars, 8, 2))
      let hour = parse_digits(char_slice(chars, 11, 2))
      let minute = parse_digits(char_slice(chars, 14, 2))
      let second = parse_digits(char_slice(chars, 17, 2))
      timestamp_rest(rule, chars, 19, year, month, day, hour, minute, second)
    }
  }
}

fn timestamp_rest(
  rule: types.CalendarRule,
  chars: List(String),
  position: Int,
  year: Int,
  month: Int,
  day: Int,
  hour: Int,
  minute: Int,
  second: Int,
) -> Bool {
  let after_fraction = case char_at(chars, position) {
    "." -> {
      let fraction = take_digits(chars, position + 1)
      case fraction > position + 1 {
        True -> fraction
        False -> -1
      }
    }
    _ -> position
  }
  case after_fraction < 0 {
    True -> False
    False -> {
      let zone = string.join(list.drop(chars, after_fraction), "")
      let second_limit = case rule.allow_second_60 {
        True -> 60
        False -> 59
      }
      let date_valid =
        year >= rule.minimum_year
        && year <= rule.maximum_year
        && month >= 1
        && month <= 12
        && day >= 1
        && day <= days_in_month(year, month)
        && hour <= 23
        && minute <= 59
        && second <= second_limit
      let outside_utc_range =
        rule.reject_utc_year_outside_range
        && utc_year_outside_range(rule, zone, year, month, day, hour, minute)
      date_valid && zone_valid(zone) && !outside_utc_range
    }
  }
}

fn leap_year(year: Int) -> Bool {
  case year % 4 == 0 {
    False -> False
    True ->
      case year % 100 == 0 {
        False -> True
        True -> year % 400 == 0
      }
  }
}

fn days_in_month(year: Int, month: Int) -> Int {
  case month {
    1 | 3 | 5 | 7 | 8 | 10 | 12 -> 31
    4 | 6 | 9 | 11 -> 30
    2 ->
      case leap_year(year) {
        True -> 29
        False -> 28
      }
    _ -> 0
  }
}

fn zone_valid(zone: String) -> Bool {
  case zone {
    "Z" -> True
    _ ->
      case string.to_graphemes(zone) {
        [sign, h1, h2, ":", m1, m2] -> {
          let sign_valid = sign == "+" || sign == "-"
          let hours = string.concat([h1, h2])
          let minutes = string.concat([m1, m2])
          sign_valid
          && digits(hours)
          && digits(minutes)
          && parse_digits(hours) <= 23
          && parse_digits(minutes) <= 59
          && zone != "-00:00"
        }
        _ -> False
      }
  }
}

fn utc_year_outside_range(
  rule: types.CalendarRule,
  zone: String,
  year: Int,
  month: Int,
  day: Int,
  hour: Int,
  minute: Int,
) -> Bool {
  let offset = case string.to_graphemes(zone) {
    [sign, h1, h2, ":", m1, m2] -> {
      let magnitude =
        parse_digits(string.concat([h1, h2]))
        * 60
        + parse_digits(string.concat([m1, m2]))
      case sign {
        "+" -> magnitude
        "-" -> -magnitude
        _ -> 0
      }
    }
    _ -> 0
  }
  let utc_minute = hour * 60 + minute - offset
  year == rule.minimum_year
  && month == 1
  && day == 1
  && utc_minute < 0
  || year == rule.maximum_year
  && month == 12
  && day == 31
  && utc_minute >= 24 * 60
}

fn language_tag(grandfathered: List(String), text: String) -> Bool {
  let lowered = string.lowercase(text)
  case string.byte_size(text) == string.length(text) && text != "" {
    False -> False
    True ->
      case
        list.any(grandfathered, fn(tag) { string.lowercase(tag) == lowered })
      {
        True -> True
        False -> language_parts(string.split(lowered, "-"))
      }
  }
}

fn language_parts(parts: List(String)) -> Bool {
  case parts {
    ["x", ..private] ->
      private != [] && list.all(private, fn(part) { subtag(part, 1, 8, False) })
    [language, ..rest] ->
      case subtag(language, 2, 8, True) {
        False -> False
        True -> {
          let after_extlangs = case string.length(language) <= 3 {
            True -> take_extlangs(rest, 3)
            False -> rest
          }
          let after_script =
            take_if(after_extlangs, fn(part) {
              string.length(part) == 4 && alpha(part)
            })
          let after_region = consume_one_if(after_script, region_subtag)
          language_extensions(after_region, [], [])
        }
      }
    _ -> False
  }
}

fn take_extlangs(parts: List(String), left: Int) -> List(String) {
  case left, parts {
    0, _ -> parts
    _, [first, ..rest] ->
      case string.length(first) == 3 && alpha(first) {
        True -> take_extlangs(rest, left - 1)
        False -> parts
      }
    _, _ -> parts
  }
}

fn take_if(parts: List(String), predicate: fn(String) -> Bool) -> List(String) {
  case parts {
    [first, ..rest] ->
      case predicate(first) {
        True -> rest
        False -> parts
      }
    [] -> []
  }
}

fn consume_one_if(
  parts: List(String),
  predicate: fn(String) -> Bool,
) -> List(String) {
  take_if(parts, predicate)
}

fn region_subtag(part: String) -> Bool {
  case string.length(part) {
    2 -> alpha(part)
    3 -> digits(part)
    _ -> False
  }
}

fn language_extensions(
  parts: List(String),
  variants: List(String),
  extensions: List(String),
) -> Bool {
  case parts {
    [] -> True
    ["x", ..private] ->
      private != [] && list.all(private, fn(part) { subtag(part, 1, 8, False) })
    [first, ..rest] -> {
      let normalized = string.lowercase(first)
      case normalized == "x" {
        True ->
          rest != [] && list.all(rest, fn(part) { subtag(part, 1, 8, False) })
        False ->
          case variant(first) {
            True ->
              !list.contains(variants, normalized)
              && language_extensions(rest, [normalized, ..variants], extensions)
            False ->
              case string.length(first) == 1 && alphanumeric(first) {
                False -> False
                True -> {
                  let extension_parts = take_extension_subtags(rest)
                  extension_parts != []
                  && !list.contains(extensions, normalized)
                  && language_extensions(
                    list.drop(rest, list.length(extension_parts)),
                    variants,
                    [normalized, ..extensions],
                  )
                }
              }
          }
      }
    }
  }
}

fn take_extension_subtags(parts: List(String)) -> List(String) {
  case parts {
    [first, ..rest] ->
      case
        string.length(first) >= 2
        && string.length(first) <= 8
        && alphanumeric(first)
      {
        True -> [first, ..take_extension_subtags(rest)]
        False -> []
      }
    [] -> []
  }
}

fn variant(text: String) -> Bool {
  let numeric_variant =
    string.length(text) == 4
    && digits(string.slice(from: text, at_index: 0, length: 1))
    && alphanumeric(text)
  subtag(text, 5, 8, False) || numeric_variant
}

fn subtag(text: String, minimum: Int, maximum: Int, alpha_only: Bool) -> Bool {
  case string.length(text) >= minimum && string.length(text) <= maximum {
    False -> False
    True ->
      case alpha_only {
        True -> alpha(text)
        False -> alphanumeric(text)
      }
  }
}

fn alpha(text: String) -> Bool {
  text != ""
  && list.all(string.to_graphemes(text), fn(char) {
    string.contains(
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz",
      char,
    )
  })
}

fn alphanumeric(text: String) -> Bool {
  text != ""
  && list.all(string.to_graphemes(text), fn(char) {
    string.contains(
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
      char,
    )
  })
}

fn digits(text: String) -> Bool {
  text != ""
  && list.all(string.to_graphemes(text), fn(char) {
    string.contains("0123456789", char)
  })
}

fn parse_digits(text: String) -> Int {
  int.parse(text) |> result.unwrap(0)
}

fn list_index(values: List(a), index: Int) -> Option(a) {
  case index < 0 {
    True -> None
    False -> list_index_nonnegative(values, index)
  }
}

fn list_index_nonnegative(values: List(a), index: Int) -> Option(a) {
  case values {
    [] -> None
    [first, ..rest] ->
      case index {
        0 -> Some(first)
        _ -> list_index_nonnegative(rest, index - 1)
      }
  }
}

fn char_at(chars: List(String), index: Int) -> String {
  list_index(chars, index) |> option.unwrap("")
}

fn char_slice(chars: List(String), start: Int, length: Int) -> String {
  string.join(chars |> list.drop(start) |> list.take(length), "")
}

fn take_digits(chars: List(String), start: Int) -> Int {
  take_digits_loop(chars |> list.drop(start), start)
}

fn take_digits_loop(chars: List(String), position: Int) -> Int {
  case chars {
    [first, ..rest] ->
      case string.contains("0123456789", first) {
        True -> take_digits_loop(rest, position + 1)
        False -> position
      }
    [] -> position
  }
}

fn nonempty_profile_ref(reference: types.ProfileRef) -> Bool {
  reference.identity != ""
  && reference.revision != ""
  && reference.content_digest != ""
}

fn unique_nonempty(values: List(String)) -> Bool {
  list.all(values, fn(value) { value != "" })
  && list.length(values) == list.length(list.unique(values))
}

fn declared_range_valid(range: types.IntegerDomain) -> Bool {
  case range {
    types.Unbounded -> True
    types.IntegerInterval(minimum, maximum) -> minimum <= maximum
  }
}

fn declared_format_well_formed(rule: types.FormatRule) -> Bool {
  case rule {
    types.Sequence(rules) | types.Choice(rules) ->
      list.all(rules, declared_format_well_formed)
    types.Optional(inner) | types.Not(inner) ->
      declared_format_well_formed(inner)
    types.Labels(separator, _, _, _, inner) ->
      separator != "" && declared_format_well_formed(inner)
    types.Bounded(_, maximum, inner) ->
      maximum >= 0 && declared_format_well_formed(inner)
    types.Identifier(first, rest, exact, minimum, maximum, forbidden) ->
      first != ""
      && rest != ""
      && string.byte_size(first) == string.length(first)
      && string.byte_size(rest) == string.length(rest)
      && minimum >= 0
      && option.unwrap(
        option.map(maximum, fn(upper) { minimum <= upper }),
        True,
      )
      && list.all(forbidden, fn(value) {
        string.from_utf_codepoints(string.to_utf_codepoints(value)) == value
      })
      && case exact {
        None -> True
        Some(length) ->
          length >= minimum
          && option.unwrap(
            option.map(maximum, fn(upper) { length <= upper }),
            True,
          )
      }
    types.AsciiDfa(spec) ->
      spec.state_count > 0
      && spec.initial_state >= 0
      && spec.initial_state < spec.state_count
      && list.all(spec.accepting_states, fn(state) {
        state >= 0 && state < spec.state_count
      })
    types.Timestamp(rule) ->
      rule.minimum_year >= 0
      && rule.minimum_year <= rule.maximum_year
      && rule.maximum_year <= 9999
    types.Literal(_)
    | types.AbsoluteUri(_)
    | types.LanguageTag(_)
    | types.Text -> True
  }
}

fn profile_failure(
  profile: types.SemanticProfile,
  predicate: types.ProfilePredicate,
  location: List(String),
) -> Result(types.CheckedProfile, types.ProfileFailure) {
  Error(types.ProfileFailure(profile.reference, predicate, location))
}

pub fn check_profile(
  profile: types.SemanticProfile,
) -> Result(types.CheckedProfile, types.ProfileFailure) {
  let integer_names =
    list.map(profile.integer_domains, fn(binding) { binding.name })
  let format_names =
    list.map(profile.format_bindings, fn(binding) { binding.name })
  let wrapper_names = list.map(profile.wrappers, fn(wrapper) { wrapper.name })
  let wrapper_keys = list.map(profile.wrappers, fn(wrapper) { wrapper.key })
  let invalid_reference =
    !nonempty_profile_ref(profile.reference)
    || list.any(profile.integer_domains, fn(binding) {
      !nonempty_profile_ref(binding.reference)
    })
    || list.any(profile.format_bindings, fn(binding) {
      !nonempty_profile_ref(binding.reference)
    })
    || option.unwrap(
      option.map(profile.bytes_policy, fn(policy) {
        !nonempty_profile_ref(policy.reference)
      }),
      False,
    )
    || option.unwrap(
      option.map(profile.grapheme_rules, fn(rules) {
        !nonempty_profile_ref(rules.reference)
      }),
      False,
    )
  let checks = [
    #(invalid_reference, types.Pr01, ["profile"]),
    #(!unique_nonempty(integer_names), types.Pr02, ["integer_domains"]),
    #(
      list.any(profile.integer_domains, fn(binding) {
        !declared_range_valid(binding.range)
      }),
      types.Pr03,
      ["integer_domains"],
    ),
    #(
      list.any(profile.integer_domains, fn(binding) {
        list.is_empty(binding.forms)
      }),
      types.Pr04,
      ["integer_domains"],
    ),
    #(
      !list.contains(integer_names, profile.default_integer_domain),
      types.Pr05,
      ["default_integer_domain"],
    ),
    #(!unique_nonempty(format_names), types.Pr06, ["format_bindings"]),
    #(
      list.any(profile.format_bindings, fn(binding) {
        !declared_format_well_formed(binding.rule)
      }),
      types.Pr07,
      ["format_bindings"],
    ),
    #(
      !unique_nonempty(wrapper_names) || !unique_nonempty(wrapper_keys),
      types.Pr08,
      ["wrappers"],
    ),
    #(
      list.any(profile.wrappers, fn(wrapper) {
        case wrapper.payload {
          types.WrapperText(Some(format)) ->
            !list.contains(format_names, format)
          _ -> False
        }
      }),
      types.Pr09,
      ["wrappers"],
    ),
    #(
      option.unwrap(
        option.map(profile.bytes_policy, fn(policy) {
          case policy.wrapper {
            None -> False
            Some(name) ->
              !list.any(profile.wrappers, fn(wrapper) {
                wrapper.name == name && wrapper.payload == types.WrapperBytes
              })
          }
        }),
        False,
      ),
      types.Pr10,
      ["bytes_policy", "wrapper"],
    ),
  ]
  case list.find(checks, fn(check) { check.0 }) {
    Ok(check) -> profile_failure(profile, check.1, check.2)
    Error(_) -> check_profile_tag(profile, format_names, wrapper_keys)
  }
}

fn check_profile_tag(
  profile: types.SemanticProfile,
  format_names: List(String),
  wrapper_keys: List(String),
) -> Result(types.CheckedProfile, types.ProfileFailure) {
  let tag_checks = case profile.tag {
    None -> []
    Some(tag) -> [
      #(tag.key == "" || list.contains(wrapper_keys, tag.key), types.Pr11, [
        "tag",
        "key",
      ]),
      #(
        option.unwrap(
          option.map(tag.format, fn(name) { !list.contains(format_names, name) }),
          False,
        ),
        types.Pr12,
        ["tag", "format"],
      ),
      #(
        !unique_nonempty(list.map(tag.sealed, fn(form) { form.tag }))
          || option.unwrap(
          option.map(tag.format, fn(name) {
            case
              list.find(profile.format_bindings, fn(binding) {
                binding.name == name
              })
            {
              Error(_) -> True
              Ok(binding) ->
                list.any(tag.sealed, fn(form) {
                  !recognizes(binding.rule, form.tag)
                })
            }
          }),
          False,
        ),
        types.Pr13,
        ["tag", "sealed"],
      ),
      #(
        list.any(tag.sealed, fn(form) {
          let keys = list.map(form.fields, fn(field) { field.key })
          !unique_nonempty(keys)
          || list.contains(keys, tag.key)
          || list.any(keys, fn(key) { list.contains(wrapper_keys, key) })
        }),
        types.Pr14,
        ["tag", "sealed", "fields"],
      ),
      #(
        list.any(tag.sealed, fn(form) {
          list.any(form.fields, fn(field) {
            case field.leaf {
              types.SealedString(spec) ->
                option.unwrap(
                  option.map(spec.wrapper, fn(name) {
                    !list.any(profile.wrappers, fn(wrapper) {
                      wrapper.name == name
                      && case wrapper.payload {
                        types.WrapperText(_) -> True
                        _ -> False
                      }
                    })
                  }),
                  False,
                )
                || option.unwrap(
                  option.map(spec.format, fn(format) {
                    case format {
                      types.NamedFormat(name) ->
                        !list.contains(format_names, name)
                      types.InlineFormat(rule) ->
                        !declared_format_well_formed(rule)
                    }
                  }),
                  False,
                )
                || list.any(spec.lengths, fn(bound) {
                  case bound.minimum, bound.maximum {
                    Some(minimum), Some(maximum) -> minimum > maximum
                    _, _ -> False
                  }
                })
              types.SealedInteger(spec) ->
                option.unwrap(
                  option.map(spec.domain, fn(name) {
                    !list.any(profile.integer_domains, fn(binding) {
                      binding.name == name
                    })
                  }),
                  False,
                )
            }
          })
        }),
        types.Pr15,
        ["tag", "sealed", "fields"],
      ),
    ]
  }
  let invalid_grapheme_ranges =
    option.unwrap(
      option.map(profile.grapheme_rules, fn(rules) {
        list.any(rules.properties, fn(range) { range.last < range.first })
        || list.any(rules.extended_pictographic, fn(range) {
          range.last < range.first
        })
        || list.any(rules.indic_conjunct, fn(range) { range.last < range.first })
      }),
      False,
    )
  case list.find(tag_checks, fn(check) { check.0 }) {
    Ok(check) -> profile_failure(profile, check.1, check.2)
    Error(_) if invalid_grapheme_ranges ->
      profile_failure(profile, types.Pr16, ["grapheme_rules"])
    Error(_) -> Ok(types.checked_profile(profile))
  }
}

fn declared_find_type(
  graph: types.SemanticGraph,
  reference: types.TypeRef,
) -> Option(types.TypeNode) {
  case list.find(graph.nodes, fn(node) { node.reference == reference }) {
    Ok(node) -> Some(node)
    Error(_) -> None
  }
}

fn declared_type_children(shape: types.TypeShape) -> List(types.TypeRef) {
  case shape {
    types.ProductShape(spec) -> {
      let fields = list.map(spec.fields, fn(field) { field.slot.type_ref })
      case spec.extras {
        types.RejectExtras -> fields
        types.AllowExtras(_, value) -> list.append(fields, [value.type_ref])
      }
    }
    types.ArrayShape(spec) -> [spec.item.type_ref]
    types.AliasShape(target, _) -> [target]
    types.TaggedUnionShape(spec) ->
      list.map(spec.branches, fn(branch) { branch.target })
    _ -> []
  }
}

fn declared_integer_binding(
  profile: types.SemanticProfile,
  domain: Option(String),
) -> Option(types.IntegerDomainBinding) {
  let name = option.unwrap(domain, profile.default_integer_domain)
  case
    list.find(profile.integer_domains, fn(binding) { binding.name == name })
  {
    Ok(binding) -> Some(binding)
    Error(_) -> None
  }
}

pub fn node_meaning_obligations(
  graph: types.SemanticGraph,
  reference: types.TypeRef,
) -> List(types.SemanticObligation) {
  let obligation = fn(reason) {
    types.SemanticObligation(reference, [], reason)
  }
  case declared_find_type(graph, reference) {
    None -> [obligation(types.UnresolvedTypeReason)]
    Some(node) ->
      case node.shape {
        types.StringShape(spec) -> {
          let grapheme = case
            list.any(spec.lengths, fn(bound) { bound.unit == types.Graphemes }),
            graph.profile.grapheme_rules
          {
            True, None -> [obligation(types.MissingGraphemeRulesReason)]
            _, _ -> []
          }
          let format = case spec.format {
            Some(types.NamedFormat(name)) ->
              case
                list.any(graph.profile.format_bindings, fn(binding) {
                  binding.name == name
                })
              {
                True -> []
                False -> [obligation(types.UnknownFormatReason(name))]
              }
            _ -> []
          }
          let wrapper = case spec.wrapper {
            None -> []
            Some(name) ->
              case
                list.find(graph.profile.wrappers, fn(item) { item.name == name })
              {
                Error(_) -> [obligation(types.UnknownWrapperReason(name))]
                Ok(item) ->
                  case item.payload {
                    types.WrapperText(_) -> []
                    types.WrapperBytes -> [
                      obligation(types.WrapperPayloadReason(name)),
                    ]
                  }
              }
          }
          list.append(grapheme, list.append(format, wrapper))
        }
        types.IntegerShape(spec) ->
          case declared_integer_binding(graph.profile, spec.domain) {
            None -> [
              obligation(
                types.UnknownIntegerDomainReason(option.unwrap(
                  spec.domain,
                  graph.profile.default_integer_domain,
                )),
              ),
            ]
            Some(binding) ->
              case binding.range {
                types.Unbounded -> []
                types.IntegerInterval(domain_minimum, domain_maximum) ->
                  case
                    option.unwrap(
                      option.map(spec.minimum, fn(value) {
                        value < domain_minimum
                      }),
                      False,
                    )
                    || option.unwrap(
                      option.map(spec.maximum, fn(value) {
                        value > domain_maximum
                      }),
                      False,
                    )
                  {
                    True -> [obligation(types.IntegerBoundReason)]
                    False -> []
                  }
              }
          }
        types.DecimalShape(_) ->
          case graph.profile.numbers.decimals {
            True -> []
            False -> [obligation(types.DecimalNotAdmittedReason)]
          }
        types.BytesShape(_) | types.RawBodyShape(_) ->
          case graph.profile.bytes_policy {
            Some(_) -> []
            None -> [obligation(types.MissingBytesPolicyReason)]
          }
        types.SealedShape(tag, _) ->
          case graph.profile.tag {
            Some(model) ->
              case list.any(model.sealed, fn(form) { form.tag == tag }) {
                True -> []
                False -> [obligation(types.UnknownSealedTagReason(tag))]
              }
            None -> [obligation(types.UnknownSealedTagReason(tag))]
          }
        types.TaggedUnionShape(spec) ->
          case
            list.any(spec.branches, fn(branch) {
              branch.selector == types.InternalTag
            }),
            graph.profile.tag
          {
            True, None -> [obligation(types.MissingTagModelReason)]
            _, _ -> []
          }
        types.OpaqueShape(name) -> [obligation(types.OpaqueTypeReason(name))]
        _ -> []
      }
  }
}

fn declared_reachable_types(
  graph: types.SemanticGraph,
  fuel: Int,
  pending: List(types.TypeRef),
  seen: List(types.TypeRef),
) -> List(types.TypeRef) {
  case fuel <= 0, pending {
    True, _ | _, [] -> seen
    False, [reference, ..rest] ->
      case list.contains(seen, reference) {
        True -> declared_reachable_types(graph, fuel - 1, rest, seen)
        False -> {
          let children = case declared_find_type(graph, reference) {
            Some(node) -> declared_type_children(node.shape)
            None -> []
          }
          declared_reachable_types(
            graph,
            fuel - 1,
            list.append(children, rest),
            [reference, ..seen],
          )
        }
      }
  }
}

pub fn meaning_obligations(
  graph: types.SemanticGraph,
  references: List(types.TypeRef),
) -> List(types.SemanticObligation) {
  let edge_count =
    list.fold(graph.nodes, 0, fn(count, node) {
      count + list.length(declared_type_children(node.shape))
    })
  declared_reachable_types(
    graph,
    list.length(references) + list.length(graph.nodes) + edge_count + 1,
    references,
    [],
  )
  |> list.flat_map(fn(reference) { node_meaning_obligations(graph, reference) })
}

fn meaning_predicate(
  reason: types.SemanticReason,
) -> Option(types.MeaningObligation) {
  case reason {
    types.UnknownFormatReason(_) -> Some(types.Mo01)
    types.MissingGraphemeRulesReason -> Some(types.Mo02)
    types.MissingBytesPolicyReason -> Some(types.Mo03)
    types.UnknownIntegerDomainReason(_) -> Some(types.Mo04)
    types.UnknownWrapperReason(_) -> Some(types.Mo05)
    types.WrapperPayloadReason(_) -> Some(types.Mo06)
    types.UnknownSealedTagReason(_) -> Some(types.Mo07)
    types.DecimalNotAdmittedReason -> Some(types.Mo08)
    types.IntegerBoundReason -> Some(types.Mo09)
    types.OpaqueTypeReason(_) -> Some(types.Mo10)
    types.MissingTagModelReason -> Some(types.Mo11)
    types.UnresolvedTypeReason | types.MembershipBoundReason -> None
  }
}

fn path_location(path: types.ValuePath) -> List(String) {
  list.map(path, fn(step) {
    case step {
      types.Field(name) -> "field:" <> name
      types.Index(index) -> "index:" <> int.to_string(index)
      types.Variant(tag) -> "variant:" <> tag
    }
  })
}

fn first_meaning_failure(
  obligations: List(types.SemanticObligation),
) -> Option(types.MeaningFailure) {
  case obligations {
    [] -> None
    [obligation, ..rest] ->
      case meaning_predicate(obligation.reason) {
        Some(predicate) ->
          Some(types.MeaningFailure(
            obligation.type_ref,
            predicate,
            path_location(obligation.value_path),
          ))
        None -> first_meaning_failure(rest)
      }
  }
}

pub fn check_meaning_defined(
  graph: types.SemanticGraph,
  references: List(types.TypeRef),
) -> Result(Nil, types.MeaningFailure) {
  case first_meaning_failure(meaning_obligations(graph, references)) {
    Some(failure) -> Error(failure)
    None -> Ok(Nil)
  }
}

fn declared_failure(
  reference: types.TypeRef,
  path: types.ValuePath,
  condition: types.ValueCondition,
  observed: kdl.JsonValue,
  trace: List(types.TypeRef),
) -> types.ValueFailure {
  types.ValueFailure(
    reference,
    types.DefinitionRef(reference.source, reference.definition_name),
    types.OccurrenceRef(reference.source, reference.pointer),
    path,
    condition,
    types.Present(observed),
    trace,
  )
}

fn declared_format_accepts(
  profile: types.SemanticProfile,
  format_use: types.FormatUse,
  value: String,
) -> Bool {
  case format_use {
    types.InlineFormat(rule) -> recognizes(rule, value)
    types.NamedFormat(name) ->
      case
        list.find(profile.format_bindings, fn(binding) { binding.name == name })
      {
        Ok(binding) -> recognizes(binding.rule, value)
        Error(_) -> False
      }
  }
}

fn declared_length(
  profile: types.SemanticProfile,
  unit: types.StringLengthUnit,
  value: String,
) -> Option(Int) {
  case unit {
    types.Utf8Bytes -> Some(string.byte_size(value))
    types.UnicodeScalars -> Some(list.length(string.to_utf_codepoints(value)))
    types.Graphemes ->
      option.map(profile.grapheme_rules, fn(rules) {
        grapheme_count(rules, value)
      })
  }
}

fn declared_string_condition(
  profile: types.SemanticProfile,
  spec: types.StringSpec,
  value: String,
) -> Option(types.ValueCondition) {
  let const_invalid =
    option.unwrap(
      option.map(spec.const_value, fn(expected) { expected != value }),
      False,
    )
  let enum_invalid =
    option.unwrap(
      option.map(spec.enum_values, fn(values) { !list.contains(values, value) }),
      False,
    )
  case const_invalid, enum_invalid {
    True, _ -> Some(types.ConstMismatchCondition)
    False, True -> Some(types.EnumMismatchCondition)
    False, False ->
      case
        list.find(spec.lengths, fn(bound) {
          case declared_length(profile, bound.unit, value) {
            None -> True
            Some(length) ->
              option.unwrap(
                option.map(bound.minimum, fn(minimum) { length < minimum }),
                False,
              )
              || option.unwrap(
                option.map(bound.maximum, fn(maximum) { length > maximum }),
                False,
              )
          }
        })
      {
        Ok(_) -> Some(types.StringLengthCondition)
        Error(_) ->
          case spec.format {
            Some(format_use) ->
              case declared_format_accepts(profile, format_use, value) {
                True -> None
                False ->
                  Some(
                    types.FormatFailureCondition(case format_use {
                      types.NamedFormat(name) -> name
                      types.InlineFormat(_) -> "inline"
                    }),
                  )
              }
            None -> None
          }
      }
  }
}

fn declared_decimal_mantissa_and_exponent(
  text: String,
) -> Option(#(String, Int)) {
  let parts = case string.split_once(text, "e") {
    Ok(parts) -> Ok(parts)
    Error(_) -> string.split_once(text, "E")
  }
  case parts {
    Error(_) -> Some(#(text, 0))
    Ok(#(mantissa, exponent)) -> {
      let exponent = case string.starts_with(exponent, "+") {
        True -> string.drop_start(exponent, 1)
        False -> exponent
      }
      option.map(option.from_result(int.parse(exponent)), fn(value) {
        #(mantissa, value)
      })
    }
  }
}

fn declared_shifted_decimal(
  coefficient_text: String,
  fraction_length: Int,
  exponent: Int,
) -> Option(Int) {
  case int.parse(coefficient_text) {
    Error(_) -> None
    Ok(coefficient) -> {
      let decimal_shift = exponent - fraction_length
      case decimal_shift >= 0 {
        True ->
          option.from_result(int.parse(
            coefficient_text <> string.repeat("0", decimal_shift),
          ))
        False -> {
          let trailing = 0 - decimal_shift
          let unsigned = string.remove_prefix(coefficient_text, "-")
          let length = string.length(unsigned)
          case trailing >= length {
            True ->
              case coefficient == 0 {
                True -> Some(0)
                False -> None
              }
            False -> {
              let prefix_length = length - trailing
              let suffix =
                string.slice(
                  from: unsigned,
                  at_index: prefix_length,
                  length: trailing,
                )
              case
                list.all(string.to_graphemes(suffix), fn(digit) { digit == "0" })
              {
                False -> None
                True -> {
                  let prefix =
                    string.slice(
                      from: unsigned,
                      at_index: 0,
                      length: prefix_length,
                    )
                  let signed_prefix = case
                    string.starts_with(coefficient_text, "-")
                  {
                    True -> "-" <> prefix
                    False -> prefix
                  }
                  option.from_result(int.parse(signed_prefix))
                }
              }
            }
          }
        }
      }
    }
  }
}

fn declared_integral_decimal(text: String) -> Option(Int) {
  case declared_decimal_mantissa_and_exponent(text) {
    None -> None
    Some(#(mantissa, exponent)) -> {
      let #(whole, fraction) = case string.split(mantissa, ".") {
        [whole] -> #(whole, "")
        [whole, fraction] -> #(whole, fraction)
        _ -> #("", "")
      }
      declared_shifted_decimal(
        whole <> fraction,
        string.length(fraction),
        exponent,
      )
    }
  }
}

fn declared_drop_leading_zeroes(digits: List(String)) -> List(String) {
  case digits {
    ["0", ..rest] -> declared_drop_leading_zeroes(rest)
    _ -> digits
  }
}

fn declared_count_trailing_zeroes(reversed: List(String), count: Int) -> Int {
  case reversed {
    ["0", ..rest] -> declared_count_trailing_zeroes(rest, count + 1)
    _ -> count
  }
}

fn declared_decimal_is_integral(text: String) -> Bool {
  case declared_decimal_mantissa_and_exponent(text) {
    None -> False
    Some(#(mantissa, exponent)) -> {
      let #(whole, fraction) = case string.split(mantissa, ".") {
        [whole] -> #(whole, "")
        [whole, fraction] -> #(whole, fraction)
        _ -> #("", "")
      }
      let coefficient = whole <> fraction
      let unsigned = string.remove_prefix(coefficient, "-")
      let digits = string.to_graphemes(unsigned)
      case list.all(digits, fn(digit) { digit == "0" }) {
        True -> True
        False -> {
          let decimal_shift = exponent - string.length(fraction)
          case decimal_shift >= 0 {
            True -> True
            False ->
              declared_count_trailing_zeroes(list.reverse(digits), 0)
              >= 0 - decimal_shift
          }
        }
      }
    }
  }
}

fn declared_decimal_exceeds_range(
  text: String,
  range: types.IntegerDomain,
) -> Bool {
  case range {
    types.Unbounded -> False
    types.IntegerInterval(minimum, maximum) ->
      case declared_decimal_mantissa_and_exponent(text) {
        None -> False
        Some(#(mantissa, exponent)) -> {
          let #(whole, fraction) = case string.split(mantissa, ".") {
            [whole] -> #(whole, "")
            [whole, fraction] -> #(whole, fraction)
            _ -> #("", "")
          }
          let coefficient = whole <> fraction
          let unsigned = string.remove_prefix(coefficient, "-")
          let digits =
            declared_drop_leading_zeroes(string.to_graphemes(unsigned))
          case list.is_empty(digits) {
            True -> False
            False -> {
              let decimal_shift = exponent - string.length(fraction)
              let magnitude = fn(value: Int) {
                case value < 0 {
                  True -> 0 - value
                  False -> value
                }
              }
              let maximum_digits =
                int.max(
                  string.length(int.to_string(magnitude(minimum))),
                  string.length(int.to_string(magnitude(maximum))),
                )
              list.length(digits) + decimal_shift > maximum_digits
            }
          }
        }
      }
  }
}

fn declared_integer_value(
  binding: types.IntegerDomainBinding,
  value: kdl.JsonValue,
) -> Option(Int) {
  case value {
    kdl.JsonValueNum(number) ->
      case list.contains(binding.forms, types.Number) {
        True -> Some(number)
        False -> None
      }
    kdl.JsonValueDec(text) ->
      case list.contains(binding.forms, types.IntegralDecimal) {
        False -> None
        True -> declared_integral_decimal(text)
      }
    kdl.JsonValueStr(text) ->
      case list.contains(binding.forms, types.DecimalString) {
        True -> option.from_result(int.parse(text))
        False -> None
      }
    _ -> None
  }
}

fn declared_integer_condition(
  profile: types.SemanticProfile,
  spec: types.IntegerSpec,
  value: kdl.JsonValue,
) -> Option(types.ValueCondition) {
  let domain_name = option.unwrap(spec.domain, profile.default_integer_domain)
  case
    list.find(profile.integer_domains, fn(binding) {
      binding.name == domain_name
    })
  {
    Error(_) -> Some(types.IntegerDomainCondition)
    Ok(binding) ->
      case declared_integer_value(binding, value) {
        None -> Some(types.WrongValueKindCondition("integer"))
        Some(integer) -> {
          let in_domain = case binding.range {
            types.Unbounded -> True
            types.IntegerInterval(minimum, maximum) ->
              integer >= minimum && integer <= maximum
          }
          let const_invalid =
            option.unwrap(
              option.map(spec.const_value, fn(expected) { expected != integer }),
              False,
            )
          let enum_invalid =
            option.unwrap(
              option.map(spec.enum_values, fn(values) {
                !list.contains(values, integer)
              }),
              False,
            )
          case in_domain, const_invalid, enum_invalid {
            False, _, _ -> Some(types.IntegerDomainCondition)
            True, True, _ -> Some(types.ConstMismatchCondition)
            True, False, True -> Some(types.EnumMismatchCondition)
            True, False, False ->
              case spec.minimum, spec.maximum {
                Some(minimum), _ if integer < minimum ->
                  Some(types.BelowMinimumCondition)
                _, Some(maximum) if integer > maximum ->
                  Some(types.AboveMaximumCondition)
                _, _ -> None
              }
          }
        }
      }
  }
}

fn declared_duplicate_key(
  members: List(#(String, kdl.JsonValue)),
) -> Option(String) {
  case members {
    [] -> None
    [member, ..rest] ->
      case list.any(rest, fn(other) { other.0 == member.0 }) {
        True -> Some(member.0)
        False -> declared_duplicate_key(rest)
      }
  }
}

fn declared_value_kind(value: kdl.JsonValue) -> types.ValueKind {
  case value {
    kdl.JsonValueNull -> types.NullKind
    kdl.JsonValueBool(_) -> types.BooleanKind
    kdl.JsonValueNum(_) | kdl.JsonValueDec(_) -> types.NumberKind
    kdl.JsonValueStr(_) -> types.StringKind
    kdl.JsonValueArr(_) -> types.ArrayKind
    kdl.JsonValueObj(_) -> types.ObjectKind
  }
}

fn declared_selector_matches(
  profile: types.SemanticProfile,
  branch: types.UnionBranch,
  value: kdl.JsonValue,
) -> Bool {
  case branch.selector {
    types.InternalTag ->
      case profile.tag, value {
        Some(tag), kdl.JsonValueObj(members) ->
          list.key_find(members, tag.key)
          == Ok(kdl.JsonValueStr(branch.wire_tag))
        _, _ -> False
      }
    types.MemberShape(tests) ->
      case value {
        kdl.JsonValueObj(members) ->
          list.all(tests, fn(member_test) {
            case member_test.1, list.key_find(members, member_test.0) {
              types.AbsentMember, Error(_) -> True
              types.FormatMember(name), Ok(kdl.JsonValueStr(text)) ->
                declared_format_accepts(profile, types.NamedFormat(name), text)
              _, _ -> False
            }
          })
        _ -> False
      }
    types.Kind(kind) -> declared_value_kind(value) == kind
    types.Otherwise -> True
  }
}

fn declared_object_class(
  profile: types.SemanticProfile,
  members: List(#(String, kdl.JsonValue)),
) -> types.ObjectClass {
  let wrapper_or_ordinary = fn() {
    case
      list.find(profile.wrappers, fn(wrapper) {
        result.is_ok(list.key_find(members, wrapper.key))
      })
    {
      Ok(wrapper) -> types.WrapperObject(wrapper)
      Error(_) -> types.OrdinaryObjectClass
    }
  }
  case profile.tag {
    Some(tag) ->
      case list.key_find(members, tag.key) {
        Ok(kdl.JsonValueStr(value)) ->
          case list.find(tag.sealed, fn(form) { form.tag == value }) {
            Ok(form) -> types.SealedObject(form)
            Error(_) -> wrapper_or_ordinary()
          }
        _ -> wrapper_or_ordinary()
      }
    None -> wrapper_or_ordinary()
  }
}

fn declared_eval_object_header(
  profile: types.SemanticProfile,
  reference: types.TypeRef,
  members: List(#(String, kdl.JsonValue)),
  path: types.ValuePath,
  observed: kdl.JsonValue,
  trace: List(types.TypeRef),
) -> Result(Nil, types.ValueFailure) {
  case declared_duplicate_key(members) {
    Some(key) ->
      Error(declared_failure(
        reference,
        path,
        types.DuplicateFieldCondition(key),
        observed,
        trace,
      ))
    None ->
      case profile.tag {
        None -> Ok(Nil)
        Some(tag) ->
          case list.key_find(members, tag.key) {
            Error(_) -> Ok(Nil)
            Ok(member) -> {
              let valid = case member, tag.format {
                kdl.JsonValueStr(_), None -> True
                kdl.JsonValueStr(text), Some(name) ->
                  declared_format_accepts(
                    profile,
                    types.NamedFormat(name),
                    text,
                  )
                _, _ -> False
              }
              case valid {
                True -> Ok(Nil)
                False ->
                  Error(declared_failure(
                    reference,
                    list.append(path, [types.Field(tag.key)]),
                    types.InvalidTagCondition,
                    member,
                    trace,
                  ))
              }
            }
          }
      }
  }
}

fn declared_shape_inspects_object(shape: types.TypeShape) -> Bool {
  case shape {
    types.ProductShape(_)
    | types.TaggedUnionShape(_)
    | types.SealedShape(_, _)
    | types.UnknownShape(_) -> True
    _ -> False
  }
}

fn declared_eval_data_members(
  graph: types.SemanticGraph,
  reference: types.TypeRef,
  members: List(#(String, kdl.JsonValue)),
  path: types.ValuePath,
  trace: List(types.TypeRef),
) -> Result(Nil, types.ValueFailure) {
  use _ <- result.try(
    list.try_map(members, fn(member) {
      declared_eval_data(
        graph,
        reference,
        member.1,
        list.append(path, [types.Field(member.0)]),
        trace,
      )
    }),
  )
  Ok(Nil)
}

fn declared_eval_data(
  graph: types.SemanticGraph,
  reference: types.TypeRef,
  value: kdl.JsonValue,
  path: types.ValuePath,
  trace: List(types.TypeRef),
) -> Result(Nil, types.ValueFailure) {
  case value {
    kdl.JsonValueNum(_) -> {
      let spec = types.IntegerSpec(None, None, None, None, None, None)
      case declared_integer_condition(graph.profile, spec, value) {
        None -> Ok(Nil)
        Some(_) ->
          Error(declared_failure(
            reference,
            path,
            types.IntegerDomainCondition,
            value,
            trace,
          ))
      }
    }
    kdl.JsonValueDec(text) -> {
      case generation_values.is_json_number(text) {
        False ->
          Error(declared_failure(
            reference,
            path,
            types.InvalidDataModelCondition,
            value,
            trace,
          ))
        True ->
          case
            list.find(graph.profile.integer_domains, fn(binding) {
              binding.name == graph.profile.default_integer_domain
            })
          {
            Error(_) ->
              Error(declared_failure(
                reference,
                path,
                types.InvalidDataModelCondition,
                value,
                trace,
              ))
            Ok(binding) -> {
              let integral_decimal =
                list.contains(binding.forms, types.IntegralDecimal)
                && declared_decimal_is_integral(text)
              case integral_decimal {
                False if graph.profile.numbers.decimals -> Ok(Nil)
                False ->
                  Error(declared_failure(
                    reference,
                    path,
                    types.InvalidDataModelCondition,
                    value,
                    trace,
                  ))
                True ->
                  case binding.range {
                    types.Unbounded -> Ok(Nil)
                    _ ->
                      case declared_decimal_exceeds_range(text, binding.range) {
                        True ->
                          Error(declared_failure(
                            reference,
                            path,
                            types.IntegerDomainCondition,
                            value,
                            trace,
                          ))
                        False ->
                          case
                            declared_integer_condition(
                              graph.profile,
                              types.IntegerSpec(
                                None,
                                None,
                                None,
                                None,
                                None,
                                None,
                              ),
                              value,
                            )
                          {
                            None -> Ok(Nil)
                            Some(types.IntegerDomainCondition) ->
                              Error(declared_failure(
                                reference,
                                path,
                                types.IntegerDomainCondition,
                                value,
                                trace,
                              ))
                            Some(_) ->
                              Error(declared_failure(
                                reference,
                                path,
                                types.InvalidDataModelCondition,
                                value,
                                trace,
                              ))
                          }
                      }
                  }
              }
            }
          }
      }
    }
    kdl.JsonValueArr(items) -> {
      use _ <- result.try(
        list.try_map(
          list.index_map(items, fn(item, index) { #(item, index) }),
          fn(item) {
            declared_eval_data(
              graph,
              reference,
              item.0,
              list.append(path, [types.Index(item.1)]),
              trace,
            )
          },
        ),
      )
      Ok(Nil)
    }
    kdl.JsonValueObj(members) -> {
      use _ <- result.try(declared_eval_object_header(
        graph.profile,
        reference,
        members,
        path,
        value,
        trace,
      ))
      case declared_object_class(graph.profile, members) {
        types.WrapperObject(wrapper) ->
          result.map(wrapper_payload_text(graph.profile, wrapper, value), fn(_) {
            Nil
          })
          |> result.map_error(fn(condition) {
            declared_failure(reference, path, condition, value, trace)
          })
        types.SealedObject(form) -> {
          use _ <- result.try(declared_eval_sealed_fields(
            graph,
            reference,
            form,
            [],
            members,
            path,
            trace,
          ))
          let extras =
            list.filter(members, fn(member) {
              !list.any(form.fields, fn(field) { field.key == member.0 })
              && case graph.profile.tag {
                Some(tag) -> member.0 != tag.key
                None -> True
              }
            })
          declared_eval_data_members(graph, reference, extras, path, trace)
        }
        types.OrdinaryObjectClass ->
          declared_eval_data_members(graph, reference, members, path, trace)
      }
    }
    _ -> Ok(Nil)
  }
}

pub fn wrapper_payload_text(
  profile: types.SemanticProfile,
  wrapper: types.Wrapper,
  value: kdl.JsonValue,
) -> Result(String, types.ValueCondition) {
  let text = case value {
    kdl.JsonValueObj([#(key, kdl.JsonValueStr(text))]) if key == wrapper.key ->
      Some(text)
    _ -> None
  }
  let failure = case wrapper.payload {
    types.WrapperBytes -> types.InvalidBytesCondition
    types.WrapperText(None) -> types.WrongValueKindCondition("wrapper text")
    types.WrapperText(Some(name)) -> types.FormatFailureCondition(name)
  }
  case text {
    None -> Error(failure)
    Some(text) -> {
      let accepted = case wrapper.payload {
        types.WrapperBytes ->
          case profile.bytes_policy {
            None -> False
            Some(policy) ->
              result.is_ok(base64.decode(
                text,
                policy.padding_optional,
                policy.alphabet,
                policy.strict_pad_bits,
              ))
          }
        types.WrapperText(None) -> True
        types.WrapperText(Some(name)) ->
          declared_format_accepts(profile, types.NamedFormat(name), text)
      }
      case accepted {
        True -> Ok(text)
        False -> Error(failure)
      }
    }
  }
}

pub fn object_class(
  profile: types.SemanticProfile,
  value: kdl.JsonValue,
) -> types.ObjectClass {
  case value {
    kdl.JsonValueObj(members) -> declared_object_class(profile, members)
    _ -> types.OrdinaryObjectClass
  }
}

fn declared_eval_string(
  graph: types.SemanticGraph,
  reference: types.TypeRef,
  spec: types.StringSpec,
  value: kdl.JsonValue,
  path: types.ValuePath,
  trace: List(types.TypeRef),
) -> Result(Nil, types.ValueFailure) {
  let text = case spec.wrapper, value {
    None, kdl.JsonValueStr(text) -> Ok(text)
    None, _ -> Error(types.WrongValueKindCondition("string"))
    Some(name), _ ->
      case object_class(graph.profile, value) {
        types.WrapperObject(wrapper) if wrapper.name == name ->
          wrapper_payload_text(graph.profile, wrapper, value)
        _ -> Error(types.WrongValueKindCondition("string wrapper"))
      }
  }
  use text <- result.try(
    result.map_error(text, fn(condition) {
      declared_failure(reference, path, condition, value, trace)
    }),
  )
  case declared_string_condition(graph.profile, spec, text) {
    None -> Ok(Nil)
    Some(condition) ->
      Error(declared_failure(reference, path, condition, value, trace))
  }
}

fn declared_eval_leaf(
  graph: types.SemanticGraph,
  reference: types.TypeRef,
  leaf: types.SealedLeaf,
  value: kdl.JsonValue,
  path: types.ValuePath,
  trace: List(types.TypeRef),
) -> Result(Nil, types.ValueFailure) {
  let condition = case leaf, value {
    types.SealedString(spec), _ -> {
      let text = case value {
        kdl.JsonValueStr(text) -> Ok(text)
        _ ->
          case object_class(graph.profile, value) {
            types.WrapperObject(wrapper) ->
              wrapper_payload_text(graph.profile, wrapper, value)
            _ -> Error(types.WrongValueKindCondition("string"))
          }
      }
      case text {
        Error(condition) -> Some(condition)
        Ok(text) -> declared_string_condition(graph.profile, spec, text)
      }
    }
    types.SealedInteger(spec), kdl.JsonValueNum(_) ->
      declared_integer_condition(graph.profile, spec, value)
    types.SealedInteger(_), _ -> Some(types.WrongValueKindCondition("integer"))
  }
  case condition {
    None -> Ok(Nil)
    Some(condition) ->
      Error(declared_failure(reference, path, condition, value, trace))
  }
}

fn declared_eval_sealed_fields(
  graph: types.SemanticGraph,
  reference: types.TypeRef,
  form: types.SealedForm,
  refinements: List(types.SealedRefinement),
  members: List(#(String, kdl.JsonValue)),
  path: types.ValuePath,
  trace: List(types.TypeRef),
) -> Result(Nil, types.ValueFailure) {
  use _ <- result.try(
    list.try_map(form.fields, fn(field) {
      let field_path = list.append(path, [types.Field(field.key)])
      case list.key_find(members, field.key) {
        Error(_) ->
          case field.required {
            True ->
              Error(types.ValueFailure(
                reference,
                types.DefinitionRef(reference.source, reference.definition_name),
                types.OccurrenceRef(reference.source, reference.pointer),
                field_path,
                types.MissingRequiredCondition,
                types.Absent,
                trace,
              ))
            False -> Ok(Nil)
          }
        Ok(value) -> {
          let leaf = case
            list.find(refinements, fn(item) { item.key == field.key })
          {
            Ok(refinement) -> refinement.leaf
            Error(_) -> field.leaf
          }
          declared_eval_leaf(graph, reference, leaf, value, field_path, trace)
        }
      }
    }),
  )
  let known =
    list.append(
      [
        case graph.profile.tag {
          Some(tag) -> tag.key
          None -> ""
        },
      ],
      list.map(form.fields, fn(field) { field.key }),
    )
  case form.extras {
    types.SealedAny -> Ok(Nil)
    types.SealedReject ->
      case list.find(members, fn(member) { !list.contains(known, member.0) }) {
        Ok(member) ->
          Error(declared_failure(
            reference,
            list.append(path, [types.Field(member.0)]),
            types.UnexpectedFieldCondition(member.0),
            member.1,
            trace,
          ))
        Error(_) -> Ok(Nil)
      }
  }
}

fn declared_json_size(value: kdl.JsonValue) -> Int {
  case value {
    kdl.JsonValueArr(items) ->
      1
      + list.fold(items, 0, fn(size, child) { size + declared_json_size(child) })
    kdl.JsonValueObj(members) ->
      1
      + list.fold(members, 0, fn(size, member) {
        size + declared_json_size(member.1)
      })
    _ -> 1
  }
}

fn declared_eval_element(
  graph: types.SemanticGraph,
  contract: types.ElementContract,
  value: kdl.JsonValue,
  path: types.ValuePath,
  evaluation_path: types.ValuePath,
  fuel: Int,
  active: List(#(types.TypeRef, types.ValuePath)),
) -> Result(Nil, types.ValueFailure) {
  case value, contract.nullable {
    kdl.JsonValueNull, True -> Ok(Nil)
    _, _ ->
      declared_eval(
        graph,
        contract.type_ref,
        value,
        path,
        evaluation_path,
        fuel,
        active,
      )
  }
}

fn declared_eval_product(
  graph: types.SemanticGraph,
  reference: types.TypeRef,
  spec: types.ProductSpec,
  members: List(#(String, kdl.JsonValue)),
  path: types.ValuePath,
  evaluation_path: types.ValuePath,
  trace: List(types.TypeRef),
  fuel: Int,
  active: List(#(types.TypeRef, types.ValuePath)),
) -> Result(Nil, types.ValueFailure) {
  use _ <- result.try(
    list.try_map(spec.fields, fn(field) {
      let field_path = list.append(path, [types.Field(field.wire_name)])
      case list.key_find(members, field.wire_name) {
        Error(_) ->
          case field.slot.required {
            True ->
              Error(types.ValueFailure(
                field.slot.type_ref,
                types.DefinitionRef(
                  field.slot.type_ref.source,
                  field.slot.type_ref.definition_name,
                ),
                field.origin,
                field_path,
                types.MissingRequiredCondition,
                types.Absent,
                trace,
              ))
            False -> Ok(Nil)
          }
        Ok(kdl.JsonValueNull) ->
          case field.slot.nullable {
            True -> Ok(Nil)
            False ->
              Error(declared_failure(
                field.slot.type_ref,
                field_path,
                types.NullNotAllowedCondition,
                kdl.JsonValueNull,
                trace,
              ))
          }
        Ok(value) ->
          declared_eval(
            graph,
            field.slot.type_ref,
            value,
            field_path,
            list.append(evaluation_path, [types.Field(field.wire_name)]),
            fuel,
            active,
          )
      }
    }),
  )
  let extras =
    list.filter(members, fn(member) {
      !list.any(spec.fields, fn(field) { field.wire_name == member.0 })
      && case graph.profile.tag {
        Some(tag) -> member.0 != tag.key
        None -> True
      }
    })
  case spec.extras {
    types.RejectExtras ->
      case extras {
        [extra, ..] ->
          Error(declared_failure(
            reference,
            list.append(path, [types.Field(extra.0)]),
            types.UnexpectedFieldCondition(extra.0),
            extra.1,
            trace,
          ))
        [] -> Ok(Nil)
      }
    types.AllowExtras(key_format, contract) -> {
      use _ <- result.try(
        list.try_map(extras, fn(extra) {
          use _ <- result.try(case key_format {
            Some(format_use) ->
              case declared_format_accepts(graph.profile, format_use, extra.0) {
                True -> Ok(Nil)
                False ->
                  Error(declared_failure(
                    reference,
                    list.append(path, [types.Field(extra.0)]),
                    types.KeyFormatCondition(case format_use {
                      types.NamedFormat(name) -> name
                      types.InlineFormat(_) -> "inline"
                    }),
                    extra.1,
                    trace,
                  ))
              }
            None -> Ok(Nil)
          })
          declared_eval_element(
            graph,
            contract,
            extra.1,
            list.append(path, [types.Field(extra.0)]),
            list.append(evaluation_path, [types.Field(extra.0)]),
            fuel,
            active,
          )
        }),
      )
      Ok(Nil)
    }
  }
}

fn declared_eval_bytes(
  graph: types.SemanticGraph,
  reference: types.TypeRef,
  spec: types.LengthSpec,
  value: kdl.JsonValue,
  path: types.ValuePath,
  trace: List(types.TypeRef),
) -> Result(Nil, types.ValueFailure) {
  let encoded = case graph.profile.bytes_policy {
    Some(policy) ->
      case policy.wrapper, value {
        None, kdl.JsonValueStr(text) -> Some(text)
        Some(name), _ ->
          case
            list.find(graph.profile.wrappers, fn(wrapper) {
              wrapper.name == name
            })
          {
            Ok(wrapper) ->
              option.from_result(wrapper_payload_text(
                graph.profile,
                wrapper,
                value,
              ))
            Error(_) -> None
          }
        _, _ -> None
      }
    None -> None
  }
  case graph.profile.bytes_policy, encoded {
    Some(policy), Some(text) ->
      case
        base64.decode(
          text,
          policy.padding_optional,
          policy.alphabet,
          policy.strict_pad_bits,
        )
      {
        Error(_) ->
          Error(declared_failure(
            reference,
            path,
            types.InvalidBytesCondition,
            value,
            trace,
          ))
        Ok(bytes) -> {
          let length = list.length(bytes)
          case
            option.unwrap(
              option.map(spec.minimum, fn(minimum) { length < minimum }),
              False,
            ),
            option.unwrap(
              option.map(spec.maximum, fn(maximum) { length > maximum }),
              False,
            )
          {
            True, _ | _, True ->
              Error(declared_failure(
                reference,
                path,
                types.BytesLengthCondition,
                value,
                trace,
              ))
            False, False -> Ok(Nil)
          }
        }
      }
    _, _ ->
      Error(declared_failure(
        reference,
        path,
        types.InvalidBytesCondition,
        value,
        trace,
      ))
  }
}

fn declared_eval(
  graph: types.SemanticGraph,
  reference: types.TypeRef,
  value: kdl.JsonValue,
  path: types.ValuePath,
  evaluation_path: types.ValuePath,
  fuel: Int,
  active: List(#(types.TypeRef, types.ValuePath)),
) -> Result(Nil, types.ValueFailure) {
  let trace = list.map(list.reverse(active), fn(identity) { identity.0 })
  case fuel <= 0 || list.contains(active, #(reference, evaluation_path)) {
    True ->
      Error(declared_failure(
        reference,
        path,
        types.ReferenceCycleCondition,
        value,
        trace,
      ))
    False ->
      case declared_find_type(graph, reference) {
        None ->
          Error(declared_failure(
            reference,
            path,
            types.InvalidDataModelCondition,
            value,
            trace,
          ))
        Some(node) -> {
          use _ <- result.try(case value {
            kdl.JsonValueObj(members) ->
              case declared_shape_inspects_object(node.shape) {
                True ->
                  declared_eval_object_header(
                    graph.profile,
                    reference,
                    members,
                    path,
                    value,
                    trace,
                  )
                False -> Ok(Nil)
              }
            _ -> Ok(Nil)
          })
          case node.shape {
            types.BooleanShape(spec) ->
              case value {
                kdl.JsonValueBool(actual) ->
                  case spec.const_value {
                    Some(expected) if expected != actual ->
                      Error(declared_failure(
                        reference,
                        path,
                        types.ConstMismatchCondition,
                        value,
                        trace,
                      ))
                    _ -> Ok(Nil)
                  }
                _ ->
                  Error(declared_failure(
                    reference,
                    path,
                    types.WrongValueKindCondition("boolean"),
                    value,
                    trace,
                  ))
              }
            types.IntegerShape(spec) ->
              case declared_integer_condition(graph.profile, spec, value) {
                None -> Ok(Nil)
                Some(condition) ->
                  Error(declared_failure(
                    reference,
                    path,
                    condition,
                    value,
                    trace,
                  ))
              }
            types.DecimalShape(_) ->
              case value {
                kdl.JsonValueDec(_) -> Ok(Nil)
                _ ->
                  Error(declared_failure(
                    reference,
                    path,
                    types.WrongValueKindCondition("decimal"),
                    value,
                    trace,
                  ))
              }
            types.StringShape(spec) ->
              declared_eval_string(graph, reference, spec, value, path, trace)
            types.BytesShape(spec) ->
              declared_eval_bytes(graph, reference, spec, value, path, trace)
            types.ProductShape(spec) ->
              case value {
                kdl.JsonValueObj(members) ->
                  declared_eval_product(
                    graph,
                    reference,
                    spec,
                    members,
                    path,
                    evaluation_path,
                    trace,
                    fuel - 1,
                    [#(reference, evaluation_path), ..active],
                  )
                _ ->
                  Error(declared_failure(
                    reference,
                    path,
                    types.WrongValueKindCondition("object"),
                    value,
                    trace,
                  ))
              }
            types.ArrayShape(spec) ->
              case value {
                kdl.JsonValueArr(items) -> {
                  let length = list.length(items)
                  let invalid_length =
                    option.unwrap(
                      option.map(spec.min_length, fn(minimum) {
                        length < minimum
                      }),
                      False,
                    )
                    || option.unwrap(
                      option.map(spec.max_length, fn(maximum) {
                        length > maximum
                      }),
                      False,
                    )
                  case invalid_length {
                    True ->
                      Error(declared_failure(
                        reference,
                        path,
                        types.ArrayLengthCondition,
                        value,
                        trace,
                      ))
                    False -> {
                      use _ <- result.try(
                        list.try_map(
                          list.index_map(items, fn(item, index) {
                            #(item, index)
                          }),
                          fn(item) {
                            declared_eval_element(
                              graph,
                              spec.item,
                              item.0,
                              list.append(path, [types.Index(item.1)]),
                              list.append(evaluation_path, [types.Index(item.1)]),
                              fuel - 1,
                              [#(reference, evaluation_path), ..active],
                            )
                          },
                        ),
                      )
                      Ok(Nil)
                    }
                  }
                }
                _ ->
                  Error(declared_failure(
                    reference,
                    path,
                    types.WrongValueKindCondition("array"),
                    value,
                    trace,
                  ))
              }
            types.AliasShape(target, _) ->
              declared_eval(
                graph,
                target,
                value,
                path,
                evaluation_path,
                fuel - 1,
                [#(reference, evaluation_path), ..active],
              )
            types.TaggedUnionShape(spec) ->
              case
                list.find(spec.branches, fn(branch) {
                  declared_selector_matches(graph.profile, branch, value)
                })
              {
                Error(_) ->
                  Error(declared_failure(
                    reference,
                    path,
                    types.NoBranchSelectedCondition,
                    value,
                    trace,
                  ))
                Ok(branch) ->
                  declared_eval(
                    graph,
                    branch.target,
                    value,
                    path,
                    evaluation_path,
                    fuel - 1,
                    [#(reference, evaluation_path), ..active],
                  )
              }
            types.SealedShape(tag_value, refinements) ->
              case value, graph.profile.tag {
                kdl.JsonValueObj(members), Some(tag) ->
                  case
                    list.key_find(members, tag.key),
                    list.find(tag.sealed, fn(form) { form.tag == tag_value })
                  {
                    Ok(kdl.JsonValueStr(actual)), Ok(form)
                      if actual == tag_value
                    ->
                      declared_eval_sealed_fields(
                        graph,
                        reference,
                        form,
                        refinements,
                        members,
                        path,
                        trace,
                      )
                    _, _ ->
                      Error(declared_failure(
                        reference,
                        path,
                        types.WrongValueKindCondition("sealed object"),
                        value,
                        trace,
                      ))
                  }
                _, _ ->
                  Error(declared_failure(
                    reference,
                    path,
                    types.WrongValueKindCondition("sealed object"),
                    value,
                    trace,
                  ))
              }
            types.Never ->
              Error(declared_failure(
                reference,
                path,
                types.InvalidDataModelCondition,
                value,
                trace,
              ))
            types.UnknownShape(types.AnyValue) ->
              declared_eval_data(graph, reference, value, path, trace)
            types.UnknownShape(types.OrdinaryObject) ->
              case value {
                kdl.JsonValueObj(members) ->
                  case declared_object_class(graph.profile, members) {
                    types.OrdinaryObjectClass ->
                      declared_eval_data(graph, reference, value, path, trace)
                    _ ->
                      Error(declared_failure(
                        reference,
                        path,
                        types.WrongValueKindCondition("ordinary object"),
                        value,
                        trace,
                      ))
                  }
                _ ->
                  Error(declared_failure(
                    reference,
                    path,
                    types.WrongValueKindCondition("ordinary object"),
                    value,
                    trace,
                  ))
              }
            types.UnitShape ->
              case value {
                kdl.JsonValueNull -> Ok(Nil)
                _ ->
                  Error(declared_failure(
                    reference,
                    path,
                    types.WrongValueKindCondition("unit"),
                    value,
                    trace,
                  ))
              }
            types.RawBodyShape(_) ->
              declared_eval_bytes(
                graph,
                reference,
                types.LengthSpec(None, None),
                value,
                path,
                trace,
              )
            types.OpaqueShape(_) ->
              Error(declared_failure(
                reference,
                path,
                types.InvalidDataModelCondition,
                value,
                trace,
              ))
          }
        }
      }
  }
}

pub fn declared_value_decision(
  graph: types.SemanticGraph,
  reference: types.TypeRef,
  value: kdl.JsonValue,
) -> types.ValueDecision {
  let obligations = meaning_obligations(graph, [reference])
  case obligations {
    [_, ..] -> types.UnresolvedValue(obligations)
    [] ->
      case
        declared_eval(
          graph,
          reference,
          value,
          [],
          [],
          { declared_json_size(value) + 1 } * { list.length(graph.nodes) + 1 },
          [],
        )
      {
        Ok(_) -> types.AcceptedValue
        Error(failure) -> types.RejectedValue(failure)
      }
  }
}

fn find_type(
  graph: types.SemanticGraph,
  reference: types.TypeRef,
) -> Option(types.TypeNode) {
  case list.find(graph.nodes, fn(node) { node.reference == reference }) {
    Ok(node) -> Some(node)
    Error(_) -> None
  }
}

pub fn accepts_value(
  graph: types.SemanticGraph,
  reference: types.TypeRef,
  value: kdl.JsonValue,
) -> Bool {
  declared_value_decision(graph, reference, value) == types.AcceptedValue
}

pub fn element_allows_null(
  graph: types.SemanticGraph,
  contract: types.ElementContract,
) -> Bool {
  contract.nullable
  || accepts_value(graph, contract.type_ref, kdl.JsonValueNull)
}

pub fn accepts_slot(
  graph: types.SemanticGraph,
  contract: types.SlotContract,
  value: types.SlotValue(kdl.JsonValue),
) -> Bool {
  result.is_ok(validate_slot(graph, contract, value))
}

pub fn validate_value(
  graph: types.SemanticGraph,
  reference: types.TypeRef,
  value: kdl.JsonValue,
) -> Result(ValidatedValue, ValidationFailure) {
  case declared_value_decision(graph, reference, value) {
    types.AcceptedValue ->
      Ok(ValidatedValue(graph, reference, value, MemberProof([])))
    types.RejectedValue(failure) -> Error(Rejected(failure))
    types.UnresolvedValue(obligations) -> Error(Unresolved(obligations))
    types.CertificateMismatchValue(condition) ->
      Error(CertificateMismatchFailure(condition))
  }
}

pub fn validate_slot(
  graph: types.SemanticGraph,
  contract: types.SlotContract,
  value: types.SlotValue(kdl.JsonValue),
) -> Result(ValidatedSlot, ValidationFailure) {
  case value {
    types.Absent if !contract.required ->
      Ok(ValidatedSlot(graph, contract, value, None))
    types.Null if contract.nullable ->
      Ok(ValidatedSlot(graph, contract, value, None))
    types.Present(actual) ->
      result.map(validate_value(graph, contract.type_ref, actual), fn(checked) {
        ValidatedSlot(graph, contract, value, Some(checked.proof))
      })
    types.Absent ->
      Error(
        Rejected(
          types.ValueFailure(
            contract.type_ref,
            types.DefinitionRef(
              contract.type_ref.source,
              contract.type_ref.definition_name,
            ),
            types.occurrence(contract.type_ref),
            [],
            types.MissingRequiredCondition,
            types.Absent,
            [contract.type_ref],
          ),
        ),
      )
    types.Null ->
      Error(
        Rejected(
          types.ValueFailure(
            contract.type_ref,
            types.DefinitionRef(
              contract.type_ref.source,
              contract.type_ref.definition_name,
            ),
            types.occurrence(contract.type_ref),
            [],
            types.NullNotAllowedCondition,
            types.Null,
            [contract.type_ref],
          ),
        ),
      )
  }
}

pub fn value_at_path(
  tag: Option(types.TagModel),
  value: kdl.JsonValue,
  path: types.ValuePath,
) -> types.SlotValue(kdl.JsonValue) {
  case path {
    [] -> types.Present(value)
    [step, ..rest] ->
      case step, value {
        _, kdl.JsonValueNull -> types.Null
        types.Field(name), kdl.JsonValueObj(members) ->
          case list.key_find(members, name) {
            Error(_) -> types.Absent
            Ok(kdl.JsonValueNull) -> types.Null
            Ok(found) -> value_at_path(tag, found, rest)
          }
        types.Index(index), kdl.JsonValueArr(items) ->
          case list_index_nonnegative(items, index) {
            None -> types.Absent
            Some(kdl.JsonValueNull) -> types.Null
            Some(found) -> value_at_path(tag, found, rest)
          }
        types.Variant(expected), kdl.JsonValueObj(members) ->
          case tag {
            Some(model) ->
              case list.key_find(members, model.key) {
                Ok(kdl.JsonValueStr(actual)) if actual == expected ->
                  value_at_path(tag, value, rest)
                _ -> types.Absent
              }
            None -> types.Absent
          }
        _, _ -> types.Absent
      }
  }
}

fn strengthened(
  slot: types.SlotContract,
  path: types.ValuePath,
  assumptions: List(ProjectionAssumption),
) -> types.SlotContract {
  let present =
    list.any(assumptions, fn(assumption) {
      case assumption {
        Present(at) | Variant(at, _) | IndexPresent(at, _) -> at == path
        _ -> False
      }
    })
  let nonnull =
    list.any(assumptions, fn(assumption) {
      case assumption {
        NonNull(at) -> at == path
        _ -> False
      }
    })
  types.SlotContract(
    slot.type_ref,
    slot.required || present,
    slot.nullable && !present && !nonnull,
  )
}

pub fn project_slot(
  graph: types.SemanticGraph,
  source: types.SlotContract,
  path: types.ValuePath,
  assumptions: List(ProjectionAssumption),
) -> Result(ProjectionCertificate, ProjectionFailure) {
  let obligations = meaning_obligations(graph, [source.type_ref])
  case obligations {
    [_, ..] -> Error(ProjectionUnresolved(obligations))
    [] -> project_steps(graph, source, source, path, assumptions, 0, [])
  }
}

fn project_steps(
  graph: types.SemanticGraph,
  source: types.SlotContract,
  slot: types.SlotContract,
  path: types.ValuePath,
  assumptions: List(ProjectionAssumption),
  position: Int,
  seen: List(#(types.TypeRef, Int)),
) -> Result(ProjectionCertificate, ProjectionFailure) {
  let traversed = list.take(path, position)
  let slot = strengthened(slot, traversed, assumptions)
  case list_index_nonnegative(path, position) {
    None ->
      Ok(ProjectionCertificate(
        graph.profile.reference,
        graph.source_refs,
        source,
        path,
        assumptions,
        slot,
      ))
    Some(step) ->
      case list.contains(seen, #(slot.type_ref, position)) {
        True -> Error(WrongShape(slot.type_ref, traversed))
        False ->
          case find_type(graph, slot.type_ref) {
            None ->
              Error(
                ProjectionUnresolved([
                  types.SemanticObligation(
                    slot.type_ref,
                    traversed,
                    types.UnresolvedTypeReason,
                  ),
                ]),
              )
            Some(node) -> {
              let next = [#(slot.type_ref, position), ..seen]
              case node.shape, step {
                types.AliasShape(target, _), _ ->
                  project_steps(
                    graph,
                    source,
                    types.SlotContract(target, slot.required, slot.nullable),
                    path,
                    assumptions,
                    position,
                    next,
                  )
                types.ProductShape(spec), types.Field(name) ->
                  case
                    list.find(spec.fields, fn(field) { field.wire_name == name })
                  {
                    Error(_) -> Error(MissingField(slot.type_ref, name))
                    Ok(field) ->
                      project_steps(
                        graph,
                        source,
                        types.SlotContract(
                          field.slot.type_ref,
                          slot.required && field.slot.required,
                          slot.nullable || field.slot.nullable,
                        ),
                        path,
                        assumptions,
                        position + 1,
                        next,
                      )
                  }
                types.ArrayShape(spec), types.Index(index) -> {
                  let guaranteed =
                    option.unwrap(
                      option.map(spec.min_length, fn(minimum) {
                        index < minimum
                      }),
                      False,
                    )
                    || list.contains(
                      assumptions,
                      IndexPresent(traversed, index),
                    )
                  project_steps(
                    graph,
                    source,
                    types.SlotContract(
                      spec.item.type_ref,
                      slot.required && guaranteed,
                      slot.nullable || element_allows_null(graph, spec.item),
                    ),
                    path,
                    assumptions,
                    position + 1,
                    next,
                  )
                }
                types.TaggedUnionShape(spec), types.Variant(tag) ->
                  case
                    list.find(spec.branches, fn(branch) {
                      branch.wire_tag == tag
                    })
                  {
                    Error(_) -> Error(MissingVariant(slot.type_ref, tag))
                    Ok(branch) ->
                      case list.contains(assumptions, Variant(traversed, tag)) {
                        True ->
                          project_steps(
                            graph,
                            source,
                            types.SlotContract(
                              branch.target,
                              slot.required,
                              slot.nullable,
                            ),
                            path,
                            assumptions,
                            position + 1,
                            next,
                          )
                        False -> Error(BranchAssumptionRequired(traversed, tag))
                      }
                  }
                _, _ -> Error(WrongShape(slot.type_ref, traversed))
              }
            }
          }
      }
  }
}

pub fn check_projection_certificate(
  graph: types.SemanticGraph,
  certificate: ProjectionCertificate,
) -> Result(Nil, ProjectionFailure) {
  case
    certificate.profile != graph.profile.reference
    || certificate.source_refs != graph.source_refs
  {
    True -> Error(CertificateMismatch("profile/source revision"))
    False -> {
      case
        project_slot(
          graph,
          certificate.source,
          certificate.path,
          certificate.assumptions,
        )
      {
        Ok(computed) if computed == certificate -> Ok(Nil)
        Ok(_) -> Error(CertificateMismatch("projection contract"))
        Error(failure) -> Error(failure)
      }
    }
  }
}

pub fn assumption_holds(
  tag: Option(types.TagModel),
  value: kdl.JsonValue,
  assumption: ProjectionAssumption,
) -> Bool {
  case assumption {
    Present(path) ->
      case value_at_path(tag, value, path) {
        types.Present(kdl.JsonValueNull) | types.Absent | types.Null -> False
        _ -> True
      }
    NonNull(path) ->
      case value_at_path(tag, value, path) {
        types.Null | types.Present(kdl.JsonValueNull) -> False
        _ -> True
      }
    Variant(path, expected) ->
      case value_at_path(tag, value, path), tag {
        types.Present(kdl.JsonValueObj(members)), Some(model) ->
          list.key_find(members, model.key) == Ok(kdl.JsonValueStr(expected))
        _, _ -> False
      }
    IndexPresent(path, index) ->
      case value_at_path(tag, value, path) {
        types.Present(kdl.JsonValueArr(items)) ->
          index >= 0 && index < list.length(items)
        _ -> False
      }
  }
}

pub fn project_value(
  graph: types.SemanticGraph,
  certificate: ProjectionCertificate,
  source: types.SlotValue(kdl.JsonValue),
) -> Result(ValidatedSlot, ProjectionValueFailure) {
  use _ <- result.try(
    check_projection_certificate(graph, certificate)
    |> result.map_error(Projection),
  )
  use _ <- result.try(
    validate_slot(graph, certificate.source, source)
    |> result.map_error(Validation),
  )
  let holds = case source {
    types.Present(value) ->
      list.all(certificate.assumptions, fn(a) {
        assumption_holds(graph.profile.tag, value, a)
      })
    _ -> certificate.assumptions == []
  }
  use _ <- result.try(case holds {
    True -> Ok(Nil)
    False -> Error(UnsatisfiedGuard)
  })
  let projected = case source {
    types.Present(value) ->
      value_at_path(graph.profile.tag, value, certificate.path)
    other -> other
  }
  validate_slot(graph, certificate.destination, projected)
  |> result.map_error(Validation)
}

type DefaultDraft {
  DefaultDraft(value: kdl.JsonValue, applications: List(DefaultApplication))
}

fn declared_default(
  graph: types.SemanticGraph,
  reference: types.TypeRef,
  fuel: Int,
) -> Option(#(types.TypeRef, kdl.JsonValue)) {
  case fuel <= 0 {
    True -> None
    False ->
      case find_type(graph, reference) {
        None -> None
        Some(node) ->
          case node.shape {
            types.AliasShape(target, _) ->
              declared_default(graph, target, fuel - 1)
            shape ->
              option.map(type_default(shape), fn(value) { #(reference, value) })
          }
      }
  }
}

fn default_draft(
  graph: types.SemanticGraph,
  reference: types.TypeRef,
  path: types.ValuePath,
  value: kdl.JsonValue,
  fuel: Int,
) -> Result(DefaultDraft, ValidationFailure) {
  use _ <- result.try(case fuel <= 0 {
    True ->
      Error(
        Unresolved([
          types.SemanticObligation(reference, path, types.MembershipBoundReason),
        ]),
      )
    False -> Ok(Nil)
  })
  use node <- result.try(case find_type(graph, reference) {
    None ->
      Error(
        Unresolved([
          types.SemanticObligation(reference, path, types.UnresolvedTypeReason),
        ]),
      )
    Some(node) -> Ok(node)
  })
  case node.shape, value {
    types.AliasShape(target, _), _ ->
      default_draft(graph, target, path, value, fuel - 1)
    types.TaggedUnionShape(spec), kdl.JsonValueObj(members) -> {
      let key =
        option.unwrap(
          option.map(graph.profile.tag, fn(model) { model.key }),
          "",
        )
      case list.key_find(members, key) {
        Ok(kdl.JsonValueStr(tag)) ->
          case list.find(spec.branches, fn(branch) { branch.wire_tag == tag }) {
            Ok(branch) ->
              default_draft(graph, branch.target, path, value, fuel - 1)
            Error(_) -> Ok(DefaultDraft(value, []))
          }
        _ -> Ok(DefaultDraft(value, []))
      }
    }
    types.ArrayShape(spec), kdl.JsonValueArr(items) -> {
      use output <- result.try(
        list.try_fold(
          list.index_map(items, fn(item, index) { #(item, index) }),
          #([], []),
          fn(output, item) {
            use child <- result.try(default_draft(
              graph,
              spec.item.type_ref,
              list.append(path, [types.Index(item.1)]),
              item.0,
              fuel - 1,
            ))
            Ok(#(
              list.append(output.0, [child.value]),
              list.append(output.1, child.applications),
            ))
          },
        ),
      )
      Ok(DefaultDraft(kdl.JsonValueArr(output.0), output.1))
    }
    types.ProductShape(spec), kdl.JsonValueObj(members) -> {
      use retained <- result.try(
        list.try_fold(members, #([], []), fn(output, member) {
          let #(values, applications) = output
          case
            list.find(spec.fields, fn(field) { field.wire_name == member.0 }),
            member.1
          {
            Ok(field), item if item != kdl.JsonValueNull -> {
              use child <- result.try(default_draft(
                graph,
                field.slot.type_ref,
                list.append(path, [types.Field(member.0)]),
                item,
                fuel - 1,
              ))
              Ok(#(
                list.append(values, [#(member.0, child.value)]),
                list.append(applications, child.applications),
              ))
            }
            _, _ -> Ok(#(list.append(values, [member]), applications))
          }
        }),
      )
      use inserted <- result.try(
        list.try_fold(spec.fields, retained, fn(output, field) {
          let #(values, applications) = output
          case list.key_find(members, field.wire_name) {
            Ok(_) -> Ok(output)
            Error(_) ->
              case
                declared_default(
                  graph,
                  field.slot.type_ref,
                  list.length(graph.nodes) + 1,
                )
              {
                None -> Ok(output)
                Some(#(default_ref, item)) -> {
                  use _ <- result.try(validate_value(graph, default_ref, item))
                  let application =
                    DefaultApplication(
                      list.append(path, [types.Field(field.wire_name)]),
                      default_ref,
                      types.occurrence_at(default_ref, "default"),
                      item,
                    )
                  Ok(#(
                    list.append(values, [#(field.wire_name, item)]),
                    list.append(applications, [application]),
                  ))
                }
              }
          }
        }),
      )
      Ok(DefaultDraft(kdl.JsonValueObj(inserted.0), inserted.1))
    }
    _, _ -> Ok(DefaultDraft(value, []))
  }
}

pub fn materialize_defaults(
  graph: types.SemanticGraph,
  reference: types.TypeRef,
  value: kdl.JsonValue,
) -> Result(DefaultedValue, ValidationFailure) {
  use draft <- result.try(default_draft(
    graph,
    reference,
    [],
    value,
    { declared_json_size(value) + 1 } * { list.length(graph.nodes) + 1 },
  ))
  use checked <- result.try(validate_value(graph, reference, draft.value))
  case
    check_default_applications(graph, value, draft.value, draft.applications)
  {
    True ->
      Ok(DefaultedValue(
        graph,
        reference,
        draft.value,
        draft.applications,
        checked.proof,
      ))
    False ->
      Error(CertificateMismatchFailure("default source, absence, or result"))
  }
}

pub fn member_certificate(
  graph: types.SemanticGraph,
  reference: types.TypeRef,
  value: kdl.JsonValue,
) -> Result(MemberProof, ValidationFailure) {
  validate_value(graph, reference, value)
  |> result.map(fn(value) { value.proof })
}

pub fn check_member_certificate(
  graph: types.SemanticGraph,
  reference: types.TypeRef,
  value: kdl.JsonValue,
  proof: MemberProof,
) -> Result(Nil, ValidationFailure) {
  use observed <- result.try(member_certificate(graph, reference, value))
  case observed == proof {
    True -> Ok(Nil)
    False ->
      validate_value(graph, reference, value) |> result.map(fn(_) { Nil })
  }
}

fn type_default(shape: types.TypeShape) -> Option(kdl.JsonValue) {
  case shape {
    types.BooleanShape(spec) ->
      option.map(spec.default_value, kdl.JsonValueBool)
    types.IntegerShape(spec) -> option.map(spec.default_value, kdl.JsonValueNum)
    types.StringShape(spec) -> option.map(spec.default_value, kdl.JsonValueStr)
    _ -> None
  }
}

pub fn check_default_applications(
  graph: types.SemanticGraph,
  before: kdl.JsonValue,
  after: kdl.JsonValue,
  applications: List(DefaultApplication),
) -> Bool {
  list.all(applications, fn(application) {
    value_at_path(graph.profile.tag, before, application.value_path)
    == types.Absent
    && value_at_path(graph.profile.tag, after, application.value_path)
    == types.Present(application.value)
    && application.origin
    == types.OccurrenceRef(
      application.type_ref.source,
      list.append(application.type_ref.pointer, ["default"]),
    )
    && option.then(find_type(graph, application.type_ref), fn(node) {
      type_default(node.shape)
    })
    == Some(application.value)
  })
}
