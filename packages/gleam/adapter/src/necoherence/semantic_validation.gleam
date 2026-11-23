// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/bit_array
import gleam/bool
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import necoherence/exact_json as kdl
import necoherence/semantic_base64 as base64
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

pub type MemberCertificate {
  MemberCertificate(
    profile: types.ProfileRef,
    source_refs: List(types.SourceRef),
    contract: types.SlotContract,
    value: types.SlotValue(kdl.JsonValue),
    proof: Option(MemberProof),
  )
}

pub opaque type ValidatedSlot {
  ValidatedSlot(
    graph: types.SemanticGraph,
    contract: types.SlotContract,
    value: types.SlotValue(kdl.JsonValue),
    certificate: MemberCertificate,
  )
}

pub type ValueRequirement {
  ValueRequirement(
    type_ref: types.TypeRef,
    value_path: types.ValuePath,
    value: kdl.JsonValue,
  )
}

pub type Expansion {
  Requirements(children: List(ValueRequirement))
  RejectedExpansion(failure: types.ValueFailure)
  UnresolvedExpansion(obligations: List(types.SemanticObligation))
}

pub type MembershipResult {
  Accepted(proof: MemberProof)
  RejectedMembership(failure: types.ValueFailure)
  UnresolvedMembership(obligations: List(types.SemanticObligation))
  InvalidCertificate(condition: String)
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
  VariantSelectionUndetermined(path: types.ValuePath, tag: String)
  ProjectionUnresolved(obligations: List(types.SemanticObligation))
  CertificateMismatch(condition: String)
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

type Indexed(a)

@external(erlang, "erlang", "list_to_tuple")
fn indexed(items: List(a)) -> Indexed(a)

@external(erlang, "erlang", "element")
fn indexed_at(position: Int, items: Indexed(a)) -> a

type RangeLookup(a) {
  SortedRanges(ranges: Indexed(a), size: Int)
  LinearRanges(ranges: List(a))
}

type GraphemeLookup {
  GraphemeLookup(
    properties: RangeLookup(types.GraphemeRange),
    indic_conjunct: RangeLookup(types.IndicRange),
    extended_pictographic: RangeLookup(types.CodepointRange),
  )
}

fn range_lookup(
  ranges: List(a),
  first: fn(a) -> Int,
  last: fn(a) -> Int,
) -> RangeLookup(a) {
  case ranges_sorted_disjoint(ranges, first, last, -1, 0) {
    Some(size) -> SortedRanges(indexed(ranges), size)
    None -> LinearRanges(ranges)
  }
}

fn ranges_sorted_disjoint(
  ranges: List(a),
  first: fn(a) -> Int,
  last: fn(a) -> Int,
  previous_last: Int,
  size: Int,
) -> Option(Int) {
  case ranges {
    [] -> Some(size)
    [range, ..rest] ->
      case first(range) > previous_last && first(range) <= last(range) {
        True -> ranges_sorted_disjoint(rest, first, last, last(range), size + 1)
        False -> None
      }
  }
}

fn find_range(
  lookup: RangeLookup(a),
  first: fn(a) -> Int,
  last: fn(a) -> Int,
  codepoint: Int,
) -> Option(a) {
  case lookup {
    LinearRanges(ranges) ->
      option.from_result(
        list.find(ranges, fn(range) {
          codepoint >= first(range) && codepoint <= last(range)
        }),
      )
    SortedRanges(ranges, size) ->
      search_ranges(ranges, first, last, codepoint, 1, size)
  }
}

fn search_ranges(
  ranges: Indexed(a),
  first: fn(a) -> Int,
  last: fn(a) -> Int,
  codepoint: Int,
  low: Int,
  high: Int,
) -> Option(a) {
  case low > high {
    True -> None
    False -> {
      let middle = { low + high } / 2
      let range = indexed_at(middle, ranges)
      case codepoint < first(range), codepoint > last(range) {
        True, _ ->
          search_ranges(ranges, first, last, codepoint, low, middle - 1)
        _, True ->
          search_ranges(ranges, first, last, codepoint, middle + 1, high)
        False, False -> Some(range)
      }
    }
  }
}

fn grapheme_lookup(rules: types.GraphemeRules) -> GraphemeLookup {
  GraphemeLookup(
    range_lookup(
      rules.properties,
      fn(range: types.GraphemeRange) { range.first },
      fn(range: types.GraphemeRange) { range.last },
    ),
    range_lookup(
      rules.indic_conjunct,
      fn(range: types.IndicRange) { range.first },
      fn(range: types.IndicRange) { range.last },
    ),
    range_lookup(
      rules.extended_pictographic,
      fn(range: types.CodepointRange) { range.first },
      fn(range: types.CodepointRange) { range.last },
    ),
  )
}

pub fn grapheme_count(rules: types.GraphemeRules, text: String) -> Int {
  lookup_grapheme_count(grapheme_lookup(rules), codepoints(text))
}

fn lookup_grapheme_count(lookup: GraphemeLookup, codepoints: List(Int)) -> Int {
  segment_graphemes(
    lookup,
    codepoints,
    GraphemeState(None, 0, False, False, False, False),
    0,
    0,
    fn(count, _) { count + 1 },
  ).1
}

pub fn grapheme_boundaries(
  rules: types.GraphemeRules,
  text: String,
) -> List(Int) {
  let #(length, boundaries) =
    segment_graphemes(
      grapheme_lookup(rules),
      codepoints(text),
      GraphemeState(None, 0, False, False, False, False),
      0,
      [],
      fn(boundaries, offset) { [offset, ..boundaries] },
    )
  case length {
    0 -> []
    _ -> list.reverse([length, ..boundaries])
  }
}

fn segment_graphemes(
  lookup: GraphemeLookup,
  codepoints: List(Int),
  state: GraphemeState,
  offset: Int,
  accumulated: a,
  boundary: fn(a, Int) -> a,
) -> #(Int, a) {
  case codepoints {
    [] -> #(offset, accumulated)
    [codepoint, ..rest] -> {
      let property = grapheme_property(lookup, codepoint)
      let indic = indic_property(lookup, codepoint)
      let pictographic = pictographic(lookup, codepoint)
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
        lookup,
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
  let previous_control = case state.previous {
    Some(previous) -> control_property(previous)
    None -> False
  }
  let current_control = control_property(current)
  case state.previous {
    None -> True
    Some(types.Cr) if current == types.Lf -> False
    Some(_) if previous_control -> True
    _ if current_control -> True
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
  lookup: GraphemeLookup,
  codepoint: Int,
) -> types.GraphemeProperty {
  case
    find_range(
      lookup.properties,
      fn(range: types.GraphemeRange) { range.first },
      fn(range: types.GraphemeRange) { range.last },
      codepoint,
    )
  {
    Some(range) -> range.property
    None -> types.Other
  }
}

fn indic_property(
  lookup: GraphemeLookup,
  codepoint: Int,
) -> types.IndicProperty {
  case
    find_range(
      lookup.indic_conjunct,
      fn(range: types.IndicRange) { range.first },
      fn(range: types.IndicRange) { range.last },
      codepoint,
    )
  {
    Some(range) -> range.property
    None -> types.IndicOther
  }
}

fn pictographic(lookup: GraphemeLookup, codepoint: Int) -> Bool {
  option.is_some(find_range(
    lookup.extended_pictographic,
    fn(range: types.CodepointRange) { range.first },
    fn(range: types.CodepointRange) { range.last },
    codepoint,
  ))
}

fn control_property(property: types.GraphemeProperty) -> Bool {
  property == types.Cr || property == types.Lf || property == types.Control
}

pub fn recognizes(
  grapheme_rules: Option(types.GraphemeRules),
  rule: types.FormatRule,
  text: String,
) -> Bool {
  let program = compile_format_program(rule)
  let lookup = case program.uses_graphemes {
    True -> option.map(grapheme_rules, grapheme_lookup)
    False -> None
  }
  run_format_program(program, grapheme_rules, lookup, text)
}

type FormatProgram {
  FormatProgram(node: FormatSpanNode, uses_graphemes: Bool)
}

fn compile_format_program(rule: types.FormatRule) -> FormatProgram {
  let #(node, _) = compile_format_span(rule, 0)
  FormatProgram(node, format_rule_uses_graphemes(rule))
}

fn run_format_program(
  program: FormatProgram,
  grapheme_rules: Option(types.GraphemeRules),
  lookup: Option(GraphemeLookup),
  text: String,
) -> Bool {
  let #(context, count) =
    format_span_context_of_string(grapheme_rules, lookup, text)
  span_accepts(
    program.node,
    context,
    0,
    count,
    FormatSpanMemo(dict.new(), dict.new(), dict.new()),
  ).0
}

type FormatCache {
  FormatCache(
    grapheme: Option(GraphemeLookup),
    named: Dict(String, FormatProgram),
    inline: Dict(types.FormatRule, FormatProgram),
  )
}

type Tables {
  Tables(profile: types.SemanticProfile, cache: Option(FormatCache))
}

fn tables_of(profile: types.SemanticProfile) -> Tables {
  Tables(profile, None)
}

fn prepared_format_cache(graph: types.SemanticGraph) -> FormatCache {
  let profile = graph.profile
  let named =
    list.fold(
      list.reverse(profile.format_bindings),
      dict.new(),
      fn(named, binding) {
        dict.insert(named, binding.name, compile_format_program(binding.rule))
      },
    )
  let inline =
    list.fold(graph_inline_rules(graph), dict.new(), fn(inline, rule) {
      case dict.has_key(inline, rule) {
        True -> inline
        False -> dict.insert(inline, rule, compile_format_program(rule))
      }
    })
  FormatCache(
    option.map(profile.grapheme_rules, grapheme_lookup),
    named,
    inline,
  )
}

fn graph_inline_rules(graph: types.SemanticGraph) -> List(types.FormatRule) {
  let from_use = fn(format) {
    case format {
      Some(types.InlineFormat(rule)) -> [rule]
      _ -> []
    }
  }
  let from_leaf = fn(leaf) {
    case leaf {
      types.SealedString(spec) -> from_use(spec.format)
      types.SealedInteger(_) -> []
    }
  }
  let from_tag =
    list.flat_map(
      case graph.profile.tag {
        Some(model) -> model.sealed
        None -> []
      },
      fn(form) {
        list.flat_map(form.fields, fn(field) { from_leaf(field.leaf) })
      },
    )
  list.append(
    from_tag,
    list.flat_map(graph.nodes, fn(node) {
      case node.shape {
        types.StringShape(spec) -> from_use(spec.format)
        types.ProductShape(spec) ->
          case spec.extras {
            types.AllowExtras(key_format, _) -> from_use(key_format)
            types.RejectExtras -> []
          }
        types.SealedShape(_, refinements) ->
          list.flat_map(refinements, fn(refinement) {
            from_leaf(refinement.leaf)
          })
        _ -> []
      }
    }),
  )
}

fn run_cached_program(
  cache: FormatCache,
  grapheme_rules: Option(types.GraphemeRules),
  program: FormatProgram,
) -> fn(String) -> Bool {
  let lookup = case program.uses_graphemes {
    True -> cache.grapheme
    False -> None
  }
  fn(text) { run_format_program(program, grapheme_rules, lookup, text) }
}

fn tables_named_format(
  tables: Tables,
  name: String,
) -> Option(fn(String) -> Bool) {
  let profile = tables.profile
  case tables.cache {
    None ->
      case
        list.find(profile.format_bindings, fn(binding) { binding.name == name })
      {
        Ok(binding) ->
          Some(fn(text) {
            recognizes(profile.grapheme_rules, binding.rule, text)
          })
        Error(_) -> None
      }
    Some(cache) ->
      case dict.get(cache.named, name) {
        Ok(program) ->
          Some(run_cached_program(cache, profile.grapheme_rules, program))
        Error(_) -> None
      }
  }
}

fn tables_inline_format(
  tables: Tables,
  rule: types.FormatRule,
) -> fn(String) -> Bool {
  let profile = tables.profile
  case tables.cache {
    None -> fn(text) { recognizes(profile.grapheme_rules, rule, text) }
    Some(cache) ->
      case dict.get(cache.inline, rule) {
        Ok(program) ->
          run_cached_program(cache, profile.grapheme_rules, program)
        Error(_) -> fn(text) { recognizes(profile.grapheme_rules, rule, text) }
      }
  }
}

pub fn format_use_accepts(
  profile: types.SemanticProfile,
  format_use: types.FormatUse,
  text: String,
) -> Bool {
  format_use_accepts_with(tables_of(profile), format_use, text)
}

pub fn wrapper_payload_text(
  profile: types.SemanticProfile,
  wrapper: types.Wrapper,
  value: kdl.JsonValue,
) -> Option(String) {
  wrapper_payload_text_with(tables_of(profile), wrapper, value)
}

pub fn wrapper_text_accepts(
  profile: types.SemanticProfile,
  value: kdl.JsonValue,
) -> Bool {
  wrapper_text_accepts_with(tables_of(profile), value)
}

pub fn string_condition(
  profile: types.SemanticProfile,
  spec: types.StringSpec,
  value: String,
) -> Option(types.ValueCondition) {
  string_condition_with(tables_of(profile), spec, value)
}

pub fn tag_value_accepts(
  profile: types.SemanticProfile,
  members: List(#(String, kdl.JsonValue)),
) -> Bool {
  tag_value_accepts_with(tables_of(profile), members)
}

pub fn data_value_accepts(
  profile: types.SemanticProfile,
  value: kdl.JsonValue,
) -> Bool {
  data_value_accepts_with(tables_of(profile), value)
}

pub fn selector_matches(
  profile: types.SemanticProfile,
  branch: types.UnionBranch,
  value: kdl.JsonValue,
) -> Bool {
  selector_matches_with(tables_of(profile), branch, value)
}

pub fn select_union_branch(
  profile: types.SemanticProfile,
  spec: types.UnionSpec,
  value: kdl.JsonValue,
) -> Option(types.UnionBranch) {
  select_union_branch_with(tables_of(profile), spec, value)
}

fn tables_grapheme_count(tables: Tables, text: String) -> Option(Int) {
  case tables.cache {
    None ->
      option.map(tables.profile.grapheme_rules, fn(rules) {
        grapheme_count(rules, text)
      })
    Some(cache) ->
      option.map(cache.grapheme, fn(lookup) {
        lookup_grapheme_count(lookup, codepoints(text))
      })
  }
}

pub fn format_accepts(
  grapheme_rules: Option(types.GraphemeRules),
  rule: types.FormatRule,
  text: String,
) -> Bool {
  format_accepts_fuel(grapheme_rules, types.format_rule_depth(rule), rule, text)
}

fn format_accepts_fuel(
  grapheme_rules: Option(types.GraphemeRules),
  fuel: Int,
  rule: types.FormatRule,
  text: String,
) -> Bool {
  case fuel <= 0 {
    True -> False
    False -> {
      let inner = fuel - 1
      case rule {
        types.Literal(_)
        | types.Identifier(..)
        | types.AbsoluteUri(_)
        | types.Timestamp(_)
        | types.LanguageTag(_)
        | types.AsciiDfa(_)
        | types.Text -> recognizes_leaf(rule, text)
        types.Sequence(parts) ->
          sequence_accepts_with(
            fn(part, part_text) {
              format_accepts_fuel(grapheme_rules, inner, part, part_text)
            },
            parts,
            text,
          )
        types.Optional(child) ->
          format_accepts_fuel(grapheme_rules, inner, child, text) || text == ""
        types.Labels(separator, min_count, max_count, total_max, child) -> {
          let values = label_parts(separator, text)
          let count = list.length(values)
          separator != ""
          && count >= min_count
          && option.unwrap(
            option.map(max_count, fn(bound) { count <= bound }),
            True,
          )
          && option.unwrap(
            option.map(total_max, fn(bound) { codepoint_count(text) <= bound }),
            True,
          )
          && list.all(values, fn(value) {
            format_accepts_fuel(grapheme_rules, inner, child, value)
          })
        }
        types.Bounded(unit, maximum, child) ->
          format_within(grapheme_rules, unit, maximum, text)
          && format_accepts_fuel(grapheme_rules, inner, child, text)
        types.Choice(rules) ->
          list.any(rules, fn(child) {
            format_accepts_fuel(grapheme_rules, inner, child, text)
          })
        types.Not(child) ->
          types.format_rule_depth(child) <= inner
          && !format_accepts_fuel(grapheme_rules, inner, child, text)
      }
    }
  }
}

fn sequence_accepts_with(
  accepts: fn(types.FormatRule, String) -> Bool,
  parts: List(types.FormatRule),
  text: String,
) -> Bool {
  case parts {
    [] -> text == ""
    [first, ..rest] -> {
      let source = bit_array.from_string(text)
      sequence_split_accepts(
        accepts,
        first,
        rest,
        source,
        bit_array.byte_size(source),
        [0, ..codepoint_byte_ends(codepoints(text), 0)],
      )
    }
  }
}

fn sequence_split_accepts(
  accepts: fn(types.FormatRule, String) -> Bool,
  first: types.FormatRule,
  rest: List(types.FormatRule),
  source: BitArray,
  size: Int,
  offsets: List(Int),
) -> Bool {
  case offsets {
    [] -> False
    [offset, ..later] ->
      {
        accepts(first, byte_text(source, 0, offset))
        && sequence_accepts_with(accepts, rest, byte_text(source, offset, size))
      }
      || sequence_split_accepts(accepts, first, rest, source, size, later)
  }
}

fn byte_text(source: BitArray, first: Int, last: Int) -> String {
  let assert Ok(bytes) = bit_array.slice(source, first, last - first)
  let assert Ok(text) = bit_array.to_string(bytes)
  text
}

fn codepoint_byte_width(codepoint: Int) -> Int {
  case codepoint < 128, codepoint < 2048, codepoint < 65_536 {
    True, _, _ -> 1
    _, True, _ -> 2
    _, _, True -> 3
    _, _, _ -> 4
  }
}

fn codepoint_byte_ends(codepoints: List(Int), offset: Int) -> List(Int) {
  case codepoints {
    [] -> []
    [codepoint, ..rest] -> {
      let end = offset + codepoint_byte_width(codepoint)
      [end, ..codepoint_byte_ends(rest, end)]
    }
  }
}

fn codepoint_count(text: String) -> Int {
  list.length(string.to_utf_codepoints(text))
}

fn format_span_context_of_string(
  grapheme_rules: Option(types.GraphemeRules),
  grapheme_lookup: Option(GraphemeLookup),
  text: String,
) -> #(FormatSpanContext, Int) {
  let points = codepoints(text)
  let count = list.length(points)
  let context =
    FormatSpanContext(
      bit_array.from_string(text),
      indexed([0, ..codepoint_byte_ends(points, 0)]),
      indexed(points),
      count,
      grapheme_rules,
      grapheme_lookup,
    )
  #(context, count)
}

type SpanWidth {
  SpanWidth(minimum: Int, maximum: Option(Int))
}

type FormatSpanNode {
  SpanEpsilon(id: Int)
  SpanSequence(
    id: Int,
    width: SpanWidth,
    left: FormatSpanNode,
    right: FormatSpanNode,
  )
  SpanRule(
    id: Int,
    width: SpanWidth,
    rule: types.FormatRule,
    children: List(FormatSpanNode),
  )
  SpanLiteral(id: Int, width: SpanWidth, value: BitArray)
  SpanIdentifier(
    id: Int,
    width: SpanWidth,
    first: String,
    rest: String,
    forbidden: List(BitArray),
  )
  SpanDfa(
    id: Int,
    spec: types.DfaSpec,
    transitions: Dict(Int, List(types.DfaTransition)),
  )
}

type FormatSpanContext {
  FormatSpanContext(
    source: BitArray,
    offsets: Indexed(Int),
    codepoints: Indexed(Int),
    count: Int,
    grapheme_rules: Option(types.GraphemeRules),
    grapheme_lookup: Option(GraphemeLookup),
  )
}

type FormatSpanMemo {
  FormatSpanMemo(
    accepted: Dict(#(Int, Int, Int), Bool),
    runs: Dict(#(Int, Int), Int),
    sets: Dict(String, Int),
  )
}

fn fresh_format_span_id(next: Int) -> #(Int, Int) {
  #(next, next + 1)
}

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
    _ -> {
      let #(id, next) = fresh_format_span_id(next)
      #(compile_format_node(id, rule, children), next)
    }
  }
}

fn compile_format_node(
  id: Int,
  rule: types.FormatRule,
  children: List(FormatSpanNode),
) -> FormatSpanNode {
  case rule {
    types.Literal(value) -> {
      let length = codepoint_count(value)
      SpanLiteral(
        id,
        SpanWidth(length, Some(length)),
        bit_array.from_string(value),
      )
    }
    types.Identifier(first, rest, exact, minimum, maximum, forbidden) -> {
      let #(lower, upper) = case exact {
        None -> #(int.max(1, minimum), maximum)
        Some(length) -> #(
          int.max(int.max(1, minimum), length),
          Some(option.unwrap(
            option.map(maximum, fn(upper) { int.min(upper, length) }),
            length,
          )),
        )
      }
      SpanIdentifier(
        id,
        SpanWidth(lower, upper),
        first,
        rest,
        list.map(forbidden, bit_array.from_string),
      )
    }
    types.AsciiDfa(spec) ->
      SpanDfa(id, spec, dfa_transitions_by_state(spec.transitions))
    _ -> SpanRule(id, format_rule_width(rule, children), rule, children)
  }
}

fn format_rule_width(
  rule: types.FormatRule,
  children: List(FormatSpanNode),
) -> SpanWidth {
  case rule, children {
    types.Choice(_), _ ->
      case list.map(children, span_width) {
        [] -> SpanWidth(0, Some(0))
        [width, ..widths] ->
          list.fold(widths, width, fn(union, width) {
            SpanWidth(
              int.min(union.minimum, width.minimum),
              case union.maximum, width.maximum {
                Some(left), Some(right) -> Some(int.max(left, right))
                _, _ -> None
              },
            )
          })
      }
    types.Optional(_), [child] ->
      SpanWidth(
        0,
        option.map(span_width(child).maximum, fn(upper) { int.max(upper, 0) }),
      )
    types.Bounded(types.Graphemes, _, _), [child] -> span_width(child)
    types.Bounded(_, maximum, _), [child] -> {
      let width = span_width(child)
      SpanWidth(
        width.minimum,
        Some(option.unwrap(
          option.map(width.maximum, fn(upper) { int.min(upper, maximum) }),
          maximum,
        )),
      )
    }
    types.Labels(_, _, _, total_maximum, _), _ -> SpanWidth(0, total_maximum)
    types.AbsoluteUri(maximum), _ -> SpanWidth(0, maximum)
    _, _ -> SpanWidth(0, None)
  }
}

fn span_width(node: FormatSpanNode) -> SpanWidth {
  case node {
    SpanEpsilon(_) -> SpanWidth(0, Some(0))
    SpanSequence(_, width, _, _)
    | SpanRule(_, width, _, _)
    | SpanLiteral(_, width, _)
    | SpanIdentifier(_, width, _, _, _) -> width
    SpanDfa(_, _, _) -> SpanWidth(0, None)
  }
}

fn width_admits(width: SpanWidth, length: Int) -> Bool {
  length >= width.minimum
  && case width.maximum {
    Some(upper) -> length <= upper
    None -> True
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
    [] -> {
      let #(id, next) = fresh_format_span_id(next)
      #(SpanEpsilon(id), next)
    }
    [child] -> #(child, next)
    [_, _, ..] -> {
      let #(left, right) = list.split(children, list.length(children) / 2)
      let #(left, next) = binary_format_sequence(left, next)
      let #(right, next) = binary_format_sequence(right, next)
      let #(id, next) = fresh_format_span_id(next)
      let left_width = span_width(left)
      let right_width = span_width(right)
      let width =
        SpanWidth(
          left_width.minimum + right_width.minimum,
          case left_width.maximum, right_width.maximum {
            Some(left), Some(right) -> Some(left + right)
            _, _ -> None
          },
        )
      #(SpanSequence(id, width, left, right), next)
    }
  }
}

fn span_offset(context: FormatSpanContext, index: Int) -> Int {
  indexed_at(index + 1, context.offsets)
}

fn span_codepoint(context: FormatSpanContext, index: Int) -> Int {
  indexed_at(index + 1, context.codepoints)
}

fn span_bytes(context: FormatSpanContext, start: Int, end: Int) -> BitArray {
  let first = span_offset(context, start)
  let assert Ok(bytes) =
    bit_array.slice(context.source, first, span_offset(context, end) - first)
  bytes
}

fn span_text(context: FormatSpanContext, start: Int, end: Int) -> String {
  let assert Ok(text) = bit_array.to_string(span_bytes(context, start, end))
  text
}

fn span_codepoints(
  context: FormatSpanContext,
  start: Int,
  index: Int,
  acc: List(Int),
) -> List(Int) {
  case index < start {
    True -> acc
    False ->
      span_codepoints(context, start, index - 1, [
        span_codepoint(context, index),
        ..acc
      ])
  }
}

fn span_accepts(
  node: FormatSpanNode,
  context: FormatSpanContext,
  start: Int,
  end: Int,
  memo: FormatSpanMemo,
) -> #(Bool, FormatSpanMemo) {
  case width_admits(span_width(node), end - start), node {
    False, _ -> #(False, memo)
    True, SpanEpsilon(_) -> #(True, memo)
    True, SpanLiteral(_, _, value) -> #(
      span_bytes(context, start, end) == value,
      memo,
    )
    True, SpanIdentifier(id, _, first, rest, forbidden) ->
      span_identifier(id, first, rest, forbidden, context, start, end, memo)
    True, SpanSequence(id, _, _, _)
    | True, SpanRule(id, _, _, _)
    | True, SpanDfa(id, _, _)
    -> {
      let key = #(id, start, end)
      case dict.get(memo.accepted, key) {
        Ok(accepted) -> #(accepted, memo)
        Error(_) -> {
          let #(accepted, memo) = case node {
            SpanSequence(_, _, left, right) -> {
              let left_width = span_width(left)
              let right_width = span_width(right)
              let lowest = case right_width.maximum {
                Some(upper) -> int.max(start + left_width.minimum, end - upper)
                None -> start + left_width.minimum
              }
              let highest = case left_width.maximum {
                Some(upper) -> int.min(end - right_width.minimum, start + upper)
                None -> end - right_width.minimum
              }
              span_splits(
                left,
                right,
                context,
                start,
                end,
                lowest,
                highest,
                memo,
              )
            }
            SpanRule(_, _, rule, children) ->
              span_rule(rule, children, context, start, end, memo)
            SpanDfa(_, spec, transitions) -> #(
              run_span_dfa(
                spec,
                transitions,
                context,
                start,
                end,
                spec.initial_state,
              ),
              memo,
            )
            SpanEpsilon(_)
            | SpanLiteral(_, _, _)
            | SpanIdentifier(_, _, _, _, _) -> #(False, memo)
          }
          #(
            accepted,
            FormatSpanMemo(
              ..memo,
              accepted: dict.insert(memo.accepted, key, accepted),
            ),
          )
        }
      }
    }
  }
}

fn span_splits(
  left: FormatSpanNode,
  right: FormatSpanNode,
  context: FormatSpanContext,
  start: Int,
  end: Int,
  split: Int,
  highest: Int,
  memo: FormatSpanMemo,
) -> #(Bool, FormatSpanMemo) {
  case split > highest {
    True -> #(False, memo)
    False -> {
      let #(accepted, memo) =
        format_span_and(
          fn(memo) { span_accepts(left, context, start, split, memo) },
          fn(memo) { span_accepts(right, context, split, end, memo) },
          memo,
        )
      case accepted {
        True -> #(True, memo)
        False ->
          span_splits(
            left,
            right,
            context,
            start,
            end,
            split + 1,
            highest,
            memo,
          )
      }
    }
  }
}

fn span_identifier(
  id: Int,
  first: String,
  rest: String,
  forbidden: List(BitArray),
  context: FormatSpanContext,
  start: Int,
  end: Int,
  memo: FormatSpanMemo,
) -> #(Bool, FormatSpanMemo) {
  let #(first, memo) = memo_ascii_set(memo, first)
  let #(rest, memo) = memo_ascii_set(memo, rest)
  case ascii_member(first, span_codepoint(context, start)) {
    False -> #(False, memo)
    True -> {
      let #(run, memo) = case dict.get(memo.runs, #(id, start)) {
        Ok(run) -> #(run, memo)
        Error(_) -> {
          let run = ascii_run(context, rest, start + 1)
          #(
            run,
            FormatSpanMemo(
              ..memo,
              runs: dict.insert(memo.runs, #(id, start), run),
            ),
          )
        }
      }
      #(
        end <= run
          && case forbidden {
          [] -> True
          _ -> !list.contains(forbidden, span_bytes(context, start, end))
        },
        memo,
      )
    }
  }
}

fn ascii_run(context: FormatSpanContext, set: Int, index: Int) -> Int {
  case
    index < context.count && ascii_member(set, span_codepoint(context, index))
  {
    True -> ascii_run(context, set, index + 1)
    False -> index
  }
}

fn memo_ascii_set(
  memo: FormatSpanMemo,
  alphabet: String,
) -> #(Int, FormatSpanMemo) {
  case dict.get(memo.sets, alphabet) {
    Ok(set) -> #(set, memo)
    Error(_) -> {
      let set = ascii_set(alphabet)
      #(
        set,
        FormatSpanMemo(..memo, sets: dict.insert(memo.sets, alphabet, set)),
      )
    }
  }
}

fn ascii_set(alphabet: String) -> Int {
  ascii_set_of(bit_array.from_string(alphabet), 0)
}

fn ascii_set_of(bytes: BitArray, set: Int) -> Int {
  case bytes {
    <<byte, rest:bytes>> if byte < 128 ->
      ascii_set_of(rest, int.bitwise_or(set, int.bitwise_shift_left(1, byte)))
    <<_, rest:bytes>> -> ascii_set_of(rest, set)
    _ -> set
  }
}

fn ascii_member(set: Int, codepoint: Int) -> Bool {
  codepoint < 128
  && int.bitwise_and(int.bitwise_shift_right(set, codepoint), 1) == 1
}

fn run_span_dfa(
  spec: types.DfaSpec,
  transitions: Dict(Int, List(types.DfaTransition)),
  context: FormatSpanContext,
  index: Int,
  end: Int,
  state: Int,
) -> Bool {
  case index >= end {
    True -> list.contains(spec.accepting_states, state)
    False ->
      case dfa_step(transitions, state, span_codepoint(context, index)) {
        Some(next) ->
          run_span_dfa(spec, transitions, context, index + 1, end, next)
        None -> False
      }
  }
}

fn dfa_transitions_by_state(
  transitions: List(types.DfaTransition),
) -> Dict(Int, List(types.DfaTransition)) {
  list.fold(list.reverse(transitions), dict.new(), fn(groups, transition) {
    dict.insert(groups, transition.from_state, [
      transition,
      ..result.unwrap(dict.get(groups, transition.from_state), [])
    ])
  })
}

fn dfa_step(
  transitions: Dict(Int, List(types.DfaTransition)),
  state: Int,
  codepoint: Int,
) -> Option(Int) {
  case codepoint < 128 {
    False -> None
    True ->
      case
        list.find(
          result.unwrap(dict.get(transitions, state), []),
          fn(transition) {
            codepoint >= transition.first && codepoint <= transition.last
          },
        )
      {
        Ok(transition) -> Some(transition.to_state)
        Error(_) -> None
      }
  }
}

fn label_parts(separator: String, text: String) -> List(String) {
  let chars = codepoint_strings(text)
  list.map(
    split_at_separator(codepoint_strings(separator), list.length(chars), chars),
    string.concat,
  )
}

fn codepoint_strings(text: String) -> List(String) {
  list.map(string.to_utf_codepoints(text), fn(point) {
    string.from_utf_codepoints([point])
  })
}

fn prepend_to_first_label(
  first: String,
  labels: List(List(String)),
) -> List(List(String)) {
  case labels {
    [] -> [[first]]
    [label, ..later] -> [[first, ..label], ..later]
  }
}

fn split_at_separator(
  separator: List(String),
  fuel: Int,
  text: List(String),
) -> List(List(String)) {
  case fuel <= 0 {
    True -> [text]
    False ->
      case text {
        [] -> [[]]
        [first, ..rest] ->
          case list.take(text, list.length(separator)) == separator {
            True -> [
              [],
              ..split_at_separator(
                separator,
                fuel - 1,
                list.drop(text, list.length(separator)),
              )
            ]
            False ->
              prepend_to_first_label(
                first,
                split_at_separator(separator, fuel - 1, rest),
              )
          }
      }
  }
}

fn format_span_short_circuit(
  target: Bool,
  check: fn(a, FormatSpanMemo) -> #(Bool, FormatSpanMemo),
  items: List(a),
  memo: FormatSpanMemo,
) -> #(Bool, FormatSpanMemo) {
  case items {
    [] -> #(!target, memo)
    [item, ..rest] -> {
      let #(result, memo) = check(item, memo)
      case result == target {
        True -> #(target, memo)
        False -> format_span_short_circuit(target, check, rest, memo)
      }
    }
  }
}

fn format_span_and(
  left: fn(FormatSpanMemo) -> #(Bool, FormatSpanMemo),
  right: fn(FormatSpanMemo) -> #(Bool, FormatSpanMemo),
  memo: FormatSpanMemo,
) -> #(Bool, FormatSpanMemo) {
  let #(accepted_left, memo) = left(memo)
  case accepted_left {
    True -> right(memo)
    False -> #(False, memo)
  }
}

fn span_labels(
  context: FormatSpanContext,
  separator: List(Int),
  separator_length: Int,
  label_start: Int,
  index: Int,
  end: Int,
  spans: List(#(Int, Int)),
) -> List(#(Int, Int)) {
  case separator {
    [] -> []
    _ ->
      case index >= end {
        True -> list.reverse([#(label_start, end), ..spans])
        False ->
          case
            index + separator_length <= end
            && span_matches(context, separator, index)
          {
            True ->
              span_labels(
                context,
                separator,
                separator_length,
                index + separator_length,
                index + separator_length,
                end,
                [#(label_start, index), ..spans],
              )
            False ->
              span_labels(
                context,
                separator,
                separator_length,
                label_start,
                index + 1,
                end,
                spans,
              )
          }
      }
  }
}

fn span_matches(
  context: FormatSpanContext,
  expected: List(Int),
  index: Int,
) -> Bool {
  case expected {
    [] -> True
    [codepoint, ..rest] ->
      span_codepoint(context, index) == codepoint
      && span_matches(context, rest, index + 1)
  }
}

fn span_within(
  context: FormatSpanContext,
  unit: types.StringLengthUnit,
  maximum: Int,
  start: Int,
  end: Int,
) -> Bool {
  case unit {
    types.UnicodeScalars -> end - start <= maximum
    types.Utf8Bytes ->
      span_offset(context, end) - span_offset(context, start) <= maximum
    types.Graphemes ->
      case context.grapheme_lookup {
        Some(lookup) ->
          lookup_grapheme_count(
            lookup,
            span_codepoints(context, start, end - 1, []),
          )
          <= maximum
        None -> False
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
    types.Choice(_), _ ->
      format_span_short_circuit(
        True,
        fn(child, memo) { span_accepts(child, context, start, end, memo) },
        children,
        memo,
      )
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
      case span_within(context, unit, maximum, start, end) {
        True -> span_accepts(child, context, start, end, memo)
        False -> #(False, memo)
      }
    types.Labels(separator, minimum, maximum, total_maximum, _), [child] -> {
      let separator = codepoints(separator)
      let spans =
        span_labels(
          context,
          separator,
          list.length(separator),
          start,
          start,
          end,
          [],
        )
      let count = list.length(spans)
      case
        separator != []
        && count >= minimum
        && option.unwrap(
          option.map(maximum, fn(bound) { count <= bound }),
          True,
        )
        && option.unwrap(
          option.map(total_maximum, fn(bound) { end - start <= bound }),
          True,
        )
      {
        True ->
          format_span_short_circuit(
            False,
            fn(span: #(Int, Int), memo) {
              span_accepts(child, context, span.0, span.1, memo)
            },
            spans,
            memo,
          )
        False -> #(False, memo)
      }
    }
    types.Text, [] -> #(True, memo)
    _, _ -> #(recognizes_leaf(rule, span_text(context, start, end)), memo)
  }
}

fn recognizes_leaf(rule: types.FormatRule, text: String) -> Bool {
  case rule {
    types.Literal(value) -> value == text
    types.Identifier(first, rest, exact, minimum, maximum, forbidden) -> {
      let codepoints = codepoints(text)
      let length = list.length(codepoints)
      length >= minimum
      && option.unwrap(option.map(maximum, fn(upper) { length <= upper }), True)
      && option.unwrap(
        option.map(exact, fn(expected) { expected == length }),
        True,
      )
      && !list.contains(forbidden, text)
      && case codepoints {
        [head, ..tail] -> {
          let rest = ascii_set(rest)
          ascii_member(ascii_set(first), head)
          && list.all(tail, ascii_member(rest, _))
        }
        [] -> False
      }
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

fn format_length(
  grapheme_rules: Option(types.GraphemeRules),
  unit: types.StringLengthUnit,
  text: String,
) -> Option(Int) {
  case unit {
    types.Utf8Bytes -> Some(string.byte_size(text))
    types.UnicodeScalars -> Some(list.length(string.to_utf_codepoints(text)))
    types.Graphemes ->
      option.map(grapheme_rules, fn(rules) { grapheme_count(rules, text) })
  }
}

fn format_within(
  grapheme_rules: Option(types.GraphemeRules),
  unit: types.StringLengthUnit,
  maximum: Int,
  text: String,
) -> Bool {
  option.unwrap(
    option.map(format_length(grapheme_rules, unit, text), fn(length) {
      length <= maximum
    }),
    False,
  )
}

fn ascii_alphanumeric(text: String) -> Bool {
  all_chars(ascii_alnum, text)
}

fn nonempty_chars(predicate: fn(Int) -> Bool, text: String) -> Bool {
  text != "" && all_chars(predicate, text)
}

fn all_chars(predicate: fn(Int) -> Bool, text: String) -> Bool {
  list.all(codepoints(text), predicate)
}

fn codepoints(text: String) -> List(Int) {
  list.map(string.to_utf_codepoints(text), string.utf_codepoint_to_int)
}

fn in_set(set: String, codepoint: Int) -> Bool {
  list.contains(codepoints(set), codepoint)
}

fn ascii_alnum(codepoint: Int) -> Bool {
  ascii_alpha(codepoint) || ascii_digit(codepoint)
}

fn ascii_alpha(codepoint: Int) -> Bool {
  { codepoint >= 65 && codepoint <= 90 }
  || { codepoint >= 97 && codepoint <= 122 }
}

fn ascii_digit(codepoint: Int) -> Bool {
  codepoint >= 48 && codepoint <= 57
}

fn hex_digit(codepoint: Int) -> Bool {
  ascii_digit(codepoint)
  || { codepoint >= 65 && codepoint <= 70 }
  || { codepoint >= 97 && codepoint <= 102 }
}

fn recognize_dfa(spec: types.DfaSpec, text: String) -> Bool {
  run_dfa(
    spec,
    dfa_transitions_by_state(spec.transitions),
    codepoints(text),
    spec.initial_state,
  )
}

fn run_dfa(
  spec: types.DfaSpec,
  transitions: Dict(Int, List(types.DfaTransition)),
  codepoints: List(Int),
  state: Int,
) -> Bool {
  case codepoints {
    [] -> list.contains(spec.accepting_states, state)
    [codepoint, ..rest] ->
      case dfa_step(transitions, state, codepoint) {
        Some(next) -> run_dfa(spec, transitions, rest, next)
        None -> False
      }
  }
}

fn absolute_uri(maximum: Option(Int), text: String) -> Bool {
  case
    option.map(maximum, fn(bound) { string.byte_size(text) <= bound })
    |> option.unwrap(True)
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
                Ok(#(_, fragment)) ->
                  uri_chars(codepoints(fragment), in_set("/?:@", _))
                Error(_) -> True
              }
              let hierarchy = case without_fragment {
                Ok(#(value, _)) -> value
                Error(_) -> rest
              }
              let without_query = string.split_once(hierarchy, "?")
              let query_valid = case without_query {
                Ok(#(_, query)) ->
                  uri_chars(codepoints(query), in_set("/?:@", _))
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
  case codepoints(scheme) {
    [first, ..rest] ->
      ascii_alpha(first)
      && list.all(rest, fn(codepoint) {
        ascii_alnum(codepoint) || in_set("+-.", codepoint)
      })
    _ -> False
  }
}

fn absolute_hierarchy(hierarchy: String) -> Bool {
  case string.starts_with(hierarchy, "//") {
    False -> uri_chars(codepoints(hierarchy), in_set("/:@", _))
    True ->
      case string.split(string.drop_start(hierarchy, 2), "/") {
        [authority, ..path] ->
          valid_authority(authority)
          && uri_chars(codepoints(string.join(path, "/")), in_set("/:@", _))
        _ -> False
      }
  }
}

fn valid_authority(authority: String) -> Bool {
  case string.split(authority, "@") {
    [host] -> valid_host_port(host)
    [userinfo, host] ->
      uri_chars(codepoints(userinfo), in_set(":", _)) && valid_host_port(host)
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
        [host] -> uri_chars(codepoints(host), fn(_) { False })
        [host, port] ->
          uri_chars(codepoints(host), fn(_) { False }) && valid_port(port)
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
      nonempty_chars(hex_digit, version)
      && nonempty_chars(
        fn(codepoint) {
          uri_unreserved(codepoint)
          || uri_subdelim(codepoint)
          || in_set(":", codepoint)
        },
        address,
      )
    _ -> False
  }
}

fn valid_ipv6(address: String) -> Bool {
  case string.split(address, "::") {
    [whole] ->
      case ipv6_group_count(string.split(whole, ":")) {
        Some(count) -> count == 8
        None -> False
      }
    [before, after] -> {
      let left = case before {
        "" -> Some(0)
        _ -> ipv6_group_count(string.split(before, ":"))
      }
      let right = case after {
        "" -> Some(0)
        _ -> ipv6_group_count(string.split(after, ":"))
      }
      case left, right {
        Some(left_count), Some(right_count) ->
          left_count + right_count < 8 && !string.contains(before, ".")
        _, _ -> False
      }
    }
    _ -> False
  }
}

fn ipv6_group_count(parts: List(String)) -> Option(Int) {
  case parts {
    [] -> Some(0)
    [last] ->
      case string.contains(last, ".") {
        True ->
          case valid_ipv4(last) {
            True -> Some(2)
            False -> None
          }
        False ->
          case
            last != "" && string.length(last) <= 4 && all_chars(hex_digit, last)
          {
            True -> Some(1)
            False -> None
          }
      }
    [part, ..rest] ->
      case
        part == "" || string.length(part) > 4 || !all_chars(hex_digit, part)
      {
        True -> None
        False -> option.map(ipv6_group_count(rest), fn(count) { count + 1 })
      }
  }
}

fn valid_ipv4(text: String) -> Bool {
  let octets = string.split(text, ".")
  list.length(octets) == 4
  && list.all(octets, fn(octet) {
    nonempty_chars(ascii_digit, octet)
    && string.length(octet) <= 3
    && case int.parse(octet) {
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
  port == "" || nonempty_chars(ascii_digit, port)
}

fn uri_chars(chars: List(Int), extra: fn(Int) -> Bool) -> Bool {
  case chars {
    [] -> True
    [37, first, second, ..rest] ->
      hex_digit(first) && hex_digit(second) && uri_chars(rest, extra)
    [37, ..] -> False
    [first, ..rest] ->
      { uri_unreserved(first) || uri_subdelim(first) || extra(first) }
      && uri_chars(rest, extra)
  }
}

fn uri_unreserved(codepoint: Int) -> Bool {
  ascii_alnum(codepoint) || in_set("-._~", codepoint)
}

fn uri_subdelim(codepoint: Int) -> Bool {
  in_set("!$&'()*+,;=", codepoint)
}

fn timestamp(rule: types.CalendarRule, text: String) -> Bool {
  let chars =
    list.map(string.to_utf_codepoints(text), fn(codepoint) {
      string.from_utf_codepoints([codepoint])
    })
  case timestamp_fields(chars) {
    None -> False
    Some(#(year, month, day, hour, minute, second, suffix)) -> {
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
      let timezone = case suffix {
        [".", ..rest] ->
          case
            list.take_while(rest, fn(char) { nonempty_chars(ascii_digit, char) })
          {
            [] -> []
            fraction -> list.drop(rest, list.length(fraction))
          }
        _ -> suffix
      }
      date_valid
      && timezone_valid(rule, year, month, day, hour, minute, timezone)
    }
  }
}

fn timestamp_fields(
  chars: List(String),
) -> Option(#(Int, Int, Int, Int, Int, Int, List(String))) {
  case chars {
    [
      y1,
      y2,
      y3,
      y4,
      "-",
      mo1,
      mo2,
      "-",
      d1,
      d2,
      "T",
      h1,
      h2,
      ":",
      mi1,
      mi2,
      ":",
      s1,
      s2,
      ..suffix
    ] -> {
      use year <- option.then(digits_nat([y1, y2, y3, y4]))
      use month <- option.then(digits_nat([mo1, mo2]))
      use day <- option.then(digits_nat([d1, d2]))
      use hour <- option.then(digits_nat([h1, h2]))
      use minute <- option.then(digits_nat([mi1, mi2]))
      use second <- option.then(digits_nat([s1, s2]))
      Some(#(year, month, day, hour, minute, second, suffix))
    }
    _ -> None
  }
}

fn digits_nat(chars: List(String)) -> Option(Int) {
  case
    chars != []
    && list.all(chars, fn(char) { nonempty_chars(ascii_digit, char) })
  {
    False -> None
    True -> option.from_result(int.parse(string.concat(chars)))
  }
}

fn timezone_valid(
  rule: types.CalendarRule,
  year: Int,
  month: Int,
  day: Int,
  hour: Int,
  minute: Int,
  timezone: List(String),
) -> Bool {
  case timezone {
    ["Z"] -> True
    [sign, h1, h2, ":", m1, m2] -> {
      let sign_valid = sign == "+" || sign == "-"
      case sign_valid, digits_nat([h1, h2]), digits_nat([m1, m2]) {
        True, Some(offset_hour), Some(offset_minute) ->
          offset_hour <= 23
          && offset_minute <= 59
          && !{ sign == "-" && offset_hour == 0 && offset_minute == 0 }
          && !{
            rule.reject_utc_year_outside_range
            && utc_year_outside_range(
              rule,
              string.concat(timezone),
              year,
              month,
              day,
              hour,
              minute,
            )
          }
        _, _, _ -> False
      }
    }
    _ -> False
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
  case
    list.all(
      list.map(string.to_utf_codepoints(text), string.utf_codepoint_to_int),
      fn(codepoint) { codepoint < 128 },
    )
  {
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
              string.length(part) == 4 && nonempty_chars(ascii_alpha, part)
            })
          let after_region = take_if(after_script, region_subtag)
          language_variants([], after_region)
        }
      }
    _ -> False
  }
}

fn take_extlangs(parts: List(String), left: Int) -> List(String) {
  case left, parts {
    0, _ -> parts
    _, [first, ..rest] ->
      case string.length(first) == 3 && nonempty_chars(ascii_alpha, first) {
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

fn region_subtag(part: String) -> Bool {
  case string.length(part) {
    2 -> nonempty_chars(ascii_alpha, part)
    3 -> nonempty_chars(ascii_digit, part)
    _ -> False
  }
}

fn language_variants(seen: List(String), parts: List(String)) -> Bool {
  case parts {
    [] -> True
    [part, ..rest] ->
      case variant(part) {
        True ->
          !list.contains(seen, part) && language_variants([part, ..seen], rest)
        False -> language_extensions([], parts)
      }
  }
}

fn language_extensions(seen: List(String), parts: List(String)) -> Bool {
  case parts {
    [] -> True
    ["x", ..private] ->
      private != [] && list.all(private, fn(part) { subtag(part, 1, 8, False) })
    [singleton, ..rest] ->
      case string.length(singleton) == 1 && ascii_alphanumeric(singleton) {
        False -> False
        True -> {
          let values = take_extension_subtags(rest)
          values != []
          && !list.contains(seen, singleton)
          && language_extensions(
            [singleton, ..seen],
            list.drop(rest, list.length(values)),
          )
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
        && ascii_alphanumeric(first)
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
    && nonempty_chars(
      ascii_digit,
      string.slice(from: text, at_index: 0, length: 1),
    )
    && ascii_alphanumeric(text)
  subtag(text, 5, 8, False) || numeric_variant
}

fn subtag(text: String, minimum: Int, maximum: Int, alpha_only: Bool) -> Bool {
  case string.length(text) >= minimum && string.length(text) <= maximum {
    False -> False
    True ->
      case alpha_only {
        True -> nonempty_chars(ascii_alpha, text)
        False -> ascii_alphanumeric(text)
      }
  }
}

fn parse_digits(text: String) -> Int {
  int.parse(text) |> result.unwrap(0)
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

fn ascii_text(text: String) -> Bool {
  list.all(string.to_utf_codepoints(text), fn(codepoint) {
    string.utf_codepoint_to_int(codepoint) < 128
  })
}

fn dfa_transitions_disjoint(transitions: List(types.DfaTransition)) -> Bool {
  case transitions {
    [] -> True
    [transition, ..rest] ->
      list.all(rest, fn(other) {
        transition.from_state != other.from_state
        || transition.last < other.first
        || other.last < transition.first
      })
      && dfa_transitions_disjoint(rest)
  }
}

pub fn format_rule_well_formed(rule: types.FormatRule) -> Bool {
  case rule {
    types.Sequence(rules) | types.Choice(rules) ->
      list.all(rules, format_rule_well_formed)
    types.Optional(inner) | types.Not(inner) -> format_rule_well_formed(inner)
    types.Labels(separator, _, _, _, inner) ->
      separator != "" && format_rule_well_formed(inner)
    types.Bounded(_, maximum, inner) ->
      maximum >= 0 && format_rule_well_formed(inner)
    types.Identifier(first, rest, exact, minimum, maximum, forbidden) ->
      first != ""
      && rest != ""
      && ascii_text(first)
      && ascii_text(rest)
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
      && list.all(spec.transitions, fn(transition) {
        transition.from_state >= 0
        && transition.from_state < spec.state_count
        && transition.to_state >= 0
        && transition.to_state < spec.state_count
        && transition.first >= 0
        && transition.first <= transition.last
        && transition.last < 128
      })
      && dfa_transitions_disjoint(spec.transitions)
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

pub opaque type CheckedProfile {
  CheckedProfile(profile: types.SemanticProfile)
}

fn profile_failure(
  profile: types.SemanticProfile,
) -> Option(types.ProfileFailure) {
  let fail = fn(predicate, location) {
    Some(types.ProfileFailure(profile.reference, predicate, location))
  }
  let formats = list.map(profile.format_bindings, fn(binding) { binding.name })
  let integer_names =
    list.map(profile.integer_domains, fn(binding) { binding.name })
  let wrapper_names = list.map(profile.wrappers, fn(wrapper) { wrapper.name })
  let wrapper_keys = list.map(profile.wrappers, fn(wrapper) { wrapper.key })
  use <- bool.guard(
    when: !nonempty_profile_ref(profile.reference)
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
    ),
    return: fail(types.Pr01, ["profile"]),
  )
  use <- bool.guard(
    when: !unique_nonempty(integer_names),
    return: fail(types.Pr02, ["integer_domains"]),
  )
  use <- bool.guard(
    when: list.any(profile.integer_domains, fn(binding) {
      !declared_range_valid(binding.range)
    }),
    return: fail(types.Pr03, ["integer_domains"]),
  )
  use <- bool.guard(
    when: list.any(profile.integer_domains, fn(binding) {
      list.is_empty(binding.forms)
    }),
    return: fail(types.Pr04, ["integer_domains"]),
  )
  use <- bool.guard(
    when: !list.contains(integer_names, profile.default_integer_domain),
    return: fail(types.Pr05, ["default_integer_domain"]),
  )
  use <- bool.guard(
    when: !unique_nonempty(formats),
    return: fail(types.Pr06, ["format_bindings"]),
  )
  use <- bool.guard(
    when: list.any(profile.format_bindings, fn(binding) {
      !format_rule_well_formed(binding.rule)
    }),
    return: fail(types.Pr07, ["format_bindings"]),
  )
  use <- bool.guard(
    when: !unique_nonempty(wrapper_names) || !unique_nonempty(wrapper_keys),
    return: fail(types.Pr08, ["wrappers"]),
  )
  use <- bool.guard(
    when: list.any(profile.wrappers, fn(wrapper) {
      case wrapper.payload {
        types.WrapperText(Some(format)) -> !list.contains(formats, format)
        _ -> False
      }
    }),
    return: fail(types.Pr09, ["wrappers"]),
  )
  use <- bool.guard(
    when: option.unwrap(
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
    return: fail(types.Pr10, ["bytes_policy", "wrapper"]),
  )
  let tag_failure = case profile.tag {
    None -> None
    Some(tag) -> {
      use <- bool.guard(
        when: tag.key == "" || list.contains(wrapper_keys, tag.key),
        return: fail(types.Pr11, ["tag", "key"]),
      )
      use <- bool.guard(
        when: option.unwrap(
          option.map(tag.format, fn(name) { !list.contains(formats, name) }),
          False,
        ),
        return: fail(types.Pr12, ["tag", "format"]),
      )
      use <- bool.guard(
        when: !unique_nonempty(list.map(tag.sealed, fn(form) { form.tag }))
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
                  !recognizes(profile.grapheme_rules, binding.rule, form.tag)
                })
            }
          }),
          False,
        ),
        return: fail(types.Pr13, ["tag", "sealed"]),
      )
      use <- bool.guard(
        when: list.any(tag.sealed, fn(form) {
          let keys = list.map(form.fields, fn(field) { field.key })
          !unique_nonempty(keys)
          || list.contains(keys, tag.key)
          || list.any(keys, fn(key) { list.contains(wrapper_keys, key) })
        }),
        return: fail(types.Pr14, ["tag", "sealed", "fields"]),
      )
      use <- bool.guard(
        when: list.any(tag.sealed, fn(form) {
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
                      types.NamedFormat(name) -> !list.contains(formats, name)
                      types.InlineFormat(rule) -> !format_rule_well_formed(rule)
                    }
                  }),
                  False,
                )
                || list.any(spec.lengths, fn(bound) {
                  !profile_length_valid(bound)
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
        return: fail(types.Pr15, ["tag", "sealed", "fields"]),
      )
      None
    }
  }
  option.lazy_or(tag_failure, fn() {
    use <- bool.guard(
      when: option.unwrap(
        option.map(profile.grapheme_rules, fn(rules) {
          list.any(rules.properties, fn(range) { range.last < range.first })
          || list.any(rules.extended_pictographic, fn(range) {
            range.last < range.first
          })
          || list.any(rules.indic_conjunct, fn(range) {
            range.last < range.first
          })
        }),
        False,
      ),
      return: fail(types.Pr16, ["grapheme_rules"]),
    )
    None
  })
}

fn profile_length_valid(bound: types.LengthBound) -> Bool {
  case bound.minimum, bound.maximum {
    Some(minimum), Some(maximum) -> minimum <= maximum
    _, _ -> True
  }
}

pub fn check_profile(
  profile: types.SemanticProfile,
) -> Result(CheckedProfile, types.ProfileFailure) {
  case profile_failure(profile) {
    Some(failure) -> Error(failure)
    None -> Ok(CheckedProfile(profile))
  }
}

fn declared_type_children(shape: types.TypeShape) -> List(types.TypeRef) {
  case shape {
    types.ProductShape(spec) -> {
      let fields = list.map(spec.fields, fn(field) { field.slot.type_ref })
      list.append(fields, extra_children(spec.extras))
    }
    types.ArrayShape(spec) -> [spec.item.type_ref]
    types.AliasShape(target, _) -> [target]
    types.TaggedUnionShape(spec) ->
      list.map(spec.branches, fn(branch) { branch.target })
    _ -> []
  }
}

fn extra_children(extras: types.ExtraMembers) -> List(types.TypeRef) {
  case extras {
    types.RejectExtras -> []
    types.AllowExtras(_, value) -> [value.type_ref]
  }
}

fn format_rule_uses_graphemes(rule: types.FormatRule) -> Bool {
  case rule {
    types.Bounded(types.Graphemes, _, _) -> True
    types.Bounded(_, _, child) -> format_rule_uses_graphemes(child)
    types.Sequence(rules) | types.Choice(rules) ->
      format_rules_use_graphemes(rules)
    types.Optional(child)
    | types.Not(child)
    | types.Labels(_, _, _, _, child) -> format_rule_uses_graphemes(child)
    _ -> False
  }
}

fn format_rules_use_graphemes(rules: List(types.FormatRule)) -> Bool {
  list.any(rules, format_rule_uses_graphemes)
}

fn format_use_uses_graphemes(
  profile: types.SemanticProfile,
  format: Option(types.FormatUse),
) -> Bool {
  case format {
    None -> False
    Some(types.InlineFormat(rule)) -> format_rule_uses_graphemes(rule)
    Some(types.NamedFormat(name)) ->
      case
        list.find(profile.format_bindings, fn(binding) { binding.name == name })
      {
        Ok(binding) -> format_rule_uses_graphemes(binding.rule)
        Error(_) -> False
      }
  }
}

pub fn node_meaning_obligations(
  graph: types.SemanticGraph,
  reference: types.TypeRef,
) -> List(types.SemanticObligation) {
  declared_meaning_obligations(graph, reference, find_type(graph, reference))
}

fn declared_meaning_obligations(
  graph: types.SemanticGraph,
  reference: types.TypeRef,
  declared: Option(types.TypeNode),
) -> List(types.SemanticObligation) {
  let obligation = fn(reason) { obligation_at(graph, reference, [], reason) }
  case declared {
    None -> [obligation(types.UnresolvedTypeReason)]
    Some(node) ->
      case node.shape {
        types.StringShape(spec) -> {
          let grapheme = case
            list.any(spec.lengths, fn(bound) { bound.unit == types.Graphemes })
            || format_use_uses_graphemes(graph.profile, spec.format),
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
          case integer_binding(graph.profile, spec.domain) {
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
  graph: PreparedGraph,
  fuel: Int,
  pending: List(types.TypeRef),
  seen: List(types.TypeRef),
  visited: Dict(types.TypeRef, Nil),
) -> List(types.TypeRef) {
  case fuel <= 0, pending {
    True, _ | _, [] -> seen
    False, [reference, ..rest] ->
      case dict.has_key(visited, reference) {
        True -> declared_reachable_types(graph, fuel - 1, rest, seen, visited)
        False -> {
          let children = case indexed_type(graph, reference) {
            Some(node) -> declared_type_children(node.shape)
            None -> []
          }
          declared_reachable_types(
            graph,
            fuel - 1,
            list.append(children, rest),
            [reference, ..seen],
            dict.insert(visited, reference, Nil),
          )
        }
      }
  }
}

pub fn meaning_obligations(
  indexed: PreparedGraph,
  references: List(types.TypeRef),
) -> List(types.SemanticObligation) {
  case
    list.all(references, fn(reference) {
      dict.has_key(indexed.obligation_free, reference)
    })
  {
    True -> []
    False -> computed_meaning_obligations(indexed, references)
  }
}

fn computed_meaning_obligations(
  indexed: PreparedGraph,
  references: List(types.TypeRef),
) -> List(types.SemanticObligation) {
  declared_reachable_types(
    indexed,
    list.length(references) + indexed.node_count + indexed.edge_count + 1,
    references,
    [],
    dict.new(),
  )
  |> list.flat_map(fn(reference) {
    declared_meaning_obligations(
      indexed.graph,
      reference,
      indexed_type(indexed, reference),
    )
  })
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
    types.UnresolvedTypeReason -> Some(types.Mo12)
    types.MembershipBoundReason
    | types.UninterpretedExtensionReason(_)
    | types.InvalidProfileReason(_)
    | types.CertificateMismatchReason(_)
    | types.ProjectionUnavailableReason(_) -> None
  }
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
            obligation.value_path,
          ))
        None -> first_meaning_failure(rest)
      }
  }
}

pub fn check_meaning_defined(
  graph: PreparedGraph,
  references: List(types.TypeRef),
) -> Result(Nil, types.MeaningFailure) {
  case first_meaning_failure(meaning_obligations(graph, references)) {
    Some(failure) -> Error(failure)
    None -> Ok(Nil)
  }
}

type DataFailure =
  #(types.ValuePath, types.ValueCondition, kdl.JsonValue)

fn member_value(
  key: String,
  members: List(#(String, kdl.JsonValue)),
) -> Option(kdl.JsonValue) {
  option.from_result(list.key_find(members, key))
}

fn failure_at(
  reference: types.TypeRef,
  path: types.ValuePath,
  value: types.SlotValue(kdl.JsonValue),
  condition: types.ValueCondition,
  trace: List(types.TypeRef),
) -> types.ValueFailure {
  types.ValueFailure(
    reference,
    types.DefinitionRef(reference.source, reference.definition_name),
    types.occurrence(reference),
    path,
    condition,
    case condition {
      types.MissingRequiredCondition -> types.Absent
      _ -> value
    },
    trace,
  )
}

fn obligation_at(
  graph: types.SemanticGraph,
  reference: types.TypeRef,
  path: types.ValuePath,
  reason: types.SemanticReason,
) -> types.SemanticObligation {
  types.SemanticObligation(
    reference,
    path,
    reason,
    types.occurrence(reference),
    graph.profile.reference,
  )
}

pub fn unicode_valid(text: String) -> Bool {
  list.all(string.to_utf_codepoints(text), fn(codepoint) {
    let value = string.utf_codepoint_to_int(codepoint)
    value <= 1_114_111 && !{ 55_296 <= value && value <= 57_343 }
  })
}

fn ascii_whitespace(codepoint: Int) -> Bool {
  codepoint == 32 || codepoint == 9 || codepoint == 13 || codepoint == 10
}

fn integer_power(base: Int, exponent: Int) -> Int {
  case exponent <= 0 {
    True -> 1
    False -> {
      let half = integer_power(base, exponent / 2)
      case exponent % 2 {
        0 -> half * half
        _ -> half * half * base
      }
    }
  }
}

fn json_digit(codepoint: Int) -> Bool {
  48 <= codepoint && codepoint <= 57
}

fn take_json_digits(chars: List(Int)) -> #(Int, Int, List(Int)) {
  let #(digits, count, rest) = take_json_digits_from(chars, [], 0)
  let value = case count {
    0 -> 0
    _ -> {
      let assert Ok(value) =
        list.reverse(digits)
        |> bit_array.concat
        |> bit_array.to_string
        |> result.try(int.parse)
      value
    }
  }
  #(value, count, rest)
}

fn take_json_digits_from(
  chars: List(Int),
  digits: List(BitArray),
  count: Int,
) -> #(List(BitArray), Int, List(Int)) {
  case chars {
    [digit, ..rest] ->
      case json_digit(digit) {
        True -> take_json_digits_from(rest, [<<digit>>, ..digits], count + 1)
        False -> #(digits, count, chars)
      }
    [] -> #(digits, count, [])
  }
}

fn drop_json_whitespace(chars: List(Int)) -> List(Int) {
  case chars {
    [first, ..rest] ->
      case ascii_whitespace(first) {
        True -> drop_json_whitespace(rest)
        False -> chars
      }
    [] -> []
  }
}

const usize_size = 18_446_744_073_709_551_616

fn parse_json_number(text: String) -> Option(#(Int, Int, Int)) {
  use <- bool.guard(
    when: option.is_some(kdl.admission_failure(text)),
    return: None,
  )
  let chars =
    drop_json_whitespace(list.map(
      string.to_utf_codepoints(text),
      string.utf_codepoint_to_int,
    ))
  let #(sign, chars) = case chars {
    [45, ..rest] -> #(-1, rest)
    _ -> #(1, chars)
  }
  let whole = case chars {
    [48, ..rest] -> Some(#(0, rest))
    [first, ..] ->
      case 49 <= first && first <= 57 {
        True -> {
          let #(value, _, rest) = take_json_digits(chars)
          Some(#(value, rest))
        }
        False -> None
      }
    [] -> None
  }
  use #(whole, chars) <- option.then(whole)
  let decimals = case chars {
    [46, first, ..] ->
      case json_digit(first) {
        True -> {
          let #(fraction, count, rest) = take_json_digits(list.drop(chars, 1))
          case count > usize_size {
            True -> None
            False ->
              Some(#(
                sign * { whole * integer_power(10, count) + fraction },
                count,
                rest,
              ))
          }
        }
        False -> None
      }
    [46, ..] -> None
    _ -> Some(#(sign * whole, 0, chars))
  }
  use #(mantissa, exponent, chars) <- option.then(decimals)
  let shifted = case chars {
    [101, ..rest] | [69, ..rest] ->
      case rest {
        [45, first, ..] ->
          case json_digit(first) {
            True -> {
              let #(shift, _, remaining) = take_json_digits(list.drop(rest, 1))
              Some(#(#(mantissa, 0, exponent + shift), remaining))
            }
            False -> None
          }
        _ -> {
          let digits = case rest {
            [43, ..after] -> after
            _ -> rest
          }
          case digits {
            [first, ..] ->
              case json_digit(first) {
                True -> {
                  let #(shift, _, remaining) = take_json_digits(digits)
                  Some(#(
                    #(
                      mantissa,
                      int.max(shift - exponent, 0),
                      int.max(exponent - shift, 0),
                    ),
                    remaining,
                  ))
                }
                False -> None
              }
            [] -> None
          }
        }
      }
    _ -> Some(#(#(mantissa, 0, exponent), chars))
  }
  use #(number, chars) <- option.then(shifted)
  case drop_json_whitespace(chars) {
    [] -> Some(number)
    _ -> None
  }
}

fn normalize_json_number(number: #(Int, Int, Int)) -> #(Int, Int, Int) {
  let #(mantissa, zeroes, exponent) = number
  case mantissa == 0 {
    True -> #(0, 0, 0)
    False -> {
      let sign = case mantissa > 0 {
        True -> 1
        False -> -1
      }
      let magnitude = int.absolute_value(mantissa)
      #(
        sign,
        strip_trailing_zeroes(magnitude),
        string.length(int.to_string(magnitude)) + zeroes - exponent,
      )
    }
  }
}

fn strip_trailing_zeroes(magnitude: Int) -> Int {
  case magnitude % 10 == 0 {
    True -> strip_trailing_zeroes(magnitude / 10)
    False -> magnitude
  }
}

fn decimal_integer_parts(text: String) -> Option(#(Int, Int, Int)) {
  let chars =
    list.map(string.to_utf_codepoints(text), string.utf_codepoint_to_int)
  let trimmed_differs = case chars, list.last(chars) {
    [first, ..], Ok(last) -> ascii_whitespace(first) || ascii_whitespace(last)
    _, _ -> False
  }
  case trimmed_differs || string.starts_with(text, "+") {
    True -> None
    False ->
      case parse_json_number(text) {
        None -> None
        Some(number) -> {
          let #(sign, digits, power) = normalize_json_number(number)
          case digits == 0 || power >= string.length(int.to_string(digits)) {
            True -> Some(#(sign, digits, power))
            False -> None
          }
        }
      }
  }
}

fn decimal_integer(text: String) -> Option(Int) {
  use #(sign, digits, power) <- option.then(decimal_integer_parts(text))
  let shift = power - string.length(int.to_string(digits))
  let magnitude = case digits == 0 {
    True -> 0
    False -> digits * integer_power(10, shift)
  }
  Some(sign * magnitude)
}

fn integer_value_for_form(
  form: types.IntegerForm,
  value: kdl.JsonValue,
) -> Option(Int) {
  case form, value {
    types.Number, kdl.JsonValueNum(integer) -> Some(integer)
    types.IntegralDecimal, kdl.JsonValueDec(text) -> decimal_integer(text)
    types.DecimalString, kdl.JsonValueStr(text) -> decimal_integer(text)
    _, _ -> None
  }
}

pub fn integer_binding(
  profile: types.SemanticProfile,
  domain: Option(String),
) -> Option(types.IntegerDomainBinding) {
  let name = option.unwrap(domain, profile.default_integer_domain)
  option.from_result(
    list.find(profile.integer_domains, fn(binding) { binding.name == name }),
  )
}

fn integer_value_for_binding(
  binding: types.IntegerDomainBinding,
  value: kdl.JsonValue,
) -> Option(Int) {
  option.from_result(
    list.find_map(binding.forms, fn(form) {
      option.to_result({ integer_value_for_form(form, value) }, Nil)
    }),
  )
}

/// The integer of a value under the integer domain, as Lean's `integerValueForDomain` reads it after validation.
pub fn integer_value_for_domain(
  prepared: PreparedGraph,
  domain: Option(String),
  value: kdl.JsonValue,
) -> Option(Int) {
  let name =
    option.unwrap(domain, prepared.graph.profile.default_integer_domain)
  case dict.get(prepared.integer_domains, name) {
    Error(_) -> None
    Ok(binding) -> integer_value_for_binding(binding, value)
  }
}

fn integer_range_accepts(range: types.IntegerDomain, value: Int) -> Bool {
  case range {
    types.Unbounded -> True
    types.IntegerInterval(minimum, maximum) ->
      minimum <= value && value <= maximum
  }
}

fn json_whole_number(characters: List(Int)) -> Bool {
  case characters {
    [] -> False
    [48, ..rest] -> rest == []
    [first, ..rest] -> 49 <= first && first <= 57 && list.all(rest, json_digit)
  }
}

fn decimal_magnitude_exceeds_range_digits(
  minimum: Int,
  maximum: Int,
  text: String,
) -> Bool {
  let unsigned = case string.starts_with(text, "-") {
    True -> string.drop_start(text, 1)
    False -> text
  }
  case string.starts_with(unsigned, "+") {
    True -> False
    False -> {
      let lowercase_parts = string.split(unsigned, "e")
      let parts = case list.length(lowercase_parts) == 2 {
        True -> lowercase_parts
        False -> string.split(unsigned, "E")
      }
      case parts {
        [base, exponent_text] -> {
          let exponent_digits = case string.starts_with(exponent_text, "+") {
            True -> string.drop_start(exponent_text, 1)
            False -> exponent_text
          }
          let exponent_chars =
            list.map(
              string.to_utf_codepoints(exponent_digits),
              string.utf_codepoint_to_int,
            )
          case
            string.starts_with(exponent_digits, "-")
            || exponent_chars == []
            || !list.all(exponent_chars, json_digit)
          {
            True -> False
            False ->
              case int.parse(exponent_digits) {
                Error(_) -> False
                Ok(exponent) -> {
                  let limit =
                    int.max(
                      int.absolute_value(minimum),
                      int.absolute_value(maximum),
                    )
                  case string.split(base, ".") {
                    [whole] ->
                      case
                        json_whole_number(list.map(
                          string.to_utf_codepoints(whole),
                          string.utf_codepoint_to_int,
                        ))
                      {
                        False -> False
                        True -> {
                          let significant =
                            list.length(
                              list.drop_while(
                                list.map(
                                  string.to_utf_codepoints(whole),
                                  string.utf_codepoint_to_int,
                                ),
                                fn(character) { character == 48 },
                              ),
                            )
                          significant != 0
                          && significant + exponent
                          > string.length(int.to_string(limit))
                        }
                      }
                    [whole, fraction] -> {
                      let fraction_chars =
                        list.map(
                          string.to_utf_codepoints(fraction),
                          string.utf_codepoint_to_int,
                        )
                      case
                        !json_whole_number(list.map(
                          string.to_utf_codepoints(whole),
                          string.utf_codepoint_to_int,
                        ))
                        || fraction_chars == []
                        || !list.all(fraction_chars, json_digit)
                        || exponent < list.length(fraction_chars)
                      {
                        True -> False
                        False -> {
                          let significant =
                            list.length(
                              list.drop_while(
                                list.append(
                                  list.map(
                                    string.to_utf_codepoints(whole),
                                    string.utf_codepoint_to_int,
                                  ),
                                  fraction_chars,
                                ),
                                fn(character) { character == 48 },
                              ),
                            )
                          significant != 0
                          && significant
                          + exponent
                          - list.length(fraction_chars)
                          > string.length(int.to_string(limit))
                        }
                      }
                    }
                    _ -> False
                  }
                }
              }
          }
        }
        _ -> False
      }
    }
  }
}

fn integer_value_for_binding_in_range(
  binding: types.IntegerDomainBinding,
  value: kdl.JsonValue,
) -> Option(Option(Int)) {
  case binding.range {
    types.Unbounded ->
      option.map(integer_value_for_binding(binding, value), Some)
    types.IntegerInterval(minimum, maximum) -> {
      let exceeds_range_digits = case value {
        kdl.JsonValueDec(text) ->
          list.contains(binding.forms, types.IntegralDecimal)
          && decimal_magnitude_exceeds_range_digits(minimum, maximum, text)
        kdl.JsonValueStr(text) ->
          list.contains(binding.forms, types.DecimalString)
          && decimal_magnitude_exceeds_range_digits(minimum, maximum, text)
        _ -> False
      }
      case exceeds_range_digits {
        True -> Some(None)
        False ->
          case integer_value_for_binding(binding, value) {
            None -> None
            Some(integer) ->
              case integer_range_accepts(binding.range, integer) {
                True -> Some(Some(integer))
                False -> Some(None)
              }
          }
      }
    }
  }
}

fn integer_in_domain(
  profile: types.SemanticProfile,
  domain: Option(String),
  value: kdl.JsonValue,
) -> Bool {
  case integer_binding(profile, domain) {
    None -> False
    Some(binding) ->
      case integer_value_for_binding_in_range(binding, value) {
        Some(Some(_)) -> True
        _ -> False
      }
  }
}

pub fn integer_condition(
  profile: types.SemanticProfile,
  spec: types.IntegerSpec,
  value: kdl.JsonValue,
) -> Option(types.ValueCondition) {
  case integer_binding(profile, spec.domain) {
    None -> Some(types.IntegerDomainCondition)
    Some(binding) ->
      case integer_value_for_binding_in_range(binding, value) {
        None -> Some(types.WrongValueKindCondition("integer"))
        Some(None) -> Some(types.IntegerDomainCondition)
        Some(Some(integer)) ->
          bool.guard(
            when: option.unwrap(
              option.map(spec.const_value, fn(expected) { expected != integer }),
              False,
            ),
            return: Some(types.ConstMismatchCondition),
            otherwise: fn() { None },
          )
          |> option.lazy_or(fn() {
            bool.guard(
              when: option.unwrap(
                option.map(spec.enum_values, fn(values) {
                  !list.contains(values, integer)
                }),
                False,
              ),
              return: Some(types.EnumMismatchCondition),
              otherwise: fn() { None },
            )
          })
          |> option.lazy_or(fn() {
            bool.guard(
              when: option.unwrap(
                option.map(spec.minimum, fn(minimum) { integer < minimum }),
                False,
              ),
              return: Some(types.BelowMinimumCondition),
              otherwise: fn() { None },
            )
          })
          |> option.lazy_or(fn() {
            bool.guard(
              when: option.unwrap(
                option.map(spec.maximum, fn(maximum) { maximum < integer }),
                False,
              ),
              return: Some(types.AboveMaximumCondition),
              otherwise: fn() { None },
            )
          })
      }
  }
}

fn length_accepts(
  minimum: Option(Int),
  maximum: Option(Int),
  length: Int,
) -> Bool {
  option.unwrap(option.map(minimum, fn(bound) { bound <= length }), True)
  && option.unwrap(option.map(maximum, fn(bound) { length <= bound }), True)
}

fn length_in_unit(
  tables: Tables,
  unit: types.StringLengthUnit,
  value: String,
) -> Option(Int) {
  case unit {
    types.Utf8Bytes -> Some(string.byte_size(value))
    types.UnicodeScalars -> Some(list.length(string.to_utf_codepoints(value)))
    types.Graphemes -> tables_grapheme_count(tables, value)
  }
}

fn length_bounds_failure(
  tables: Tables,
  value: String,
  bounds: List(types.LengthBound),
) -> Option(types.ValueCondition) {
  case bounds {
    [] -> None
    [bound, ..rest] ->
      case length_in_unit(tables, bound.unit, value) {
        None -> Some(types.StringLengthCondition)
        Some(length) ->
          case length_accepts(bound.minimum, bound.maximum, length) {
            True -> length_bounds_failure(tables, value, rest)
            False -> Some(types.StringLengthCondition)
          }
      }
  }
}

fn duplicate_key(members: List(#(String, kdl.JsonValue))) -> Option(String) {
  first_repeated(dict.new(), members)
}

fn first_repeated(
  seen: Dict(String, Nil),
  members: List(#(String, kdl.JsonValue)),
) -> Option(String) {
  case members {
    [] -> None
    [#(key, _), ..rest] ->
      case dict.has_key(seen, key) {
        True -> Some(key)
        False -> first_repeated(dict.insert(seen, key, Nil), rest)
      }
  }
}

pub fn class_of(
  profile: types.SemanticProfile,
  members: List(#(String, kdl.JsonValue)),
) -> types.ObjectClass {
  let wrapper_class = fn() {
    case
      list.find(profile.wrappers, fn(wrapper) {
        option.is_some(member_value(wrapper.key, members))
      })
    {
      Ok(wrapper) -> types.WrapperObject(wrapper)
      Error(_) -> types.OrdinaryObjectClass
    }
  }
  case profile.tag {
    Some(tag) ->
      case member_value(tag.key, members) {
        Some(kdl.JsonValueStr(value)) ->
          case list.find(tag.sealed, fn(form) { form.tag == value }) {
            Ok(form) -> types.SealedObject(form)
            Error(_) -> wrapper_class()
          }
        _ -> wrapper_class()
      }
    None -> wrapper_class()
  }
}

fn named_format_accepts(tables: Tables, name: String, value: String) -> Bool {
  case tables_named_format(tables, name) {
    Some(accepts) -> accepts(value)
    None -> False
  }
}

fn format_use_accepts_with(
  tables: Tables,
  format_use: types.FormatUse,
  text: String,
) -> Bool {
  case format_use {
    types.NamedFormat(name) -> named_format_accepts(tables, name, text)
    types.InlineFormat(rule) -> tables_inline_format(tables, rule)(text)
  }
}

fn wrapper_payload_text_with(
  tables: Tables,
  wrapper: types.Wrapper,
  value: kdl.JsonValue,
) -> Option(String) {
  case value {
    kdl.JsonValueObj([#(key, kdl.JsonValueStr(text))]) ->
      case key != wrapper.key {
        True -> None
        False ->
          case wrapper.payload {
            types.WrapperBytes ->
              case tables.profile.bytes_policy {
                None -> None
                Some(policy) ->
                  case base64.length(policy, text) {
                    Some(_) -> Some(text)
                    None -> None
                  }
              }
            types.WrapperText(None) ->
              case unicode_valid(text) {
                True -> Some(text)
                False -> None
              }
            types.WrapperText(Some(format)) ->
              case
                unicode_valid(text)
                && named_format_accepts(tables, format, text)
              {
                True -> Some(text)
                False -> None
              }
          }
      }
    _ -> None
  }
}

pub fn text_wrapper(profile: types.SemanticProfile) -> Option(types.Wrapper) {
  option.from_result(
    list.find(profile.wrappers, fn(wrapper) {
      case wrapper.payload {
        types.WrapperText(_) -> True
        types.WrapperBytes -> False
      }
    }),
  )
}

fn wrapper_text_accepts_with(tables: Tables, value: kdl.JsonValue) -> Bool {
  case text_wrapper(tables.profile) {
    Some(wrapper) ->
      option.is_some(wrapper_payload_text_with(tables, wrapper, value))
    None -> False
  }
}

fn wrapper_payload_failure(
  tables: Tables,
  wrapper: types.Wrapper,
  value: kdl.JsonValue,
) -> Option(types.ValueCondition) {
  case wrapper_payload_text_with(tables, wrapper, value) {
    Some(_) -> None
    None ->
      case wrapper.payload {
        types.WrapperBytes -> Some(types.InvalidBytesCondition)
        types.WrapperText(None) ->
          Some(types.WrongValueKindCondition("wrapper text"))
        types.WrapperText(Some(format)) ->
          Some(types.FormatFailureCondition(format))
      }
  }
}

fn string_format_failure(
  tables: Tables,
  spec: types.StringSpec,
  value: String,
  unknown_named_fails: Bool,
) -> Option(types.ValueCondition) {
  case spec.format {
    None -> None
    Some(types.NamedFormat(name)) ->
      case tables_named_format(tables, name) {
        None ->
          bool.guard(
            when: unknown_named_fails,
            return: Some(types.FormatFailureCondition(name)),
            otherwise: fn() { None },
          )
        Some(accepts) ->
          bool.guard(
            when: !accepts(value),
            return: Some(types.FormatFailureCondition(name)),
            otherwise: fn() { None },
          )
      }
    Some(types.InlineFormat(rule)) ->
      bool.guard(
        when: !tables_inline_format(tables, rule)(value),
        return: Some(types.FormatFailureCondition("inline")),
        otherwise: fn() { None },
      )
  }
}

fn string_leaf_condition(
  tables: Tables,
  spec: types.StringSpec,
  value: String,
  unknown_named_fails: Bool,
) -> Option(types.ValueCondition) {
  bool.guard(
    when: !unicode_valid(value),
    return: Some(types.InvalidDataModelCondition),
    otherwise: fn() { None },
  )
  |> option.lazy_or(fn() {
    bool.guard(
      when: option.unwrap(
        option.map(spec.const_value, fn(expected) { expected != value }),
        False,
      ),
      return: Some(types.ConstMismatchCondition),
      otherwise: fn() { None },
    )
  })
  |> option.lazy_or(fn() {
    bool.guard(
      when: option.unwrap(
        option.map(spec.enum_values, fn(values) {
          !list.contains(values, value)
        }),
        False,
      ),
      return: Some(types.EnumMismatchCondition),
      otherwise: fn() { None },
    )
  })
  |> option.lazy_or(fn() { length_bounds_failure(tables, value, spec.lengths) })
  |> option.lazy_or(fn() {
    string_format_failure(tables, spec, value, unknown_named_fails)
  })
}

fn string_condition_with(
  tables: Tables,
  spec: types.StringSpec,
  value: String,
) -> Option(types.ValueCondition) {
  string_leaf_condition(tables, spec, value, False)
}

fn sealed_string_condition(
  tables: Tables,
  spec: types.StringSpec,
  value: String,
) -> Option(types.ValueCondition) {
  string_leaf_condition(tables, spec, value, True)
}

fn sealed_integer_condition(
  profile: types.SemanticProfile,
  spec: types.IntegerSpec,
  value: Int,
) -> Option(types.ValueCondition) {
  integer_condition(profile, spec, kdl.JsonValueNum(value))
}

fn sealed_leaf_failure(
  tables: Tables,
  leaf: types.SealedLeaf,
  value: kdl.JsonValue,
) -> Option(types.ValueCondition) {
  case leaf, value {
    types.SealedString(spec), kdl.JsonValueStr(text) ->
      sealed_string_condition(tables, spec, text)
    types.SealedString(spec), kdl.JsonValueObj(members) ->
      case class_of(tables.profile, members) {
        types.WrapperObject(wrapper) ->
          case wrapper_payload_text_with(tables, wrapper, value) {
            Some(text) -> sealed_string_condition(tables, spec, text)
            None -> wrapper_payload_failure(tables, wrapper, value)
          }
        _ -> Some(types.WrongValueKindCondition("string"))
      }
    types.SealedString(_), _ -> Some(types.WrongValueKindCondition("string"))
    types.SealedInteger(spec), kdl.JsonValueNum(integer) ->
      sealed_integer_condition(tables.profile, spec, integer)
    types.SealedInteger(_), _ -> Some(types.WrongValueKindCondition("integer"))
  }
}

fn tag_value_accepts_with(
  tables: Tables,
  members: List(#(String, kdl.JsonValue)),
) -> Bool {
  option.is_none(tag_member_failure(tables, members))
}

fn tag_member_failure(
  tables: Tables,
  members: List(#(String, kdl.JsonValue)),
) -> Option(#(String, types.ValueCondition, kdl.JsonValue)) {
  case tables.profile.tag {
    None -> None
    Some(tag) ->
      case member_value(tag.key, members) {
        None -> None
        Some(kdl.JsonValueStr(text) as value) ->
          case !unicode_valid(text) {
            True -> Some(#(tag.key, types.InvalidDataModelCondition, value))
            False ->
              case tag.format {
                None -> None
                Some(format) ->
                  case named_format_accepts(tables, format, text) {
                    True -> None
                    False -> Some(#(tag.key, types.InvalidTagCondition, value))
                  }
              }
          }
        Some(value) -> Some(#(tag.key, types.InvalidTagCondition, value))
      }
  }
}

fn string_value_condition(
  tables: Tables,
  spec: types.StringSpec,
  value: kdl.JsonValue,
) -> Option(types.ValueCondition) {
  case spec.wrapper {
    None ->
      case value {
        kdl.JsonValueStr(text) -> string_condition_with(tables, spec, text)
        _ -> Some(types.WrongValueKindCondition("string"))
      }
    Some(name) ->
      case value {
        kdl.JsonValueObj(members) ->
          case class_of(tables.profile, members) {
            types.WrapperObject(wrapper) ->
              case wrapper.name != name {
                True -> Some(types.WrongValueKindCondition("string wrapper"))
                False ->
                  case wrapper_payload_text_with(tables, wrapper, value) {
                    Some(text) -> string_condition_with(tables, spec, text)
                    None -> wrapper_payload_failure(tables, wrapper, value)
                  }
              }
            _ -> Some(types.WrongValueKindCondition("string wrapper"))
          }
        _ -> Some(types.WrongValueKindCondition("string wrapper"))
      }
  }
}

fn bytes_value_length(tables: Tables, value: kdl.JsonValue) -> Option(Int) {
  use policy <- option.then(tables.profile.bytes_policy)
  use text <- option.then(case policy.wrapper {
    None ->
      case value {
        kdl.JsonValueStr(text) -> Some(text)
        _ -> None
      }
    Some(name) ->
      case
        list.find(tables.profile.wrappers, fn(wrapper) { wrapper.name == name })
      {
        Ok(wrapper) -> wrapper_payload_text_with(tables, wrapper, value)
        Error(_) -> None
      }
  })
  base64.length(policy, text)
}

fn sealed_field_failure(
  tables: Tables,
  members: List(#(String, kdl.JsonValue)),
  field: types.SealedField,
) -> Option(#(String, types.ValueCondition, kdl.JsonValue)) {
  case member_value(field.key, members) {
    None ->
      case field.required {
        True ->
          Some(#(field.key, types.MissingRequiredCondition, kdl.JsonValueNull))
        False -> None
      }
    Some(value) ->
      option.map(sealed_leaf_failure(tables, field.leaf, value), fn(condition) {
        #(field.key, condition, value)
      })
  }
}

fn sealed_fields_failure(
  tables: Tables,
  form: types.SealedForm,
  members: List(#(String, kdl.JsonValue)),
) -> Option(#(String, types.ValueCondition, kdl.JsonValue)) {
  option.from_result(
    list.find_map(form.fields, fn(field) {
      option.to_result({ sealed_field_failure(tables, members, field) }, Nil)
    }),
  )
}

fn sealed_known_field(
  tag: types.TagModel,
  form: types.SealedForm,
  key: String,
) -> Bool {
  key == tag.key || list.any(form.fields, fn(field) { field.key == key })
}

fn object_member_failure(
  tables: Tables,
  members: List(#(String, kdl.JsonValue)),
) -> Option(DataFailure) {
  case duplicate_key(members) {
    Some(key) ->
      Some(#([], types.DuplicateFieldCondition(key), kdl.JsonValueObj(members)))
    None ->
      option.map(tag_member_failure(tables, members), fn(failure) {
        #([types.Field(failure.0)], failure.1, failure.2)
      })
  }
}

fn data_value_accepts_with(tables: Tables, value: kdl.JsonValue) -> Bool {
  option.is_none(data_value_failure(tables, [], value))
}

fn data_value_failure(
  tables: Tables,
  path: types.ValuePath,
  value: kdl.JsonValue,
) -> Option(DataFailure) {
  case value {
    kdl.JsonValueNum(_) ->
      case integer_in_domain(tables.profile, None, value) {
        True -> None
        False -> Some(#(path, types.IntegerDomainCondition, value))
      }
    kdl.JsonValueDec(text) ->
      case parse_json_number(text) {
        Some(_) -> {
          let integral_unbounded = case integer_binding(tables.profile, None) {
            Some(binding) ->
              binding.range == types.Unbounded
              && list.contains(binding.forms, types.IntegralDecimal)
              && option.is_some(decimal_integer_parts(text))
            None -> False
          }
          case integral_unbounded {
            True -> None
            False ->
              case
                integer_condition(
                  tables.profile,
                  types.IntegerSpec(None, None, None, None, None, None),
                  value,
                )
              {
                None -> None
                Some(types.IntegerDomainCondition) ->
                  Some(#(path, types.IntegerDomainCondition, value))
                Some(_) ->
                  case tables.profile.numbers.decimals {
                    True -> None
                    False ->
                      Some(#(path, types.InvalidDataModelCondition, value))
                  }
              }
          }
        }
        None -> Some(#(path, types.InvalidDataModelCondition, value))
      }
    kdl.JsonValueStr(text) ->
      case unicode_valid(text) {
        True -> None
        False -> Some(#(path, types.InvalidDataModelCondition, value))
      }
    kdl.JsonValueArr(items) -> data_items_failure(tables, path, 0, items)
    kdl.JsonValueObj(members) ->
      case object_member_failure(tables, members) {
        Some(#(relative_path, condition, observed)) ->
          Some(#(list.append(path, relative_path), condition, observed))
        None ->
          case class_of(tables.profile, members) {
            types.WrapperObject(wrapper) ->
              option.map(
                wrapper_payload_failure(tables, wrapper, value),
                fn(condition) { #(path, condition, value) },
              )
            types.SealedObject(form) ->
              case sealed_fields_failure(tables, form, members) {
                Some(#(key, condition, observed)) ->
                  Some(#(
                    list.append(path, [types.Field(key)]),
                    condition,
                    observed,
                  ))
                None ->
                  case tables.profile.tag {
                    Some(tag) ->
                      data_sealed_members_failure(
                        tables,
                        path,
                        tag,
                        form,
                        members,
                      )
                    None ->
                      Some(#(path, types.InvalidDataModelCondition, value))
                  }
              }
            types.OrdinaryObjectClass ->
              data_members_failure(tables, path, members)
          }
      }
    _ -> None
  }
}

fn data_items_failure(
  tables: Tables,
  path: types.ValuePath,
  index: Int,
  items: List(kdl.JsonValue),
) -> Option(DataFailure) {
  case items {
    [] -> None
    [value, ..rest] ->
      case
        data_value_failure(
          tables,
          list.append(path, [types.Index(index)]),
          value,
        )
      {
        Some(failure) -> Some(failure)
        None -> data_items_failure(tables, path, index + 1, rest)
      }
  }
}

fn data_members_failure(
  tables: Tables,
  path: types.ValuePath,
  members: List(#(String, kdl.JsonValue)),
) -> Option(DataFailure) {
  case members {
    [] -> None
    [#(key, value), ..rest] ->
      case !unicode_valid(key) {
        True ->
          Some(#(
            list.append(path, [types.Field(key)]),
            types.InvalidDataModelCondition,
            value,
          ))
        False ->
          case
            data_value_failure(
              tables,
              list.append(path, [types.Field(key)]),
              value,
            )
          {
            Some(failure) -> Some(failure)
            None -> data_members_failure(tables, path, rest)
          }
      }
  }
}

fn data_sealed_members_failure(
  tables: Tables,
  path: types.ValuePath,
  tag: types.TagModel,
  form: types.SealedForm,
  members: List(#(String, kdl.JsonValue)),
) -> Option(DataFailure) {
  case members {
    [] -> None
    [#(key, value), ..rest] ->
      case sealed_known_field(tag, form, key) {
        True -> data_sealed_members_failure(tables, path, tag, form, rest)
        False ->
          case form.extras == types.SealedReject {
            True ->
              Some(#(
                list.append(path, [types.Field(key)]),
                types.UnexpectedFieldCondition(key),
                value,
              ))
            False ->
              case !unicode_valid(key) {
                True ->
                  Some(#(
                    list.append(path, [types.Field(key)]),
                    types.InvalidDataModelCondition,
                    value,
                  ))
                False ->
                  case
                    data_value_failure(
                      tables,
                      list.append(path, [types.Field(key)]),
                      value,
                    )
                  {
                    Some(failure) -> Some(failure)
                    None ->
                      data_sealed_members_failure(tables, path, tag, form, rest)
                  }
              }
          }
      }
  }
}

fn field_wire_names(spec: types.ProductSpec) -> Dict(String, Nil) {
  list.fold(spec.fields, dict.new(), fn(names, field) {
    dict.insert(names, field.wire_name, Nil)
  })
}

fn member_lookup(
  members: List(#(String, kdl.JsonValue)),
) -> Dict(String, kdl.JsonValue) {
  list.fold(list.reverse(members), dict.new(), fn(lookup, member) {
    dict.insert(lookup, member.0, member.1)
  })
}

fn extra_members_failure(
  tables: Tables,
  wire_names: Dict(String, Nil),
  spec: types.ProductSpec,
  members: List(#(String, kdl.JsonValue)),
) -> Option(DataFailure) {
  option.from_result(
    list.find_map(members, fn(member) {
      option.to_result(
        extra_member_failure(tables, wire_names, spec, member),
        Nil,
      )
    }),
  )
}

fn extra_member_failure(
  tables: Tables,
  wire_names: Dict(String, Nil),
  spec: types.ProductSpec,
  member: #(String, kdl.JsonValue),
) -> Option(DataFailure) {
  let #(key, value) = member
  case
    dict.has_key(wire_names, key)
    || option.unwrap(
      option.map(tables.profile.tag, fn(tag) { key == tag.key }),
      False,
    )
  {
    True -> None
    False ->
      case spec.extras {
        types.RejectExtras ->
          Some(#([types.Field(key)], types.UnexpectedFieldCondition(key), value))
        types.AllowExtras(key_format, _) ->
          case !unicode_valid(key) {
            True ->
              Some(#([types.Field(key)], types.InvalidDataModelCondition, value))
            False ->
              case
                option.unwrap(
                  option.map(key_format, fn(format_use) {
                    !format_use_accepts_with(tables, format_use, key)
                  }),
                  False,
                )
              {
                True ->
                  Some(#(
                    [types.Field(key)],
                    types.KeyFormatCondition(key),
                    value,
                  ))
                False -> None
              }
          }
      }
  }
}

fn slot_requirements(
  path: types.ValuePath,
  members: Dict(String, kdl.JsonValue),
  fields: List(types.FieldSpec),
) -> Expansion {
  case fields {
    [] -> Requirements([])
    [field, ..rest] -> {
      let here = list.append(path, [types.Field(field.wire_name)])
      let value = option.from_result(dict.get(members, field.wire_name))
      case field_value_rejection(field, here, value) {
        Some(rejected) -> rejected
        None ->
          case slot_requirements(path, members, rest) {
            Requirements(children) ->
              Requirements(case field_requirement(field, here, value) {
                Some(request) -> [request, ..children]
                None -> children
              })
            other -> other
          }
      }
    }
  }
}

fn field_value_rejection(
  field: types.FieldSpec,
  here: types.ValuePath,
  value: Option(kdl.JsonValue),
) -> Option(Expansion) {
  case
    value == None && field.slot.required,
    value == Some(kdl.JsonValueNull) && !field.slot.nullable
  {
    True, _ ->
      Some(
        RejectedExpansion(
          failure_at(
            field.slot.type_ref,
            here,
            types.Absent,
            types.MissingRequiredCondition,
            [],
          ),
        ),
      )
    False, True ->
      Some(
        RejectedExpansion(
          failure_at(
            field.slot.type_ref,
            here,
            types.Null,
            types.NullNotAllowedCondition,
            [],
          ),
        ),
      )
    False, False -> None
  }
}

fn field_requirement(
  field: types.FieldSpec,
  here: types.ValuePath,
  value: Option(kdl.JsonValue),
) -> Option(ValueRequirement) {
  case value {
    None | Some(kdl.JsonValueNull) -> None
    Some(value) -> Some(ValueRequirement(field.slot.type_ref, here, value))
  }
}

fn element_requirements(
  contract: types.ElementContract,
  path: types.ValuePath,
  value: kdl.JsonValue,
) -> List(ValueRequirement) {
  let requirement = ValueRequirement(contract.type_ref, path, value)
  case value {
    kdl.JsonValueNull ->
      case contract.nullable {
        True -> []
        False -> [requirement]
      }
    _ -> [requirement]
  }
}

fn extra_field_requirements(
  graph: types.SemanticGraph,
  path: types.ValuePath,
  wire_names: Dict(String, Nil),
  spec: types.ProductSpec,
  members: List(#(String, kdl.JsonValue)),
) -> List(ValueRequirement) {
  case members {
    [] -> []
    [#(key, value), ..rest] -> {
      let later = extra_field_requirements(graph, path, wire_names, spec, rest)
      case
        dict.has_key(wire_names, key)
        || option.unwrap(
          option.map(graph.profile.tag, fn(tag) { key == tag.key }),
          False,
        )
      {
        True -> later
        False ->
          case spec.extras {
            types.RejectExtras -> later
            types.AllowExtras(_, contract) ->
              list.append(
                element_requirements(
                  contract,
                  list.append(path, [types.Field(key)]),
                  value,
                ),
                later,
              )
          }
      }
    }
  }
}

fn product_requirements(
  graph: types.SemanticGraph,
  path: types.ValuePath,
  wire_names: Dict(String, Nil),
  spec: types.ProductSpec,
  members: List(#(String, kdl.JsonValue)),
) -> Expansion {
  case slot_requirements(path, member_lookup(members), spec.fields) {
    Requirements(fields) ->
      Requirements(list.append(
        fields,
        extra_field_requirements(graph, path, wire_names, spec, members),
      ))
    other -> other
  }
}

fn member_test_matches(
  tables: Tables,
  members: List(#(String, kdl.JsonValue)),
  member_test: #(String, types.MemberTest),
) -> Bool {
  case member_test.1 {
    types.AbsentMember -> option.is_none(member_value(member_test.0, members))
    types.FormatMember(name) ->
      case member_value(member_test.0, members) {
        Some(kdl.JsonValueStr(text)) -> named_format_accepts(tables, name, text)
        _ -> False
      }
  }
}

fn value_kind_matches(kind: types.ValueKind, value: kdl.JsonValue) -> Bool {
  case value {
    kdl.JsonValueNull -> kind == types.NullKind
    kdl.JsonValueBool(_) -> kind == types.BooleanKind
    kdl.JsonValueNum(_) | kdl.JsonValueDec(_) -> kind == types.NumberKind
    kdl.JsonValueStr(_) -> kind == types.StringKind
    kdl.JsonValueArr(_) -> kind == types.ArrayKind
    kdl.JsonValueObj(_) -> kind == types.ObjectKind
  }
}

fn selector_matches_with(
  tables: Tables,
  branch: types.UnionBranch,
  value: kdl.JsonValue,
) -> Bool {
  case branch.selector {
    types.InternalTag ->
      case tables.profile.tag, value {
        Some(tag), kdl.JsonValueObj(members) ->
          case member_value(tag.key, members) {
            Some(kdl.JsonValueStr(text)) -> text == branch.wire_tag
            _ -> False
          }
        _, _ -> False
      }
    types.MemberShape(tests) ->
      case value {
        kdl.JsonValueObj(members) ->
          list.all(tests, fn(member_test) {
            member_test_matches(tables, members, member_test)
          })
        _ -> False
      }
    types.Kind(kind) -> value_kind_matches(kind, value)
    types.Otherwise -> True
  }
}

fn select_union_branch_with(
  tables: Tables,
  spec: types.UnionSpec,
  value: kdl.JsonValue,
) -> Option(types.UnionBranch) {
  option.from_result(
    list.find(spec.branches, fn(branch) {
      selector_matches_with(tables, branch, value)
    }),
  )
}

fn compare_decimal_bound(
  text: String,
  bound: types.DecimalBound,
) -> Option(order.Order) {
  use #(mantissa, zeroes, exponent) <- option.then(parse_json_number(text))
  Some(int.compare(
    mantissa * integer_power(10, zeroes) * integer_power(10, bound.scale),
    bound.mantissa * integer_power(10, exponent),
  ))
}

fn decimal_condition(
  spec: types.DecimalSpec,
  text: String,
) -> Option(types.ValueCondition) {
  case parse_json_number(text) {
    None -> Some(types.InvalidDataModelCondition)
    Some(_) -> {
      let minimum_failed = case
        option.then(spec.minimum, fn(bound) {
          compare_decimal_bound(text, bound)
        })
      {
        Some(order.Lt) -> True
        Some(order.Eq) ->
          option.unwrap(
            option.map(spec.minimum, fn(bound) { bound.exclusive }),
            False,
          )
        _ -> False
      }
      case minimum_failed {
        True -> Some(types.BelowMinimumCondition)
        False ->
          case
            option.then(spec.maximum, fn(bound) {
              compare_decimal_bound(text, bound)
            })
          {
            Some(order.Gt) -> Some(types.AboveMaximumCondition)
            Some(order.Eq) ->
              case
                option.unwrap(
                  option.map(spec.maximum, fn(bound) { bound.exclusive }),
                  False,
                )
              {
                True -> Some(types.AboveMaximumCondition)
                False -> None
              }
            _ -> None
          }
      }
    }
  }
}

fn sealed_extras_failure(
  tables: Tables,
  path: types.ValuePath,
  form: types.SealedForm,
  members: List(#(String, kdl.JsonValue)),
) -> Option(DataFailure) {
  case tables.profile.tag {
    Some(tag) -> data_sealed_members_failure(tables, path, tag, form, members)
    None ->
      Some(#(path, types.InvalidDataModelCondition, kdl.JsonValueObj(members)))
  }
}

fn sealed_refinement_failure(
  tables: Tables,
  members: List(#(String, kdl.JsonValue)),
  refinements: List(types.SealedRefinement),
) -> Option(#(String, types.ValueCondition, kdl.JsonValue)) {
  list.find_map(refinements, fn(refinement) {
    case member_value(refinement.key, members) {
      None -> Error(Nil)
      Some(value) ->
        case sealed_leaf_failure(tables, refinement.leaf, value) {
          Some(condition) -> Ok(#(refinement.key, condition, value))
          None -> Error(Nil)
        }
    }
  })
  |> option.from_result
}

fn expand_node(
  tables: Tables,
  graph: types.SemanticGraph,
  reference: types.TypeRef,
  path: types.ValuePath,
  value: kdl.JsonValue,
  node: Option(types.TypeNode),
) -> Expansion {
  let reject = fn(condition) {
    RejectedExpansion(
      failure_at(reference, path, types.Present(value), condition, []),
    )
  }
  let rejected_at = fn(failure_path, condition, observed) {
    RejectedExpansion(
      failure_at(
        reference,
        failure_path,
        types.Present(observed),
        condition,
        [],
      ),
    )
  }
  let profile = graph.profile
  case node {
    None ->
      UnresolvedExpansion([
        obligation_at(graph, reference, path, types.UnresolvedTypeReason),
      ])
    Some(node) ->
      case node.shape, value {
        types.BooleanShape(spec), kdl.JsonValueBool(actual) ->
          case
            option.unwrap(
              option.map(spec.const_value, fn(expected) { expected != actual }),
              False,
            )
          {
            True -> reject(types.ConstMismatchCondition)
            False -> Requirements([])
          }
        types.IntegerShape(spec), _ ->
          case integer_condition(profile, spec, value) {
            None -> Requirements([])
            Some(condition) -> reject(condition)
          }
        types.DecimalShape(spec), kdl.JsonValueDec(text) ->
          case decimal_condition(spec, text) {
            None -> Requirements([])
            Some(condition) -> reject(condition)
          }
        types.StringShape(spec), _ ->
          case string_value_condition(tables, spec, value) {
            None -> Requirements([])
            Some(condition) -> reject(condition)
          }
        types.BytesShape(spec), _ ->
          case bytes_value_length(tables, value) {
            None -> reject(types.InvalidBytesCondition)
            Some(length) ->
              case length_accepts(spec.minimum, spec.maximum, length) {
                True -> Requirements([])
                False -> reject(types.BytesLengthCondition)
              }
          }
        types.ProductShape(spec), kdl.JsonValueObj(members) ->
          case object_member_failure(tables, members) {
            Some(#(relative_path, condition, observed)) ->
              rejected_at(list.append(path, relative_path), condition, observed)
            None ->
              case class_of(profile, members) {
                types.OrdinaryObjectClass -> {
                  let wire_names = field_wire_names(spec)
                  case
                    extra_members_failure(tables, wire_names, spec, members)
                  {
                    Some(#(field_path, condition, observed)) ->
                      rejected_at(
                        list.append(path, field_path),
                        condition,
                        observed,
                      )
                    None ->
                      product_requirements(
                        graph,
                        path,
                        wire_names,
                        spec,
                        members,
                      )
                  }
                }
                _ -> reject(types.WrongValueKindCondition("plain data object"))
              }
          }
        types.ArrayShape(spec), kdl.JsonValueArr(items) ->
          case
            length_accepts(spec.min_length, spec.max_length, list.length(items))
          {
            False -> reject(types.ArrayLengthCondition)
            True ->
              Requirements(
                list.flatten(
                  list.index_map(items, fn(item, index) {
                    element_requirements(
                      spec.item,
                      list.append(path, [types.Index(index)]),
                      item,
                    )
                  }),
                ),
              )
          }
        types.AliasShape(target, _), _ ->
          Requirements([ValueRequirement(target, path, value)])
        types.TaggedUnionShape(spec), _ -> {
          let select = fn() {
            case select_union_branch_with(tables, spec, value) {
              Some(branch) ->
                Requirements([ValueRequirement(branch.target, path, value)])
              None -> reject(types.NoBranchSelectedCondition)
            }
          }
          case value {
            kdl.JsonValueObj(members) ->
              case object_member_failure(tables, members) {
                Some(#(relative_path, condition, observed)) ->
                  rejected_at(
                    list.append(path, relative_path),
                    condition,
                    observed,
                  )
                None -> select()
              }
            _ -> select()
          }
        }
        types.SealedShape(tag, refinements), kdl.JsonValueObj(members) ->
          case object_member_failure(tables, members) {
            Some(#(relative_path, condition, observed)) ->
              rejected_at(list.append(path, relative_path), condition, observed)
            None ->
              case class_of(profile, members) {
                types.SealedObject(form) ->
                  case form.tag != tag {
                    True -> reject(types.InvalidDataModelCondition)
                    False ->
                      case sealed_fields_failure(tables, form, members) {
                        Some(#(key, condition, observed)) ->
                          rejected_at(
                            list.append(path, [types.Field(key)]),
                            condition,
                            observed,
                          )
                        None -> {
                          let extras =
                            sealed_extras_failure(tables, path, form, members)
                          case extras {
                            Some(#(here, condition, observed)) ->
                              rejected_at(here, condition, observed)
                            None ->
                              case
                                sealed_refinement_failure(
                                  tables,
                                  members,
                                  refinements,
                                )
                              {
                                Some(#(key, condition, observed)) ->
                                  rejected_at(
                                    list.append(path, [types.Field(key)]),
                                    condition,
                                    observed,
                                  )
                                None -> Requirements([])
                              }
                          }
                        }
                      }
                  }
                _ -> reject(types.WrongValueKindCondition("sealed object"))
              }
          }
        types.Never, _ -> reject(types.InvalidDataModelCondition)
        types.UnknownShape(types.OrdinaryObject), kdl.JsonValueObj(members) ->
          case object_member_failure(tables, members) {
            Some(#(relative_path, condition, observed)) ->
              rejected_at(list.append(path, relative_path), condition, observed)
            None ->
              case class_of(profile, members) != types.OrdinaryObjectClass {
                True -> reject(types.WrongValueKindCondition("ordinary object"))
                False ->
                  case data_members_failure(tables, path, members) {
                    None -> Requirements([])
                    Some(#(here, condition, observed)) ->
                      rejected_at(here, condition, observed)
                  }
              }
          }
        types.UnknownShape(types.OrdinaryObject), _ ->
          reject(types.WrongValueKindCondition("ordinary object"))
        types.UnknownShape(types.AnyValue), _ ->
          case data_value_failure(tables, path, value) {
            None -> Requirements([])
            Some(#(here, condition, observed)) ->
              rejected_at(here, condition, observed)
          }
        types.UnitShape, kdl.JsonValueNull -> Requirements([])
        types.RawBodyShape(_), _ ->
          case option.is_some(bytes_value_length(tables, value)) {
            True -> Requirements([])
            False -> reject(types.InvalidBytesCondition)
          }
        types.OpaqueShape(name), _ ->
          UnresolvedExpansion([
            obligation_at(graph, reference, path, types.OpaqueTypeReason(name)),
          ])
        types.BooleanShape(_), _ ->
          reject(types.WrongValueKindCondition("boolean"))
        types.DecimalShape(_), _ ->
          reject(types.WrongValueKindCondition("decimal"))
        types.SealedShape(_, _), _ ->
          reject(types.WrongValueKindCondition("sealed object"))
        types.ProductShape(_), _ ->
          reject(types.WrongValueKindCondition("object"))
        types.ArrayShape(_), _ -> reject(types.WrongValueKindCondition("array"))
        types.UnitShape, _ -> reject(types.WrongValueKindCondition("unit"))
      }
  }
}

pub fn expand_value(
  indexed: PreparedGraph,
  reference: types.TypeRef,
  path: types.ValuePath,
  value: kdl.JsonValue,
) -> Expansion {
  expand_node(
    indexed.tables,
    indexed.graph,
    reference,
    path,
    value,
    indexed_type(indexed, reference),
  )
}

type MemberFrame {
  MemberFrame(
    reference: types.TypeRef,
    path: types.ValuePath,
    child_fuel: Int,
    children: List(ValueRequirement),
    wanted: Option(List(MemberProof)),
    proofs: List(MemberProof),
  )
}

type OpenMembers =
  Dict(#(types.TypeRef, Int), List(types.ValuePath))

type MemberOpening {
  MemberDecided(result: MembershipResult)
  MemberOpened(frames: List(MemberFrame), active: OpenMembers)
}

fn check_value_fuel(
  graph: PreparedGraph,
  fuel: Int,
  seen: List(#(types.TypeRef, types.ValuePath)),
  reference: types.TypeRef,
  path: types.ValuePath,
  value: kdl.JsonValue,
  expected: Option(MemberProof),
) -> MembershipResult {
  let outer = list.map(seen, fn(entry) { entry.0 })
  let active =
    list.fold(seen, dict.new(), fn(active, entry) {
      activate_member(active, entry.0, entry.1)
    })
  case
    open_member(
      graph,
      [],
      outer,
      active,
      fuel,
      reference,
      path,
      value,
      expected,
    )
  {
    MemberDecided(result) -> result
    MemberOpened(frames, active) ->
      run_members(graph, frames, outer, active, None)
  }
}

fn open_member(
  graph: PreparedGraph,
  frames: List(MemberFrame),
  outer: List(types.TypeRef),
  active: OpenMembers,
  fuel: Int,
  reference: types.TypeRef,
  path: types.ValuePath,
  value: kdl.JsonValue,
  expected: Option(MemberProof),
) -> MemberOpening {
  case fuel <= 0 {
    True ->
      MemberDecided(
        UnresolvedMembership([
          obligation_at(
            graph.graph,
            reference,
            path,
            types.MembershipBoundReason,
          ),
        ]),
      )
    False ->
      case is_active_member(active, reference, path) {
        True ->
          MemberDecided(
            RejectedMembership(failure_at(
              reference,
              path,
              types.Present(value),
              types.ReferenceCycleCondition,
              member_trace(frames, outer),
            )),
          )
        False ->
          case
            expand_node(
              graph.tables,
              graph.graph,
              reference,
              path,
              value,
              indexed_type(graph, reference),
            )
          {
            RejectedExpansion(failure) ->
              MemberDecided(RejectedMembership(
                types.ValueFailure(
                  ..failure,
                  reference_trace: member_trace(frames, outer),
                ),
              ))
            UnresolvedExpansion(obligations) ->
              MemberDecided(UnresolvedMembership(obligations))
            Requirements(children) ->
              MemberOpened(
                [
                  MemberFrame(
                    reference,
                    path,
                    fuel - 1,
                    children,
                    option.map(expected, fn(proof) { proof.children }),
                    [],
                  ),
                  ..frames
                ],
                activate_member(active, reference, path),
              )
          }
      }
  }
}

fn member_trace(
  frames: List(MemberFrame),
  outer: List(types.TypeRef),
) -> List(types.TypeRef) {
  list.append(list.map(frames, fn(frame) { frame.reference }), outer)
}

fn is_active_member(
  active: OpenMembers,
  reference: types.TypeRef,
  path: types.ValuePath,
) -> Bool {
  case dict.get(active, #(reference, list.length(path))) {
    Ok(paths) -> list.contains(paths, path)
    Error(Nil) -> False
  }
}

fn activate_member(
  active: OpenMembers,
  reference: types.TypeRef,
  path: types.ValuePath,
) -> OpenMembers {
  dict.upsert(active, #(reference, list.length(path)), fn(paths) {
    case paths {
      Some(paths) -> [path, ..paths]
      None -> [path]
    }
  })
}

fn deactivate_member(
  active: OpenMembers,
  reference: types.TypeRef,
  path: types.ValuePath,
) -> OpenMembers {
  let key = #(reference, list.length(path))
  case dict.get(active, key) {
    Ok(paths) ->
      case list.filter(paths, fn(item) { item != path }) {
        [] -> dict.delete(active, key)
        remaining -> dict.insert(active, key, remaining)
      }
    Error(Nil) -> active
  }
}

fn run_members(
  graph: PreparedGraph,
  frames: List(MemberFrame),
  outer: List(types.TypeRef),
  active: OpenMembers,
  result: Option(MembershipResult),
) -> MembershipResult {
  case frames, result {
    [], Some(final) -> final
    [], None -> panic as "a membership check has no open frame"
    [frame, ..rest], None -> next_member(graph, frame, rest, outer, active)
    [frame, ..rest], Some(Accepted(proof)) ->
      run_members(
        graph,
        [MemberFrame(..frame, proofs: [proof, ..frame.proofs]), ..rest],
        outer,
        active,
        None,
      )
    [frame, ..rest], Some(failed) ->
      finish_member(graph, frame, rest, outer, active, failed)
  }
}

fn finish_member(
  graph: PreparedGraph,
  frame: MemberFrame,
  rest: List(MemberFrame),
  outer: List(types.TypeRef),
  active: OpenMembers,
  outcome: MembershipResult,
) -> MembershipResult {
  run_members(
    graph,
    rest,
    outer,
    deactivate_member(active, frame.reference, frame.path),
    Some(outcome),
  )
}

fn next_member(
  graph: PreparedGraph,
  frame: MemberFrame,
  rest: List(MemberFrame),
  outer: List(types.TypeRef),
  active: OpenMembers,
) -> MembershipResult {
  case frame.children, frame.wanted {
    [], None | [], Some([]) ->
      finish_member(
        graph,
        frame,
        rest,
        outer,
        active,
        Accepted(MemberProof(list.reverse(frame.proofs))),
      )
    [], Some([_, ..]) ->
      finish_member(
        graph,
        frame,
        rest,
        outer,
        active,
        InvalidCertificate("extra membership children"),
      )
    [_, ..], Some([]) ->
      finish_member(
        graph,
        frame,
        rest,
        outer,
        active,
        InvalidCertificate("missing membership children"),
      )
    [child, ..remaining], wanted -> {
      let head_proof =
        option.then(wanted, fn(proofs) {
          option.from_result(list.first(proofs))
        })
      let tail_proofs = option.map(wanted, fn(proofs) { list.drop(proofs, 1) })
      let parent =
        MemberFrame(..frame, children: remaining, wanted: tail_proofs)
      case
        open_member(
          graph,
          [parent, ..rest],
          outer,
          active,
          frame.child_fuel,
          child.type_ref,
          child.value_path,
          child.value,
          head_proof,
        )
      {
        MemberDecided(result) ->
          run_members(graph, [parent, ..rest], outer, active, Some(result))
        MemberOpened(frames, active) ->
          run_members(graph, frames, outer, active, None)
      }
    }
  }
}

pub fn validate_value(
  prepared: PreparedGraph,
  reference: types.TypeRef,
  value: kdl.JsonValue,
  proof: Option(MemberProof),
) -> Result(ValidatedValue, ValidationFailure) {
  case reference_obligations(prepared, reference) {
    [_, ..] as obligations -> Error(Unresolved(obligations))
    [] -> meaning_checked_value(prepared, reference, value, proof)
  }
}

fn meaning_checked_value(
  prepared: PreparedGraph,
  reference: types.TypeRef,
  value: kdl.JsonValue,
  proof: Option(MemberProof),
) -> Result(ValidatedValue, ValidationFailure) {
  case
    check_value_fuel(
      prepared,
      { kdl.json_size(value) + 1 } * { prepared.node_count + 1 },
      [],
      reference,
      [],
      value,
      proof,
    )
  {
    Accepted(proof) ->
      Ok(ValidatedValue(prepared.graph, reference, value, proof))
    RejectedMembership(failure) -> Error(Rejected(failure))
    UnresolvedMembership(obligations) -> Error(Unresolved(obligations))
    InvalidCertificate(condition) ->
      Error(CertificateMismatchFailure(condition))
  }
}

fn slot_proof(
  prepared: PreparedGraph,
  slot: types.SlotContract,
  value: types.SlotValue(kdl.JsonValue),
) -> Result(Option(MemberProof), ValidationFailure) {
  case reference_obligations(prepared, slot.type_ref) {
    [_, ..] as obligations -> Error(Unresolved(obligations))
    [] ->
      case value {
        types.Absent ->
          case slot.required {
            False -> Ok(None)
            True ->
              Error(
                Rejected(
                  failure_at(
                    slot.type_ref,
                    [],
                    value,
                    types.MissingRequiredCondition,
                    [],
                  ),
                ),
              )
          }
        types.Null ->
          case slot.nullable {
            True -> Ok(None)
            False ->
              Error(
                Rejected(
                  failure_at(
                    slot.type_ref,
                    [],
                    value,
                    types.NullNotAllowedCondition,
                    [],
                  ),
                ),
              )
          }
        types.Present(actual) ->
          result.map(
            meaning_checked_value(prepared, slot.type_ref, actual, None),
            fn(checked) { Some(checked.proof) },
          )
      }
  }
}

pub fn validate_slot(
  prepared: PreparedGraph,
  slot: types.SlotContract,
  value: types.SlotValue(kdl.JsonValue),
) -> Result(ValidatedSlot, ValidationFailure) {
  let graph = prepared.graph
  use proof <- result.map(slot_proof(prepared, slot, value))
  ValidatedSlot(
    graph,
    slot,
    value,
    MemberCertificate(
      graph.profile.reference,
      graph.source_refs,
      slot,
      value,
      proof,
    ),
  )
}

fn decision_of(
  graph: types.SemanticGraph,
  reference: types.TypeRef,
  checked: Result(a, ValidationFailure),
) -> types.ValueDecision {
  case checked {
    Ok(_) -> types.AcceptedValue
    Error(Rejected(failure)) -> types.RejectedValue(failure)
    Error(Unresolved(obligations)) -> types.UnresolvedValue(obligations)
    Error(CertificateMismatchFailure(condition)) ->
      types.UnresolvedValue([
        obligation_at(
          graph,
          reference,
          [],
          types.CertificateMismatchReason(condition),
        ),
      ])
  }
}

pub fn accepts_value(
  prepared: PreparedGraph,
  reference: types.TypeRef,
  value: kdl.JsonValue,
) -> types.ValueDecision {
  decision_of(
    prepared.graph,
    reference,
    validate_value(prepared, reference, value, None),
  )
}

pub fn accepts_slot(
  prepared: PreparedGraph,
  slot: types.SlotContract,
  value: types.SlotValue(kdl.JsonValue),
) -> types.ValueDecision {
  decision_of(prepared.graph, slot.type_ref, slot_proof(prepared, slot, value))
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

type TypeIndex =
  Dict(types.TypeRef, types.TypeNode)

/// A graph with what its value checks need, built once: the index of its declared types, the table of the types whose meaning obligations are empty, and the format tables.
pub opaque type PreparedGraph {
  PreparedGraph(
    graph: types.SemanticGraph,
    index: TypeIndex,
    node_count: Int,
    edge_count: Int,
    obligation_free: Dict(types.TypeRef, Nil),
    tables: Tables,
    wrappers: Dict(String, types.Wrapper),
    integer_domains: Dict(String, types.IntegerDomainBinding),
  )
}

fn index_graph(graph: types.SemanticGraph) -> PreparedGraph {
  let #(index, node_count, edge_count) =
    list.fold(list.reverse(graph.nodes), #(dict.new(), 0, 0), fn(state, node) {
      let #(index, node_count, edge_count) = state
      #(
        dict.insert(index, node.reference, node),
        node_count + 1,
        edge_count + list.length(declared_type_children(node.shape)),
      )
    })
  PreparedGraph(
    graph,
    index,
    node_count,
    edge_count,
    dict.new(),
    tables_of(graph.profile),
    first_by_name(graph.profile.wrappers, fn(wrapper) { wrapper.name }),
    first_by_name(graph.profile.integer_domains, fn(binding) { binding.name }),
  )
}

fn first_by_name(items: List(a), name_of: fn(a) -> String) -> Dict(String, a) {
  list.fold(list.reverse(items), dict.new(), fn(table, item) {
    dict.insert(table, name_of(item), item)
  })
}

/// Builds everything that a value check needs from a graph. A check on the result builds none of it again.
pub fn prepare(graph: types.SemanticGraph) -> PreparedGraph {
  let indexed = index_graph(graph)
  PreparedGraph(
    ..indexed,
    obligation_free: obligation_free_types(indexed),
    tables: Tables(graph.profile, Some(prepared_format_cache(graph))),
  )
}

pub fn prepared_graph(prepared: PreparedGraph) -> types.SemanticGraph {
  prepared.graph
}

/// Whether the value is a string that the named format of the prepared graph accepts. It reads the prepared format tables.
pub fn named_format_matches(
  prepared: PreparedGraph,
  name: String,
  value: kdl.JsonValue,
) -> Bool {
  case value {
    kdl.JsonValueStr(text) -> named_format_accepts(prepared.tables, name, text)
    _ -> False
  }
}

/// The wrapper of the prepared graph with the name, from its wrapper index.
pub fn prepared_wrapper(
  prepared: PreparedGraph,
  name: String,
) -> Option(types.Wrapper) {
  option.from_result(dict.get(prepared.wrappers, name))
}

fn obligation_free_types(indexed: PreparedGraph) -> Dict(types.TypeRef, Nil) {
  let nodes = dict.to_list(indexed.index)
  let #(parents, bad) =
    list.fold(nodes, #(dict.new(), []), fn(state, entry) {
      let #(parents, bad) = state
      let #(reference, node) = entry
      let children = declared_type_children(node.shape)
      let parents =
        list.fold(children, parents, fn(parents, child) {
          dict.upsert(parents, child, fn(existing) {
            [reference, ..option.unwrap(existing, [])]
          })
        })
      let broken =
        declared_meaning_obligations(indexed.graph, reference, Some(node)) != []
        || list.any(children, fn(child) { !dict.has_key(indexed.index, child) })
      #(parents, case broken {
        True -> [reference, ..bad]
        False -> bad
      })
    })
  let reaching = mark_reaching(parents, bad, dict.new())
  list.fold(nodes, dict.new(), fn(free, entry) {
    case dict.has_key(reaching, entry.0) {
      True -> free
      False -> dict.insert(free, entry.0, Nil)
    }
  })
}

fn mark_reaching(
  parents: Dict(types.TypeRef, List(types.TypeRef)),
  pending: List(types.TypeRef),
  marked: Dict(types.TypeRef, Nil),
) -> Dict(types.TypeRef, Nil) {
  case pending {
    [] -> marked
    [reference, ..rest] ->
      case dict.has_key(marked, reference) {
        True -> mark_reaching(parents, rest, marked)
        False ->
          mark_reaching(
            parents,
            list.append(
              option.unwrap(
                option.from_result(dict.get(parents, reference)),
                [],
              ),
              rest,
            ),
            dict.insert(marked, reference, Nil),
          )
      }
  }
}

fn reference_obligations(
  prepared: PreparedGraph,
  reference: types.TypeRef,
) -> List(types.SemanticObligation) {
  meaning_obligations(prepared, [reference])
}

@internal
pub fn indexed_type(
  graph: PreparedGraph,
  reference: types.TypeRef,
) -> Option(types.TypeNode) {
  option.from_result(dict.get(graph.index, reference))
}

fn tag_matches(
  profile: types.SemanticProfile,
  members: List(#(String, kdl.JsonValue)),
  tag: String,
) -> Bool {
  case profile.tag {
    None -> False
    Some(model) ->
      case member_value(model.key, members) {
        Some(kdl.JsonValueStr(actual)) -> actual == tag
        _ -> False
      }
  }
}

pub fn value_at_path(
  profile: types.SemanticProfile,
  value: kdl.JsonValue,
  path: types.ValuePath,
) -> types.SlotValue(kdl.JsonValue) {
  case path {
    [] -> types.Present(value)
    [step, ..rest] ->
      case value, step {
        kdl.JsonValueNull, _ -> types.Null
        kdl.JsonValueObj(members), types.Field(name) ->
          case member_value(name, members) {
            None -> types.Absent
            Some(kdl.JsonValueNull) -> types.Null
            Some(found) -> value_at_path(profile, found, rest)
          }
        kdl.JsonValueArr(items), types.Index(index) ->
          case index < 0 {
            True -> types.Absent
            False ->
              case list.first(list.drop(items, index)) {
                Error(_) -> types.Absent
                Ok(kdl.JsonValueNull) -> types.Null
                Ok(found) -> value_at_path(profile, found, rest)
              }
          }
        kdl.JsonValueObj(members), types.Variant(tag) ->
          case tag_matches(profile, members, tag) {
            True -> value_at_path(profile, value, rest)
            False -> types.Absent
          }
        _, _ -> types.Absent
      }
  }
}

pub fn projected_value(
  profile: types.SemanticProfile,
  source: types.SlotValue(kdl.JsonValue),
  path: types.ValuePath,
) -> types.SlotValue(kdl.JsonValue) {
  case source {
    types.Absent -> types.Absent
    types.Null -> types.Null
    types.Present(value) -> value_at_path(profile, value, path)
  }
}

fn strengthen_projection(
  slot: types.SlotContract,
  path: types.ValuePath,
  assumptions: List(ProjectionAssumption),
) -> types.SlotContract {
  let observed =
    list.any(assumptions, fn(assumption) {
      case assumption {
        Present(at) | Variant(at, _) | IndexPresent(at, _) -> at == path
        _ -> False
      }
    })
  case observed {
    True -> types.SlotContract(..slot, required: True, nullable: False)
    False ->
      case list.contains(assumptions, NonNull(path)) {
        True -> types.SlotContract(..slot, nullable: False)
        False -> slot
      }
  }
}

fn selector_precedes_internal_tag(
  branch: types.UnionBranch,
  tag: String,
) -> Bool {
  case branch.selector {
    types.InternalTag -> branch.wire_tag != tag
    types.Kind(kind) -> kind != types.ObjectKind
    _ -> False
  }
}

fn projectable_tag_branch(
  branches: List(types.UnionBranch),
  tag: String,
) -> Option(types.UnionBranch) {
  case branches {
    [] -> None
    [branch, ..rest] ->
      case branch.wire_tag == tag {
        True ->
          case branch.selector {
            types.InternalTag -> Some(branch)
            _ -> None
          }
        False ->
          case selector_precedes_internal_tag(branch, tag) {
            True -> projectable_tag_branch(rest, tag)
            False -> None
          }
      }
  }
}

fn project_contract(
  indexed: PreparedGraph,
  assumptions: List(ProjectionAssumption),
  fuel: Int,
  slot: types.SlotContract,
  traversed: types.ValuePath,
  remaining: types.ValuePath,
) -> Result(types.SlotContract, ProjectionFailure) {
  case fuel <= 0 {
    True ->
      Error(
        ProjectionUnresolved([
          obligation_at(
            indexed.graph,
            slot.type_ref,
            traversed,
            types.MembershipBoundReason,
          ),
        ]),
      )
    False -> {
      let slot = strengthen_projection(slot, traversed, assumptions)
      case remaining {
        [] -> Ok(slot)
        [step, ..rest] ->
          case indexed_type(indexed, slot.type_ref) {
            None ->
              Error(
                ProjectionUnresolved([
                  obligation_at(
                    indexed.graph,
                    slot.type_ref,
                    traversed,
                    types.UnresolvedTypeReason,
                  ),
                ]),
              )
            Some(node) ->
              case node.shape {
                types.AliasShape(target, _) ->
                  project_contract(
                    indexed,
                    assumptions,
                    fuel - 1,
                    types.SlotContract(..slot, type_ref: target),
                    traversed,
                    remaining,
                  )
                types.ProductShape(spec) ->
                  case step {
                    types.Field(name) ->
                      case
                        list.find(spec.fields, fn(field) {
                          field.wire_name == name
                        })
                      {
                        Error(_) -> Error(MissingField(slot.type_ref, name))
                        Ok(field) ->
                          project_contract(
                            indexed,
                            assumptions,
                            fuel - 1,
                            types.SlotContract(
                              field.slot.type_ref,
                              slot.required && field.slot.required,
                              slot.nullable || field.slot.nullable,
                            ),
                            list.append(traversed, [step]),
                            rest,
                          )
                      }
                    _ -> Error(WrongShape(slot.type_ref, traversed))
                  }
                types.ArrayShape(spec) ->
                  case step {
                    types.Index(index) -> {
                      let present =
                        index < option.unwrap(spec.min_length, 0)
                        || list.contains(
                          assumptions,
                          IndexPresent(traversed, index),
                        )
                      project_contract(
                        indexed,
                        assumptions,
                        fuel - 1,
                        types.SlotContract(
                          spec.item.type_ref,
                          slot.required && present,
                          True,
                        ),
                        list.append(traversed, [step]),
                        rest,
                      )
                    }
                    _ -> Error(WrongShape(slot.type_ref, traversed))
                  }
                types.TaggedUnionShape(spec) ->
                  case step {
                    types.Variant(tag) -> {
                      use _ <- result.try(
                        case
                          list.contains(assumptions, Variant(traversed, tag))
                        {
                          True -> Ok(Nil)
                          False ->
                            Error(BranchAssumptionRequired(traversed, tag))
                        },
                      )
                      use branch <- result.try(option.to_result(
                        option.from_result(
                          list.find(spec.branches, fn(branch) {
                            branch.wire_tag == tag
                          }),
                        ),
                        MissingVariant(slot.type_ref, tag),
                      ))
                      use _ <- result.try(case indexed.graph.profile.tag {
                        None ->
                          Error(VariantSelectionUndetermined(traversed, tag))
                        Some(_) -> Ok(Nil)
                      })
                      use selected <- result.try(option.to_result(
                        projectable_tag_branch(spec.branches, tag),
                        VariantSelectionUndetermined(traversed, tag),
                      ))
                      case selected == branch {
                        True ->
                          project_contract(
                            indexed,
                            assumptions,
                            fuel - 1,
                            types.SlotContract(..slot, type_ref: branch.target),
                            list.append(traversed, [step]),
                            rest,
                          )
                        False ->
                          Error(VariantSelectionUndetermined(traversed, tag))
                      }
                    }
                    _ -> Error(WrongShape(slot.type_ref, traversed))
                  }
                _ -> Error(WrongShape(slot.type_ref, traversed))
              }
          }
      }
    }
  }
}

pub fn project_slot(
  indexed: PreparedGraph,
  source: types.SlotContract,
  path: types.ValuePath,
  assumptions: List(ProjectionAssumption),
) -> Result(ProjectionCertificate, ProjectionFailure) {
  let graph = indexed.graph
  case meaning_obligations(indexed, [source.type_ref]) {
    [_, ..] as obligations -> Error(ProjectionUnresolved(obligations))
    [] -> {
      use destination <- result.try(project_contract(
        indexed,
        assumptions,
        { list.length(path) + 1 } * { indexed.node_count + 1 },
        source,
        [],
        path,
      ))
      case meaning_obligations(indexed, [destination.type_ref]) {
        [_, ..] as obligations -> Error(ProjectionUnresolved(obligations))
        [] ->
          Ok(ProjectionCertificate(
            graph.profile.reference,
            graph.source_refs,
            source,
            path,
            assumptions,
            destination,
          ))
      }
    }
  }
}

pub fn check_projection_certificate(
  prepared: PreparedGraph,
  certificate: ProjectionCertificate,
) -> Result(ProjectionCertificate, ProjectionFailure) {
  let graph = prepared.graph
  case
    certificate.profile != graph.profile.reference
    || certificate.source_refs != graph.source_refs
  {
    True -> Error(CertificateMismatch("profile or source revisions"))
    False -> {
      use computed <- result.try(project_slot(
        prepared,
        certificate.source,
        certificate.path,
        certificate.assumptions,
      ))
      case computed == certificate {
        True -> Ok(computed)
        False -> Error(CertificateMismatch("projection contract or guards"))
      }
    }
  }
}

type DefaultContext {
  DefaultContext(
    indexed: PreparedGraph,
    validated: Dict(types.TypeRef, Nil),
    applications: List(DefaultApplication),
  )
}

fn declared_default(
  indexed: PreparedGraph,
  reference: types.TypeRef,
  fuel: Int,
) -> Option(#(types.TypeRef, kdl.JsonValue)) {
  case fuel <= 0 {
    True -> None
    False ->
      case indexed_type(indexed, reference) {
        None -> None
        Some(node) ->
          case node.shape {
            types.AliasShape(target, _) ->
              declared_default(indexed, target, fuel - 1)
            shape ->
              option.map(type_default(shape), fn(value) { #(reference, value) })
          }
      }
  }
}

fn validate_default(
  context: DefaultContext,
  reference: types.TypeRef,
  value: kdl.JsonValue,
) -> Result(DefaultContext, ValidationFailure) {
  case dict.has_key(context.validated, reference) {
    True -> Ok(context)
    False -> {
      use _ <- result.try(validate_value(
        context.indexed,
        reference,
        value,
        None,
      ))
      Ok(
        DefaultContext(
          ..context,
          validated: dict.insert(context.validated, reference, Nil),
        ),
      )
    }
  }
}

fn field_lookup(spec: types.ProductSpec) -> Dict(String, types.FieldSpec) {
  list.fold(list.reverse(spec.fields), dict.new(), fn(fields, field) {
    dict.insert(fields, field.wire_name, field)
  })
}

fn default_draft(
  context: DefaultContext,
  reference: types.TypeRef,
  path: types.ValuePath,
  value: kdl.JsonValue,
  fuel: Int,
) -> Result(#(kdl.JsonValue, DefaultContext), ValidationFailure) {
  let graph = context.indexed.graph
  use _ <- result.try(case fuel <= 0 {
    True ->
      Error(
        Unresolved([
          obligation_at(graph, reference, path, types.MembershipBoundReason),
        ]),
      )
    False -> Ok(Nil)
  })
  use node <- result.try(case indexed_type(context.indexed, reference) {
    None ->
      Error(
        Unresolved([
          obligation_at(graph, reference, path, types.UnresolvedTypeReason),
        ]),
      )
    Some(node) -> Ok(node)
  })
  case node.shape, value {
    types.AliasShape(target, _), _ ->
      default_draft(context, target, path, value, fuel - 1)
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
              default_draft(context, branch.target, path, value, fuel - 1)
            Error(_) -> Ok(#(value, context))
          }
        _ -> Ok(#(value, context))
      }
    }
    types.ArrayShape(spec), kdl.JsonValueArr(items) -> {
      use #(drafted, context) <- result.try(
        list.try_fold(
          list.index_map(items, fn(item, index) { #(item, index) }),
          #([], context),
          fn(output, item) {
            use #(child, context) <- result.try(default_draft(
              output.1,
              spec.item.type_ref,
              list.append(path, [types.Index(item.1)]),
              item.0,
              fuel - 1,
            ))
            Ok(#([child, ..output.0], context))
          },
        ),
      )
      Ok(#(kdl.JsonValueArr(list.reverse(drafted)), context))
    }
    types.ProductShape(spec), kdl.JsonValueObj(members) -> {
      let fields = field_lookup(spec)
      use retained <- result.try(
        list.try_fold(members, #([], context), fn(output, member) {
          let #(values, context) = output
          case dict.get(fields, member.0), member.1 {
            Ok(field), item if item != kdl.JsonValueNull -> {
              use #(child, context) <- result.try(default_draft(
                context,
                field.slot.type_ref,
                list.append(path, [types.Field(member.0)]),
                item,
                fuel - 1,
              ))
              Ok(#([#(member.0, child), ..values], context))
            }
            _, _ -> Ok(#([member, ..values], context))
          }
        }),
      )
      let present = member_lookup(members)
      let default_fuel = context.indexed.node_count + 1
      use #(inserted, context) <- result.try(
        list.try_fold(spec.fields, retained, fn(output, field) {
          let #(values, context) = output
          case dict.has_key(present, field.wire_name) {
            True -> Ok(output)
            False ->
              case
                declared_default(
                  context.indexed,
                  field.slot.type_ref,
                  default_fuel,
                )
              {
                None -> Ok(output)
                Some(#(default_ref, item)) -> {
                  use context <- result.try(validate_default(
                    context,
                    default_ref,
                    item,
                  ))
                  let application =
                    DefaultApplication(
                      list.append(path, [types.Field(field.wire_name)]),
                      default_ref,
                      types.occurrence_at(default_ref, "default"),
                      item,
                    )
                  Ok(#(
                    [#(field.wire_name, item), ..values],
                    DefaultContext(..context, applications: [
                      application,
                      ..context.applications
                    ]),
                  ))
                }
              }
          }
        }),
      )
      Ok(#(kdl.JsonValueObj(list.reverse(inserted)), context))
    }
    _, _ -> Ok(#(value, context))
  }
}

pub fn materialize_defaults(
  indexed: PreparedGraph,
  reference: types.TypeRef,
  value: kdl.JsonValue,
) -> Result(DefaultedValue, ValidationFailure) {
  let graph = indexed.graph
  use #(drafted, context) <- result.try(default_draft(
    DefaultContext(indexed, dict.new(), []),
    reference,
    [],
    value,
    { kdl.json_size(value) + 1 } * { indexed.node_count + 1 },
  ))
  let applications = list.reverse(context.applications)
  use checked <- result.try(validate_value(indexed, reference, drafted, None))
  case check_default_applications(indexed, value, drafted, applications) {
    True ->
      Ok(DefaultedValue(graph, reference, drafted, applications, checked.proof))
    False ->
      Error(CertificateMismatchFailure("default source, absence, or result"))
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
  indexed: PreparedGraph,
  before: kdl.JsonValue,
  after: kdl.JsonValue,
  applications: List(DefaultApplication),
) -> Bool {
  let profile = indexed.graph.profile
  let requests =
    list.index_map(applications, fn(application, position) {
      #(application.value_path, position)
    })
  let before_values = values_at_paths(profile, before, requests, dict.new())
  let after_values = values_at_paths(profile, after, requests, dict.new())
  list.index_map(applications, fn(application, position) {
    #(application, position)
  })
  |> list.all(fn(entry) {
    let #(application, position) = entry
    dict.get(before_values, position) == Ok(types.Absent)
    && dict.get(after_values, position) == Ok(types.Present(application.value))
    && application.origin
    == types.OccurrenceRef(
      application.type_ref.source,
      list.append(application.type_ref.pointer, ["default"]),
    )
    && option.then(indexed_type(indexed, application.type_ref), fn(node) {
      type_default(node.shape)
    })
    == Some(application.value)
  })
}

fn values_at_paths(
  profile: types.SemanticProfile,
  value: kdl.JsonValue,
  requests: List(#(types.ValuePath, Int)),
  resolved: Dict(Int, types.SlotValue(kdl.JsonValue)),
) -> Dict(Int, types.SlotValue(kdl.JsonValue)) {
  let #(resolved, groups) =
    list.fold(requests, #(resolved, dict.new()), fn(state, request) {
      let #(resolved, groups) = state
      case request.0 {
        [] -> #(dict.insert(resolved, request.1, types.Present(value)), groups)
        [step, ..rest] -> #(
          resolved,
          dict.upsert(groups, step, fn(group) {
            [#(rest, request.1), ..option.unwrap(group, [])]
          }),
        )
      }
    })
  let settle = fn(resolved, group: List(#(types.ValuePath, Int)), slot) {
    list.fold(group, resolved, fn(resolved, request) {
      dict.insert(resolved, request.1, slot)
    })
  }
  let descend = fn(resolved, group, found) {
    case found {
      None -> settle(resolved, group, types.Absent)
      Some(kdl.JsonValueNull) -> settle(resolved, group, types.Null)
      Some(found) -> values_at_paths(profile, found, group, resolved)
    }
  }
  case dict.is_empty(groups), value {
    True, _ -> resolved
    False, kdl.JsonValueNull ->
      dict.fold(groups, resolved, fn(resolved, _, group) {
        settle(resolved, group, types.Null)
      })
    False, kdl.JsonValueObj(members) -> {
      let lookup = member_lookup(members)
      dict.fold(groups, resolved, fn(resolved, step, group) {
        case step {
          types.Field(name) ->
            descend(resolved, group, option.from_result(dict.get(lookup, name)))
          types.Variant(tag) ->
            case tag_matches(profile, members, tag) {
              True -> values_at_paths(profile, value, group, resolved)
              False -> settle(resolved, group, types.Absent)
            }
          _ -> settle(resolved, group, types.Absent)
        }
      })
    }
    False, kdl.JsonValueArr(items) -> {
      let size = list.length(items)
      let items = indexed(items)
      dict.fold(groups, resolved, fn(resolved, step, group) {
        case step {
          types.Index(index) if index >= 0 && index < size ->
            descend(resolved, group, Some(indexed_at(index + 1, items)))
          _ -> settle(resolved, group, types.Absent)
        }
      })
    }
    False, _ ->
      dict.fold(groups, resolved, fn(resolved, _, group) {
        settle(resolved, group, types.Absent)
      })
  }
}
