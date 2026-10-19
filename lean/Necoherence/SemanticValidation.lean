-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SemanticTypes
import Init.Data.String.Lemmas
import Std.Data.HashMap

namespace Necoherence.SemanticValidation

open Necoherence.ExactJson
open Necoherence.SemanticTypes

deriving instance DecidableEq for DfaTransition
deriving instance DecidableEq for DfaSpec
deriving instance DecidableEq for CalendarRule

private def asciiAlpha (c : Char) : Bool :=
  ('A' ≤ c && c ≤ 'Z') || ('a' ≤ c && c ≤ 'z')

private def asciiDigit (c : Char) : Bool := '0' ≤ c && c ≤ '9'
private def asciiAlnum (c : Char) : Bool := asciiAlpha c || asciiDigit c
private def asciiHex (c : Char) : Bool :=
  asciiDigit c || ('a' ≤ c && c ≤ 'f') || ('A' ≤ c && c ≤ 'F')

private def scalarValid (c : Char) : Bool :=
  c.toNat ≤ 1114111 && !(55296 ≤ c.toNat && c.toNat ≤ 57343)

def unicodeValid (text : String) : Bool := text.foldl (fun ok c => ok && scalarValid c) true

def utf8Length (text : String) : Nat :=
  text.foldl (fun count c => count +
    if c.toNat < 128 then 1 else if c.toNat < 2048 then 2
    else if c.toNat < 65536 then 3 else 4) 0

private def ascii (text : String) : Bool := text.foldl (fun ok c => ok && c.toNat < 128) true
private def allChars (test : Char → Bool) (text : String) : Bool :=
  text.foldl (fun ok c => ok && test c) true

private def inRange (n : Nat) (range : CodepointRange) : Bool := range.first ≤ n && n ≤ range.last

private def graphemeProperty (rules : GraphemeRules) (c : Char) : GraphemeProperty :=
  ((rules.properties.find? (fun range => range.first ≤ c.toNat && c.toNat ≤ range.last)).map
    (·.property)).getD .other

private def indicProperty (rules : GraphemeRules) (c : Char) : IndicProperty :=
  ((rules.indicConjunct.find? (fun range => range.first ≤ c.toNat && c.toNat ≤ range.last)).map
    (·.property)).getD .other

private def pictographic (rules : GraphemeRules) (c : Char) : Bool :=
  rules.extendedPictographic.any (inRange c.toNat)

private def controlProperty (property : GraphemeProperty) : Bool :=
  property == .cr || property == .lf || property == .control

private structure GraphemeState where
  count : Nat := 0
  previous : Option GraphemeProperty := none
  regionalRun : Nat := 0
  pictographicExtends : Bool := false
  previousZwjAfterPictographic : Bool := false
  indicConsonant : Bool := false
  indicLinker : Bool := false

private def graphemeBreak (state : GraphemeState) (next : GraphemeProperty)
    (indic : IndicProperty) (ep : Bool) : Bool :=
  match state.previous with
    | none => true
    | some previous =>
      if previous == .cr && next == .lf then false
      else if controlProperty previous || controlProperty next then true
      else if previous == .l && (next == .l || next == .v || next == .lv || next == .lvt) then false
      else if (previous == .lv || previous == .v) && (next == .v || next == .t) then false
      else if (previous == .lvt || previous == .t) && next == .t then false
      else if next == .extend || next == .zwj || next == .spacingMark then false
      else if previous == .prepend then false
      else if indic == .consonant && state.indicConsonant && state.indicLinker then false
      else if ep && previous == .zwj && state.previousZwjAfterPictographic then false
      else if previous == .regionalIndicator && next == .regionalIndicator && state.regionalRun % 2 == 1 then false
      else true

private def graphemeStep (rules : GraphemeRules) (state : GraphemeState) (c : Char) : GraphemeState :=
  let next := graphemeProperty rules c
  let indic := indicProperty rules c
  let ep := pictographic rules c
  let breaks := graphemeBreak state next indic ep
  { count := state.count + if breaks then 1 else 0
    previous := some next
    regionalRun := if next == .regionalIndicator then state.regionalRun + 1 else 0
    pictographicExtends := ep || (next == .extend && state.pictographicExtends)
    previousZwjAfterPictographic := next == .zwj && state.pictographicExtends
    indicConsonant := if indic == .consonant then true
      else (indic == .extend || indic == .linker) && state.indicConsonant
    indicLinker := if indic == .consonant then false
      else if indic == .linker then state.indicConsonant
      else indic == .extend && state.indicLinker }

def graphemeLength (rules : GraphemeRules) (text : String) : Nat :=
  (text.foldl (graphemeStep rules) {}).count

private def graphemeBoundaryOffsets (rules : GraphemeRules) :
    GraphemeState → Nat → List Char → List Nat
  | _, offset, [] => [offset]
  | state, offset, c :: cs =>
    let next := graphemeStep rules state c
    let rest := graphemeBoundaryOffsets rules next (offset + 1) cs
    if state.count < next.count then offset :: rest else rest

/-- Unicode scalar offsets of extended grapheme boundaries (Unicode 16.0 UAX #29,
GB1 and GB2). -/
def graphemeBoundaries (rules : GraphemeRules) (text : String) : List Nat :=
  match text.toList with
  | [] => []
  | c :: cs => graphemeBoundaryOffsets rules {} 0 (c :: cs)

private def base64Digit (alphabet : BytesAlphabet) (c : Char) : Option Nat :=
  if 'A' ≤ c && c ≤ 'Z' then some (c.toNat - 'A'.toNat)
  else if 'a' ≤ c && c ≤ 'z' then some (c.toNat - 'a'.toNat + 26)
  else if '0' ≤ c && c ≤ '9' then some (c.toNat - '0'.toNat + 52)
  else match alphabet with
    | .standard => if c == '+' then some 62 else if c == '/' then some 63 else none
    | .urlSafe => if c == '-' then some 62 else if c == '_' then some 63 else none
    | .either =>
      if c == '+' || c == '-' then some 62
      else if c == '/' || c == '_' then some 63
      else none

private def base32Digit (c : Char) : Option Nat :=
  if 'a' ≤ c && c ≤ 'z' then some (c.toNat - 'a'.toNat)
  else if '2' ≤ c && c ≤ '7' then some (c.toNat - '2'.toNat + 26) else none

private def base64TailBits (alphabet : BytesAlphabet) (text : String) (remainder : Nat) : Bool :=
  match text.toList.getLast? with
  | none => true
  | some c => match base64Digit alphabet c with
    | none => false
    | some n => if remainder == 2 then n % 16 == 0 else if remainder == 3 then n % 4 == 0 else true

def base64Length (policy : BytesPolicy) (text : String) : Option Nat := do
  let parts := text.splitOn "="
  let body ← parts[0]?
  let padding := parts.length - 1
  if padding > 2 || !(parts.drop 1).all (· == "") then none
  else if !allChars (fun c => (base64Digit policy.alphabet c).isSome) body then none
  else
    let remainder := body.length % 4
    if remainder == 1 || (policy.strictPadBits && !base64TailBits policy.alphabet body remainder) then none
    else if padding > 0 && (text.length % 4 != 0 || padding != (4 - remainder) % 4) then none
    else if padding == 0 && !policy.paddingOptional && remainder != 0 then none
    else some (body.length / 4 * 3 + if remainder == 0 then 0 else remainder - 1)

private def decodeBase32 (text : String) : Option (List Nat) :=
  let rec go (bits buffer : Nat) (bytes : List Nat) : List Char → Option (List Nat)
    | [] => if buffer == 0 && bits < 5 then some bytes.reverse else none
    | c :: rest => do
      let digit ← base32Digit c
      let accumulated := buffer * 32 + digit
      let available := bits + 5
      if available ≥ 8 then
        let residual := available - 8
        let divisor := 2 ^ residual
        go residual (accumulated % divisor) (accumulated / divisor :: bytes) rest
      else go available accumulated bytes rest
  go 0 0 [] text.toList

private def readVarint (bytes : List Nat) : Option (Nat × List Nat) :=
  let rec go (shift total : Nat) : List Nat → Option (Nat × List Nat)
    | [] => none
    | byte :: rest =>
      let value := total + byte % 128 * 2 ^ shift
      if byte < 128 then
        if shift > 0 && byte == 0 then none else some (value, rest)
      else go (shift + 7) value rest
  go 0 0 bytes

private def nonemptyChars (test : Char → Bool) (text : String) : Bool :=
  text != "" && allChars test text

private def splitChar (delimiter : Char) : List Char → List Char × Option (List Char)
  | [] => ([], none)
  | c :: rest => if c == delimiter then ([], some rest)
    else let (before, after) := splitChar delimiter rest; (c :: before, after)

private def uriUnreserved (c : Char) : Bool :=
  asciiAlnum c || "-._~".contains c
private def uriSubdelim (c : Char) : Bool := "!$&'()*+,;=".contains c

private def uriChars (extra : Char → Bool) : List Char → Bool
  | [] => true
  | '%' :: a :: b :: rest => asciiHex a && asciiHex b && uriChars extra rest
  | '%' :: _ => false
  | c :: rest => (uriUnreserved c || uriSubdelim c || extra c) && uriChars extra rest

private def ipv4 (text : String) : Bool :=
  let parts := text.splitOn "."
  parts.length == 4 && parts.all fun part =>
    nonemptyChars asciiDigit part && part.length ≤ 3 &&
      (part == "0" || !part.startsWith "0") && (part.toNat?.map (fun n => decide (n ≤ 255))).getD false

private def ipv6GroupCount (parts : List String) : Option Nat :=
  let rec go : List String → Option Nat
    | [] => some 0
    | [last] => if last.contains '.' then if ipv4 last then some 2 else none
      else if last != "" && last.length ≤ 4 && allChars asciiHex last then some 1 else none
    | part :: rest => do
      if part == "" || part.length > 4 || !allChars asciiHex part then none
      else return 1 + (← go rest)
  go parts

private def ipv6 (text : String) : Bool :=
  match text.splitOn "::" with
  | [whole] => (ipv6GroupCount (whole.splitOn ":")).map (· == 8) |>.getD false
  | [before, after] =>
    let left := if before == "" then some 0 else ipv6GroupCount (before.splitOn ":")
    let right := if after == "" then some 0 else ipv6GroupCount (after.splitOn ":")
    match left, right with
    | some a, some b => a + b < 8 && !before.contains '.'
    | _, _ => false
  | _ => false

private def ipLiteral (text : String) : Bool :=
  if text.startsWith "v" || text.startsWith "V" then
    match text.splitOn "." with
    | version :: tail =>
      nonemptyChars asciiHex (String.ofList (version.toList.drop 1)) &&
      nonemptyChars (fun c => uriUnreserved c || uriSubdelim c || c == ':')
        (String.intercalate "." tail)
    | _ => false
  else ipv6 text

private def uriHostPort : List Char → Bool
  | '[' :: rest =>
    let (host, after) := splitChar ']' rest
    ipLiteral (String.ofList host) &&
      match after with
      | some [] => true
      | some (':' :: port) => port.all asciiDigit
      | _ => false
  | text =>
    let (host, port) := splitChar ':' text
    uriChars (fun _ => false) host &&
      match port with | none => true | some digits => digits.all asciiDigit

private def uriAuthority (text : List Char) : Bool :=
  let (before, after) := splitChar '@' text
  match after with
  | none => uriHostPort before
  | some host => uriChars (· == ':') before && !host.contains '@' && uriHostPort host

private def uriSyntax (text : String) : Bool :=
  let (scheme, tail) := splitChar ':' text.toList
  let schemeOk := match scheme with
    | c :: rest => asciiAlpha c && rest.all (fun c => asciiAlnum c || "+-.".contains c)
    | _ => false
  schemeOk && match tail with
    | none => false
    | some tail =>
      let (beforeFragment, fragment) := splitChar '#' tail
      let (hierarchy, query) := splitChar '?' beforeFragment
      let pathOk := match hierarchy with
        | '/' :: '/' :: rest =>
          let authority := rest.takeWhile (· != '/')
          uriAuthority authority && uriChars (fun c => c == ':' || c == '@' || c == '/')
            (rest.drop authority.length)
        | rest => uriChars (fun c => c == ':' || c == '@' || c == '/') rest
      pathOk && (query.map (uriChars (fun c => c == ':' || c == '@' || c == '/' || c == '?'))).getD true &&
        (fragment.map (uriChars (fun c => c == ':' || c == '@' || c == '/' || c == '?'))).getD true

private def languageSubtag (minimum maximum : Nat) (text : String) : Bool :=
  minimum ≤ text.length && text.length ≤ maximum && allChars asciiAlnum text


private def languageExtensions (seen : List String) : List String → Bool
  | [] => true
  | "x" :: rest => !rest.isEmpty && rest.all (languageSubtag 1 8)
  | singleton :: rest =>
    if singleton.length != 1 || !allChars asciiAlnum singleton || seen.contains singleton then false
    else
      let values := rest.takeWhile (languageSubtag 2 8)
      !values.isEmpty && languageExtensions (singleton :: seen) (rest.drop values.length)
termination_by parts => parts.length
decreasing_by simp_wf; omega

private def languageVariants (seen : List String) : List String → Bool
  | [] => true
  | part :: rest =>
    let variant := languageSubtag 5 8 part ||
      (part.length == 4 && allChars asciiAlnum part &&
        (part.toList.head?.map asciiDigit).getD false)
    if variant then !seen.contains part && languageVariants (part :: seen) rest
    else languageExtensions [] (part :: rest)

private def languageSyntax (grandfathered : List String) (text : String) : Bool :=
  let lower := text.toLower
  if !ascii text then false else if grandfathered.contains lower then true
  else match lower.splitOn "-" with
    | "x" :: rest => !rest.isEmpty && rest.all (languageSubtag 1 8)
    | primary :: rest =>
      if !allChars asciiAlpha primary || primary.length < 2 || primary.length > 8 then false
      else
        let extended := if primary.length ≤ 3 then
          (rest.takeWhile (fun p => p.length == 3 && allChars asciiAlpha p)).take 3 else []
        let afterExtended := rest.drop extended.length
        let afterScript := match afterExtended with
          | script :: tail => if script.length == 4 && allChars asciiAlpha script then tail else afterExtended
          | [] => []
        let afterRegion := match afterScript with
          | region :: tail => if (region.length == 2 && allChars asciiAlpha region) ||
              (region.length == 3 && allChars asciiDigit region) then tail else afterScript
          | [] => []
        languageVariants [] afterRegion
    | _ => false

private def digitsNat (chars : List Char) : Option Nat :=
  if chars.isEmpty || !chars.all asciiDigit then none else (String.ofList chars).toNat?

private def leapYear (year : Nat) : Bool := year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)

private def monthDays (year month : Nat) : Nat :=
  if month == 2 then if leapYear year then 29 else 28
  else if [4, 6, 9, 11].contains month then 30 else 31

private def timestampSyntax (rule : CalendarRule) (text : String) : Bool := Id.run do
  let chars := text.toList
  if chars.length < 20 then return false
  if chars[4]? != some '-' || chars[7]? != some '-' || chars[10]? != some 'T' ||
      chars[13]? != some ':' || chars[16]? != some ':' then return false
  let some year := digitsNat (chars.take 4) | return false
  let some month := digitsNat ((chars.drop 5).take 2) | return false
  let some day := digitsNat ((chars.drop 8).take 2) | return false
  let some hour := digitsNat ((chars.drop 11).take 2) | return false
  let some minute := digitsNat ((chars.drop 14).take 2) | return false
  let some second := digitsNat ((chars.drop 17).take 2) | return false
  if year < rule.minimumYear || year > rule.maximumYear || month < 1 || month > 12 ||
      day < 1 || day > monthDays year month || hour > 23 || minute > 59 ||
      second > (if rule.allowSecond60 then 60 else 59) then return false
  let suffix := chars.drop 19
  let timezone := match suffix with
    | '.' :: rest =>
      let fraction := rest.takeWhile asciiDigit
      if fraction.isEmpty then [] else rest.drop fraction.length
    | _ => suffix
  match timezone with
  | ['Z'] => return true
  | [sign, h1, h2, ':', m1, m2] =>
    if sign != '+' && sign != '-' then return false
    let some oh := digitsNat [h1, h2] | return false
    let some om := digitsNat [m1, m2] | return false
    if oh > 23 || om > 59 || (sign == '-' && oh == 0 && om == 0) then return false
    if rule.rejectUtcYearOutsideRange then
      let precedingDays := (List.range (month - 1)).foldl (fun total index => total + monthDays year (index + 1)) 0
      let localMinutes := Int.ofNat ((precedingDays + day - 1) * 1440 + hour * 60 + minute)
      let offsetMinutes := Int.ofNat (oh * 60 + om)
      let utcMinutes := if sign == '+' then localMinutes - offsetMinutes else localMinutes + offsetMinutes
      let yearMinutes := Int.ofNat ((if leapYear year then 366 else 365) * 1440)
      if year == rule.minimumYear && utcMinutes < 0 then return false
      if year == rule.maximumYear && utcMinutes ≥ yearMinutes then return false
    return true
  | _ => return false

private def dfaAccepts (spec : DfaSpec) (text : String) : Bool :=
  let final := text.foldl (fun state c => do
    let current ← state
    if c.toNat ≥ 128 then none
    else (spec.transitions.find? (fun transition => transition.fromState == current &&
      transition.first ≤ c.toNat && c.toNat ≤ transition.last)).map (·.toState)) (some spec.initialState)
  (final.map spec.acceptingStates.contains).getD false

private def charSplits : List Char → List (List Char × List Char)
  | [] => [([], [])]
  | first :: rest =>
    ([], first :: rest) :: (charSplits rest).map fun (left, right) =>
      (first :: left, right)

private def stringSplits (text : String) : List (String × String) :=
  (charSplits text.toList).map fun (left, right) =>
    (String.ofList left, String.ofList right)

private def sequenceAcceptsWith (accepts : FormatRule → String → Bool) :
    List FormatRule → String → Bool
  | [], text => text == ""
  | first :: rest, text =>
    (stringSplits text).any fun (left, right) =>
      accepts first left && sequenceAcceptsWith accepts rest right


private def prependToFirstLabel (first : Char) : List (List Char) → List (List Char)
  | [] => [[first]]
  | label :: later => (first :: label) :: later

private def splitAtSeparator (separator : List Char) : Nat → List Char → List (List Char)
  | 0, text => [text]
  | _ + 1, [] => [[]]
  | fuel + 1, first :: rest =>
    if separator.isPrefixOf (first :: rest) then
      [] :: splitAtSeparator separator fuel ((first :: rest).drop separator.length)
    else prependToFirstLabel first (splitAtSeparator separator fuel rest)

def formatLength : StringLengthUnit → String → Nat
  | .utf8Bytes, text => utf8Length text
  | .unicodeScalars, text => text.length
  | .graphemes, text => text.length

def labelParts (separator text : String) : List String :=
  (splitAtSeparator separator.toList text.toList.length text.toList).map String.ofList

private def formatAcceptsFuel : Nat → FormatRule → String → Bool
  | 0, _, _ => false
  | fuel + 1, .literal value, text => value == text
  | fuel + 1, .sequence parts, text =>
    sequenceAcceptsWith (formatAcceptsFuel fuel) parts text
  | fuel + 1, .optional rule, text => formatAcceptsFuel fuel rule text || text == ""
  | fuel + 1, .labels separator minimum maximum total rule, text =>
    let values := labelParts separator text
    separator != "" && decide (values.length ≥ minimum) && (maximum.map (fun bound => decide (values.length ≤ bound))).getD true &&
      (total.map (fun bound => decide (text.length ≤ bound))).getD true && values.all (formatAcceptsFuel fuel rule)
  | fuel + 1, .bounded unit maximum rule, text =>
    decide (formatLength unit text ≤ maximum) && formatAcceptsFuel fuel rule text
  | _ + 1, .asciiDfa spec, text => dfaAccepts spec text
  | _ + 1, .identifier first rest exact minimum maximum forbidden, text =>
    ascii text && minimum ≤ text.length &&
      (maximum.map (fun bound => decide (text.length ≤ bound))).getD true &&
      (exact.map (· == text.length)).getD true && !forbidden.contains text &&
      match text.toList with | c :: tail => first.contains c && tail.all (fun c => rest.contains c) | _ => false
  | _ + 1, .timestamp rule, text => timestampSyntax rule text
  | _ + 1, .absoluteUri maximum, text =>
    (maximum.map (fun bound => decide (utf8Length text ≤ bound))).getD true && uriSyntax text
  | _ + 1, .languageTag grandfathered, text => languageSyntax grandfathered text
  | fuel + 1, .choice rules, text => rules.any (fun rule => formatAcceptsFuel fuel rule text)
  | fuel + 1, .text, _ => true
  | fuel + 1, .not rule, text =>
    decide (formatRuleDepth rule ≤ fuel) && !formatAcceptsFuel fuel rule text
def formatAccepts (rule : FormatRule) (text : String) : Bool :=
  formatAcceptsFuel (formatRuleDepth rule) rule text

private inductive FormatSpanNode where
  | epsilon (id : Nat)
  | literal (id : Nat) (value : Array Char)
  | text (id : Nat)
  | notN (id : Nat) (child : FormatSpanNode)
  | choiceN (id : Nat) (children : List FormatSpanNode)
  | sequenceN (id : Nat) (left right : FormatSpanNode)
  | optionalN (id : Nat) (child : FormatSpanNode)
  | labelsN (id : Nat) (separator : Array Char) (minimum : Nat)
      (maximum total : Option Nat) (child : FormatSpanNode)
  | boundedN (id : Nat) (unit : StringLengthUnit) (maximum : Nat)
      (child : FormatSpanNode)
  | leaf (id : Nat) (rule : FormatRule)

private def FormatSpanNode.id : FormatSpanNode → Nat
  | .epsilon id | .literal id _ | .text id | .notN id _ | .choiceN id _
  | .sequenceN id _ _ | .optionalN id _ | .labelsN id _ _ _ _ _
  | .boundedN id _ _ _ | .leaf id _ => id

private def freshFormatSpanId : StateM Nat Nat := do
  let id ← get
  set (id + 1)
  pure id

private def binaryFormatSequence : List FormatSpanNode → StateM Nat FormatSpanNode
  | [] => return .epsilon (← freshFormatSpanId)
  | [node] => pure node
  | node :: nodes => do
    let right ← binaryFormatSequence nodes
    return .sequenceN (← freshFormatSpanId) node right

private def compileFormatSpan : Nat → FormatRule → StateM Nat FormatSpanNode
  | 0, rule => return .leaf (← freshFormatSpanId) rule
  | fuel + 1, rule => do
    match rule with
    | .literal value => return .literal (← freshFormatSpanId) value.toList.toArray
    | .text => return .text (← freshFormatSpanId)
    | .not child =>
      return .notN (← freshFormatSpanId) (← compileFormatSpan fuel child)
    | .choice children =>
      return .choiceN (← freshFormatSpanId) (← children.mapM (compileFormatSpan fuel))
    | .sequence children =>
      binaryFormatSequence (← children.mapM (compileFormatSpan fuel))
    | .optional child =>
      return .optionalN (← freshFormatSpanId) (← compileFormatSpan fuel child)
    | .labels separator minimum maximum total child =>
      return .labelsN (← freshFormatSpanId) separator.toList.toArray minimum maximum total
        (← compileFormatSpan fuel child)
    | .bounded unit maximum child =>
      return .boundedN (← freshFormatSpanId) unit maximum (← compileFormatSpan fuel child)
    | leaf => return .leaf (← freshFormatSpanId) leaf

private def FormatSpanNode.size : FormatSpanNode → Nat
  | .epsilon _ | .literal _ _ | .text _ | .leaf _ _ => 1
  | .notN _ child | .optionalN _ child | .labelsN _ _ _ _ _ child
  | .boundedN _ _ _ child => child.size + 1
  | .choiceN _ children => children.foldl (fun size child => size + child.size) 1
  | .sequenceN _ left right => left.size + right.size + 1
private def formatSpanNodeRule : FormatSpanNode → FormatRule
  | .epsilon _ => .sequence []
  | .literal _ value => .literal (String.ofList value.toList)
  | .text _ => .text
  | .notN _ child => .not (formatSpanNodeRule child)
  | .choiceN _ children => .choice (children.map formatSpanNodeRule)
  | .sequenceN _ left right =>
    .sequence [formatSpanNodeRule left, formatSpanNodeRule right]
  | .optionalN _ child => .optional (formatSpanNodeRule child)
  | .labelsN _ separator minimum maximum total child =>
    .labels (String.ofList separator.toList) minimum maximum total (formatSpanNodeRule child)
  | .boundedN _ unit maximum child => .bounded unit maximum (formatSpanNodeRule child)
  | .leaf _ rule => rule


private structure FormatSpanContext where
  source : String
  sourceHash : UInt64
  chars : Array Char
  width : Nat

private abbrev FormatSpanMemo := Std.HashMap (Nat × Nat × Nat × UInt64) (List (String × Bool))

private def formatSpanSubstring (context : FormatSpanContext) (start finish : Nat) : String :=
  String.ofList (context.chars.extract start finish).toList

private def formatSpanLiteral (context : FormatSpanContext) (value : Array Char)
    (start finish : Nat) : Bool :=
  finish - start == value.size &&
    (List.range value.size).all fun offset =>
      context.chars[start + offset]? == value[offset]?

private def formatSpanContextOfString (text : String) : FormatSpanContext :=
  { source := text, sourceHash := String.hash text,
    chars := text.toList.toArray, width := text.length + 1 }

private theorem formatSpanContextOfString_full (text : String) :
    formatSpanSubstring (formatSpanContextOfString text) 0 text.length = text := by
  simp [formatSpanSubstring, formatSpanContextOfString, ← String.length_toList]

private def formatSpanSplitPoints (start finish : Nat) : List Nat :=
  if start ≤ finish then
    (List.range (finish - start + 1)).map fun offset => start + offset
  else []

private theorem formatSpanSplitPoints_mem (start finish split : Nat)
    (ordered : start ≤ finish) :
    split ∈ formatSpanSplitPoints start finish ↔ start ≤ split ∧ split ≤ finish := by
  unfold formatSpanSplitPoints
  rw [if_pos ordered]
  simp only [List.mem_map, List.mem_range]
  constructor
  · rintro ⟨offset, offset_lt, equal⟩
    have splitEq : split = start + offset := equal.symm
    omega
  · rintro ⟨lower, upper⟩
    refine ⟨split - start, ?_, ?_⟩ <;> omega

private theorem formatSpanSplitPoints_any (start finish : Nat) (test : Nat → Bool)
    (ordered : start ≤ finish) :
    (formatSpanSplitPoints start finish).any test = true ↔
      ∃ split, start ≤ split ∧ split ≤ finish ∧ test split = true := by
  rw [List.any_eq_true]
  constructor
  · rintro ⟨split, member, tested⟩
    have bounds := (formatSpanSplitPoints_mem start finish split ordered).mp member
    exact ⟨split, bounds.1, bounds.2, tested⟩
  · rintro ⟨split, lower, upper, tested⟩
    exact ⟨split, (formatSpanSplitPoints_mem start finish split ordered).mpr ⟨lower, upper⟩, tested⟩

private def formatSpanAndRun (left right : FormatSpanMemo → Bool × FormatSpanMemo)
    (memo : FormatSpanMemo) : Bool × FormatSpanMemo :=
  let (acceptedLeft, afterLeft) := left memo
  if acceptedLeft then right afterLeft else (false, afterLeft)

private def formatSpanAnd (left right : StateM FormatSpanMemo Bool) :
    StateM FormatSpanMemo Bool :=
  fun memo => pure (formatSpanAndRun (fun state => left.run state)
    (fun state => right.run state) memo)

private def formatSpanShortCircuitRun {α} (target : Bool)
    (check : α → FormatSpanMemo → Bool × FormatSpanMemo) :
    List α → FormatSpanMemo → Bool × FormatSpanMemo
  | [], memo => (!target, memo)
  | item :: rest, memo =>
    let (result, nextMemo) := check item memo
    if result == target then (target, nextMemo)
    else formatSpanShortCircuitRun target check rest nextMemo

private def formatSpanShortCircuit {α} (target : Bool)
    (check : α → StateM FormatSpanMemo Bool) (items : List α) :
    StateM FormatSpanMemo Bool :=
  fun memo => pure (formatSpanShortCircuitRun target
    (fun item state => (check item).run state) items memo)

private def evalFormatSpan : Nat → FormatSpanContext → FormatSpanNode →
    Nat → Nat → StateM FormatSpanMemo Bool
  | 0, _, _, _, _ => pure false
  | fuel + 1, context, node, start, finish => do
    let key := (node.id, start, finish, context.sourceHash)
    let bucket := (← get).getD key []
    if let some (_, accepted) := bucket.find? (fun (source, _) => source == context.source) then
      return accepted
    let accepted ← match node with
      | .epsilon _ => pure (start == finish)
      | .literal _ value => pure (formatSpanLiteral context value start finish)
      | .text _ => pure true
      | .notN _ child => return !(← evalFormatSpan fuel context child start finish)
      | .choiceN _ children =>
        formatSpanShortCircuit true
          (fun child => evalFormatSpan fuel context child start finish) children
      | .sequenceN _ left right =>
        formatSpanShortCircuit true (fun split =>
          formatSpanAnd (evalFormatSpan fuel context left start split)
            (evalFormatSpan fuel context right split finish))
          (formatSpanSplitPoints start finish)
      | .optionalN _ child =>
        if start == finish then pure true else evalFormatSpan fuel context child start finish
      | .labelsN _ separator minimum maximum total child => do
        if separator.isEmpty then return false
        let pieces := labelParts (String.ofList separator.toList) (formatSpanSubstring context start finish)
        if pieces.length < minimum then return false
        if let some bound := maximum then
          if pieces.length > bound then return false
        if let some bound := total then
          if finish - start > bound then return false
        formatSpanShortCircuit false (fun piece => do
          let pieceContext := formatSpanContextOfString piece
          evalFormatSpan fuel pieceContext child 0 piece.length) pieces
      | .boundedN _ unit maximum child =>
        let substring := formatSpanSubstring context start finish
        if formatLength unit substring > maximum then pure false
        else evalFormatSpan fuel context child start finish
      | .leaf _ rule =>
        pure (formatAccepts rule (formatSpanSubstring context start finish))
    modify fun memo => memo.insert key ((context.source, accepted) :: bucket)
    pure accepted
termination_by fuel _ _ _ _ => fuel

def formatAcceptsFast (rule : FormatRule) (text : String) : Bool :=
  let node := (compileFormatSpan (formatRuleDepth rule) rule).run' 0
  let context := formatSpanContextOfString text
  (evalFormatSpan node.size context node 0 context.chars.size).run' {}

private theorem sequenceAcceptsWith_mono
    (lower upper : FormatRule → String → Bool)
    (monotone : ∀ rule text, lower rule text = true → upper rule text = true)
    (rules : List FormatRule) (text : String)
    (accepted : sequenceAcceptsWith lower rules text = true) :
    sequenceAcceptsWith upper rules text = true := by
  induction rules generalizing text with
  | nil => exact accepted
  | cons first rest ih =>
    rw [sequenceAcceptsWith, List.any_eq_true] at accepted ⊢
    obtain ⟨⟨left, right⟩, split, accepted⟩ := accepted
    rw [Bool.and_eq_true] at accepted
    exact ⟨(left, right), split, by
      rw [Bool.and_eq_true]
      exact ⟨monotone first left accepted.1, ih right accepted.2⟩⟩


private theorem allChars_eq_all (test : Char → Bool) (text : String) :
    allChars test text = text.toList.all test := by
  unfold allChars
  rw [String.foldl_eq_foldl_toList]
  suffices ∀ (items : List Char) (initial : Bool),
      items.foldl (fun ok c => ok && test c) initial = (initial && items.all test) by
    simpa using this text.toList true
  intro items
  induction items with
  | nil => intro initial; simp
  | cons first rest ih => intro initial; simp [ih, Bool.and_assoc]

mutual
  private def formatRuleEqual : FormatRule → FormatRule → Bool
    | .literal a, .literal b => a == b
    | .sequence a, .sequence b => formatRulesEqual a b
    | .optional a, .optional b => formatRuleEqual a b
    | .labels a b c d e, .labels f g h i j =>
      a == f && b == g && c == h && d == i && formatRuleEqual e j
    | .bounded .utf8Bytes a b, .bounded .utf8Bytes c d =>
      a == c && formatRuleEqual b d
    | .bounded .unicodeScalars a b, .bounded .unicodeScalars c d =>
      a == c && formatRuleEqual b d
    | .asciiDfa a, .asciiDfa b => decide (a = b)
    | .identifier a b c d e f, .identifier g h i j k l =>
      decide ((a,b,c,d,e,f) = (g,h,i,j,k,l))
    | .timestamp a, .timestamp b => decide (a = b)
    | .absoluteUri a, .absoluteUri b => a == b
    | .languageTag a, .languageTag b => a == b
    | .choice a, .choice b => formatRulesEqual a b
    | .text, .text => true
    | .not a, .not b => formatRuleEqual a b
    | _, _ => false
  private def formatRulesEqual : List FormatRule → List FormatRule → Bool
    | [], [] => true
    | a :: rest, b :: later =>
      formatRuleEqual a b && formatRulesEqual rest later
    | _, _ => false
end

mutual
  private theorem formatRuleEqual_sound (source destination : FormatRule)
      (equal : formatRuleEqual source destination = true) : source = destination := by
    cases source <;> cases destination <;>
      simp_all [formatRuleEqual, Bool.and_eq_true]
    · exact formatRulesEqual_sound _ _ (by assumption)
    · exact formatRuleEqual_sound _ _ (by assumption)
    · congr
      exact formatRuleEqual_sound _ _ equal.2
    · rename_i sourceUnit _ _ destinationUnit _ _
      cases sourceUnit <;> cases destinationUnit <;>
        simp_all [formatRuleEqual, Bool.and_eq_true]
      all_goals congr
      all_goals exact formatRuleEqual_sound _ _ equal.2
    · exact formatRulesEqual_sound _ _ (by assumption)
    · exact formatRuleEqual_sound _ _ (by assumption)
  private theorem formatRulesEqual_sound (source destination : List FormatRule)
      (equal : formatRulesEqual source destination = true) : source = destination := by
    cases source <;> cases destination <;>
      simp_all [formatRulesEqual, Bool.and_eq_true]
    exact ⟨formatRuleEqual_sound _ _ equal.1, formatRulesEqual_sound _ _ equal.2⟩
end

private theorem formatRuleDepth_le_formatRulesDepth (rule : FormatRule) (rules : List FormatRule)
    (member : rule ∈ rules) : formatRuleDepth rule ≤ formatRulesDepth rules := by
  induction rules with
  | nil => simp at member
  | cons first rest ih =>
    rw [formatRulesDepth]
    rcases List.mem_cons.mp member with equal | member
    · subst rule
      exact Nat.le_max_left _ _
    · exact Nat.le_trans (ih member) (Nat.le_max_right _ _)

private theorem one_le_formatRuleDepth (rule : FormatRule) : 1 ≤ formatRuleDepth rule := by
  cases rule <;> simp only [formatRuleDepth] <;> omega

private theorem list_any_congr {α : Type} (items : List α) (left right : α → Bool)
    (same : ∀ item ∈ items, left item = right item) : items.any left = items.any right := by
  induction items with
  | nil => rfl
  | cons first rest ih =>
    simp only [List.any_cons]
    rw [same first List.mem_cons_self, ih (fun item member => same item (List.mem_cons_of_mem _ member))]

private theorem sequenceAcceptsWith_congr
    (left right : FormatRule → String → Bool) (rules : List FormatRule)
    (same : ∀ rule ∈ rules, ∀ text, left rule text = right rule text) (text : String) :
    sequenceAcceptsWith left rules text = sequenceAcceptsWith right rules text := by
  induction rules generalizing text with
  | nil => rfl
  | cons first rest ih =>
    simp only [sequenceAcceptsWith]
    exact list_any_congr _ _ _ fun pair _ => by
      rw [same first List.mem_cons_self pair.1,
        ih (fun rule member => same rule (List.mem_cons_of_mem _ member)) pair.2]

private theorem formatAcceptsFuel_stable (fuel : Nat) :
    ∀ (rule : FormatRule) (text : String) (other : Nat),
      formatRuleDepth rule ≤ fuel → formatRuleDepth rule ≤ other →
      formatAcceptsFuel fuel rule text = formatAcceptsFuel other rule text := by
  induction fuel with
  | zero =>
    intro rule text other low _
    have := one_le_formatRuleDepth rule
    omega
  | succ fuel ih =>
    intro rule text other low high
    cases other with
    | zero =>
      have := one_le_formatRuleDepth rule
      omega
    | succ other =>
      cases rule with
      | literal value => rfl
      | sequence rules =>
        simp only [formatRuleDepth] at low high
        simp only [formatAcceptsFuel]
        exact sequenceAcceptsWith_congr _ _ rules (fun member memberOf text =>
          ih member text other
            (Nat.le_trans (formatRuleDepth_le_formatRulesDepth member rules memberOf) (by omega))
            (Nat.le_trans (formatRuleDepth_le_formatRulesDepth member rules memberOf) (by omega))) text
      | optional part =>
        simp only [formatRuleDepth] at low high
        simp only [formatAcceptsFuel]
        rw [ih part text other (by omega) (by omega)]
      | labels separator minimum maximum total part =>
        simp only [formatRuleDepth] at low high
        have same : formatAcceptsFuel fuel part = formatAcceptsFuel other part :=
          funext fun label => ih part label other (by omega) (by omega)
        simp only [formatAcceptsFuel]
        rw [same]
      | bounded unit maximum part =>
        simp only [formatRuleDepth] at low high
        simp only [formatAcceptsFuel]
        rw [ih part text other (by omega) (by omega)]
      | asciiDfa spec => rfl
      | identifier first rest exactLength minimum maximum forbidden => rfl
      | timestamp calendar => rfl
      | absoluteUri maximum => rfl
      | languageTag grandfathered => rfl
      | text => rfl
      | not part =>
        simp only [formatRuleDepth] at low high
        simp only [formatAcceptsFuel]
        rw [ih part text other (by omega) (by omega)]
        simp [show formatRuleDepth part ≤ fuel by omega, show formatRuleDepth part ≤ other by omega]
      | choice rules =>
        simp only [formatRuleDepth] at low high
        simp only [formatAcceptsFuel]
        exact list_any_congr rules _ _ (fun member memberOf =>
          ih member text other
            (Nat.le_trans (formatRuleDepth_le_formatRulesDepth member rules memberOf) (by omega))
            (Nat.le_trans (formatRuleDepth_le_formatRulesDepth member rules memberOf) (by omega)))

private theorem formatAcceptsFuel_mono (lower upper : Nat) (rule : FormatRule) (text : String)
    (fuel : lower ≤ upper)
    (accepted : formatAcceptsFuel lower rule text = true) :
    formatAcceptsFuel upper rule text = true := by
  induction lower generalizing upper rule text with
  | zero => simp [formatAcceptsFuel] at accepted
  | succ lower ih =>
    cases upper with
    | zero => omega
    | succ upper =>
      have fuel' : lower ≤ upper := Nat.succ_le_succ_iff.mp fuel
      cases rule with
      | literal value => exact accepted
      | sequence rules =>
        exact sequenceAcceptsWith_mono _ _
          (fun rule text accepted => ih upper rule text fuel' accepted) rules text accepted
      | optional rule =>
        rw [formatAcceptsFuel, Bool.or_eq_true] at accepted ⊢
        exact accepted.elim
          (fun accepted => Or.inl (ih upper rule text fuel' accepted))
          Or.inr
      | labels separator minimum maximum total rule =>
        simp only [formatAcceptsFuel, Bool.and_eq_true, List.all_eq_true] at accepted ⊢
        exact ⟨accepted.1,
          fun value member => ih upper rule value fuel' (accepted.2 value member)⟩
      | bounded unit maximum rule =>
        cases unit <;> simp only [formatAcceptsFuel, Bool.and_eq_true] at accepted ⊢
        all_goals exact ⟨accepted.1, ih upper rule text fuel' accepted.2⟩
      | asciiDfa spec => exact accepted
      | identifier first rest exactLength minimum maximum forbidden => exact accepted
      | timestamp timestampRule => exact accepted
      | absoluteUri maximum => exact accepted
      | languageTag grandfathered => exact accepted
      | choice rules =>
        rw [formatAcceptsFuel, List.any_eq_true] at accepted ⊢
        obtain ⟨branch, member, accepted⟩ := accepted
        exact ⟨branch, member, ih upper branch text fuel' accepted⟩
      | text => exact accepted
      | not part =>
        simp only [formatAcceptsFuel, Bool.and_eq_true, decide_eq_true_eq, Bool.not_eq_true'] at accepted ⊢
        exact ⟨Nat.le_trans accepted.1 fuel', by
          rw [← formatAcceptsFuel_stable lower part text upper accepted.1 (Nat.le_trans accepted.1 fuel')]
          exact accepted.2⟩

private theorem formatAcceptsFuel_eq_formatAccepts (fuel : Nat) (rule : FormatRule) (text : String)
    (enough : formatRuleDepth rule ≤ fuel) :
    formatAcceptsFuel fuel rule text = formatAccepts rule text :=
  formatAcceptsFuel_stable fuel rule text _ enough (Nat.le_refl _)

private theorem charSplits_mem (text left right : List Char) :
    (left, right) ∈ charSplits text ↔ text = left ++ right := by
  induction text generalizing left right with
  | nil =>
    simp only [charSplits, List.mem_singleton, Prod.mk.injEq]
    constructor
    · rintro ⟨rfl, rfl⟩; rfl
    · intro equal
      exact ⟨(List.append_eq_nil_iff.mp equal.symm).1, (List.append_eq_nil_iff.mp equal.symm).2⟩
  | cons first rest ih =>
    simp only [charSplits, List.mem_cons, List.mem_map, Prod.mk.injEq, Prod.exists]
    constructor
    · rintro (⟨rfl, rfl⟩ | ⟨a, b, member, rfl, rfl⟩)
      · rfl
      · simp [(ih a b).mp member]
    · intro equal
      cases left with
      | nil => exact Or.inl ⟨rfl, by simpa using equal.symm⟩
      | cons head tail =>
        right
        simp only [List.cons_append, List.cons.injEq] at equal
        exact ⟨tail, right, (ih tail right).mpr equal.2, by rw [equal.1], rfl⟩

private theorem stringSplits_mem (text left right : String) :
    (left, right) ∈ stringSplits text ↔ text = left ++ right := by
  unfold stringSplits
  simp only [List.mem_map, Prod.mk.injEq, Prod.exists]
  constructor
  · rintro ⟨a, b, member, rfl, rfl⟩
    have := (charSplits_mem text.toList a b).mp member
    apply String.toList_inj.mp
    simpa using this
  · intro equal
    refine ⟨left.toList, right.toList, (charSplits_mem _ _ _).mpr ?_, by simp, by simp⟩
    rw [equal]
    simp

theorem formatAccepts_literal (value text : String) :
    formatAccepts (.literal value) text = decide (text = value) := by
  simp only [formatAccepts, formatRuleDepth, formatAcceptsFuel]
  by_cases same : text = value
  · subst same
    simp
  · have other : value ≠ text := fun equal => same equal.symm
    simp [same, other]

theorem formatAccepts_optional (rule : FormatRule) (text : String) :
    formatAccepts (.optional rule) text = (text == "" || formatAccepts rule text) := by
  simp only [formatAccepts, formatRuleDepth, Nat.one_add, formatAcceptsFuel]
  exact Bool.or_comm _ _

theorem formatAccepts_sequence_nil (text : String) :
    formatAccepts (.sequence []) text = (text == "") := by
  simp [formatAccepts, formatRuleDepth, formatRulesDepth, formatAcceptsFuel, sequenceAcceptsWith]

private theorem formatAccepts_sequence_eq (rules : List FormatRule) (text : String) :
    formatAccepts (.sequence rules) text =
      sequenceAcceptsWith (formatAcceptsFuel (formatRulesDepth rules)) rules text := by
  simp only [formatAccepts, formatRuleDepth, Nat.one_add, formatAcceptsFuel]

theorem formatAccepts_sequence_cons (rule : FormatRule) (rules : List FormatRule) (text : String) :
    formatAccepts (.sequence (rule :: rules)) text = true ↔
      ∃ left right, text = left ++ right ∧ formatAccepts rule left = true ∧
        formatAccepts (.sequence rules) right = true := by
  have rest : ∀ fuel, formatRulesDepth rules ≤ fuel → ∀ right,
      sequenceAcceptsWith (formatAcceptsFuel fuel) rules right = formatAccepts (.sequence rules) right := by
    intro fuel enough right
    rw [formatAccepts_sequence_eq]
    exact sequenceAcceptsWith_congr _ _ rules (fun member memberOf text =>
      formatAcceptsFuel_stable _ member text _
        (Nat.le_trans (formatRuleDepth_le_formatRulesDepth member rules memberOf) enough)
        (Nat.le_trans (formatRuleDepth_le_formatRulesDepth member rules memberOf) (Nat.le_refl _))) right
  rw [formatAccepts_sequence_eq (rule :: rules) text]
  simp only [formatRulesDepth, sequenceAcceptsWith, List.any_eq_true, Bool.and_eq_true, Prod.exists]
  constructor
  · rintro ⟨left, right, member, accepted, tail⟩
    refine ⟨left, right, (stringSplits_mem _ _ _).mp member, ?_, ?_⟩
    · rw [← formatAcceptsFuel_eq_formatAccepts _ rule left (Nat.le_max_left _ _)]
      exact accepted
    · rw [← rest _ (Nat.le_max_right _ _) right]
      exact tail
  · rintro ⟨left, right, equal, accepted, tail⟩
    refine ⟨left, right, (stringSplits_mem _ _ _).mpr equal, ?_, ?_⟩
    · rw [formatAcceptsFuel_eq_formatAccepts _ rule left (Nat.le_max_left _ _)]
      exact accepted
    · rw [rest _ (Nat.le_max_right _ _) right]
      exact tail

theorem formatAccepts_labels (separator : String) (minimum : Nat) (maximum total : Option Nat)
    (rule : FormatRule) (text : String) :
    formatAccepts (.labels separator minimum maximum total rule) text = true ↔
      separator ≠ "" ∧ minimum ≤ (labelParts separator text).length ∧
      (∀ bound, maximum = some bound → (labelParts separator text).length ≤ bound) ∧
      (∀ bound, total = some bound → text.length ≤ bound) ∧
      ∀ label ∈ labelParts separator text, formatAccepts rule label = true := by
  simp only [formatAccepts, formatRuleDepth, Nat.one_add, formatAcceptsFuel, Bool.and_eq_true,
    List.all_eq_true, bne_iff_ne, ne_eq, decide_eq_true_eq, ge_iff_le]
  cases maximum <;> cases total <;> simp [and_assoc]

theorem formatAccepts_bounded (unit : StringLengthUnit) (maximum : Nat) (rule : FormatRule) (text : String) :
    formatAccepts (.bounded unit maximum rule) text =
      (decide (formatLength unit text ≤ maximum) && formatAccepts rule text) := by
  simp only [formatAccepts, formatRuleDepth, Nat.one_add, formatAcceptsFuel]

theorem formatAccepts_text (text : String) : formatAccepts .text text = true := by
  simp [formatAccepts, formatRuleDepth, formatAcceptsFuel]

theorem formatAccepts_not (rule : FormatRule) (text : String) :
    formatAccepts (.not rule) text = !formatAccepts rule text := by
  simp only [formatAccepts, formatRuleDepth, Nat.add_comm 1, formatAcceptsFuel, Nat.le_refl, decide_true,
    Bool.true_and]

private theorem formatAccepts_choice (rules : List FormatRule) (text : String) :
    formatAccepts (.choice rules) text =
      rules.any (fun rule => formatAccepts rule text) := by
  simp only [formatAccepts, formatRuleDepth, Nat.one_add, formatAcceptsFuel]
  apply list_any_congr
  intro rule member
  exact formatAcceptsFuel_stable (formatRulesDepth rules) rule text
    (formatRuleDepth rule)
    (formatRuleDepth_le_formatRulesDepth rule rules member) (Nat.le_refl _)

private theorem formatAccepts_sequence_singleton (rule : FormatRule) (text : String) :
    formatAccepts (.sequence [rule]) text = formatAccepts rule text := by
  apply (Bool.eq_iff_iff).2
  rw [formatAccepts_sequence_cons]
  constructor
  · rintro ⟨left, right, split, acceptedLeft, acceptedRight⟩
    rw [formatAccepts_sequence_nil] at acceptedRight
    have rightEmpty : right = "" := by simpa using acceptedRight
    subst right
    have leftText : left = text := by simpa using split.symm
    subst left
    exact acceptedLeft
  · intro accepted
    exact ⟨text, "", by simp, accepted, by simp [formatAccepts_sequence_nil]⟩

private theorem formatSpanNodeMeaning_epsilon (id : Nat) (text : String) :
    formatAccepts (formatSpanNodeRule (.epsilon id)) text = (text == "") := by
  simp [formatSpanNodeRule, formatAccepts_sequence_nil]

private theorem formatSpanNodeMeaning_literal (id : Nat) (value : Array Char)
    (text : String) :
    formatAccepts (formatSpanNodeRule (.literal id value)) text =
      decide (text = String.ofList value.toList) := by
  simp [formatSpanNodeRule, formatAccepts_literal]

private theorem formatSpanNodeMeaning_text (id : Nat) (text : String) :
    formatAccepts (formatSpanNodeRule (.text id)) text = true := by
  simp [formatSpanNodeRule, formatAccepts_text]

private theorem formatSpanNodeMeaning_not (id : Nat) (child : FormatSpanNode)
    (text : String) :
    formatAccepts (formatSpanNodeRule (.notN id child)) text =
      !formatAccepts (formatSpanNodeRule child) text := by
  simp [formatSpanNodeRule, formatAccepts_not]

private theorem formatSpanNodeMeaning_choice (id : Nat) (children : List FormatSpanNode)
    (text : String) :
    formatAccepts (formatSpanNodeRule (.choiceN id children)) text =
      children.any (fun child => formatAccepts (formatSpanNodeRule child) text) := by
  simpa [formatSpanNodeRule, Function.comp_def] using
    formatAccepts_choice (children.map formatSpanNodeRule) text

private theorem formatSpanNodeMeaning_sequence (id : Nat)
    (left right : FormatSpanNode) (text : String) :
    formatAccepts (formatSpanNodeRule (.sequenceN id left right)) text =
      (stringSplits text).any fun (before, after) =>
        formatAccepts (formatSpanNodeRule left) before &&
          formatAccepts (formatSpanNodeRule right) after := by
  apply (Bool.eq_iff_iff).2
  rw [formatSpanNodeRule, formatAccepts_sequence_cons, List.any_eq_true]
  constructor
  · rintro ⟨before, after, split, acceptedLeft, acceptedRight⟩
    rw [formatAccepts_sequence_singleton] at acceptedRight
    exact ⟨(before, after), (stringSplits_mem _ _ _).mpr split,
      by simp [acceptedLeft, acceptedRight]⟩
  · rintro ⟨⟨before, after⟩, member, accepted⟩
    rw [Bool.and_eq_true] at accepted
    refine ⟨before, after, (stringSplits_mem _ _ _).mp member, accepted.1, ?_⟩
    rw [formatAccepts_sequence_singleton]
    exact accepted.2

private theorem formatSpanNodeMeaning_optional (id : Nat) (child : FormatSpanNode)
    (text : String) :
    formatAccepts (formatSpanNodeRule (.optionalN id child)) text =
      (text == "" || formatAccepts (formatSpanNodeRule child) text) := by
  simpa [formatSpanNodeRule] using formatAccepts_optional (formatSpanNodeRule child) text

private theorem formatSpanNodeMeaning_labels (id : Nat) (separator : Array Char)
    (minimum : Nat) (maximum total : Option Nat) (child : FormatSpanNode) (text : String) :
    formatAccepts (formatSpanNodeRule (.labelsN id separator minimum maximum total child)) text = true ↔
      String.ofList separator.toList ≠ "" ∧
        minimum ≤ (labelParts (String.ofList separator.toList) text).length ∧
        (∀ bound, maximum = some bound →
          (labelParts (String.ofList separator.toList) text).length ≤ bound) ∧
        (∀ bound, total = some bound → text.length ≤ bound) ∧
        ∀ label ∈ labelParts (String.ofList separator.toList) text,
          formatAccepts (formatSpanNodeRule child) label = true := by
  simpa [formatSpanNodeRule] using
    formatAccepts_labels (String.ofList separator.toList) minimum maximum total
      (formatSpanNodeRule child) text

private theorem formatSpanNodeMeaning_bounded (id : Nat) (unit : StringLengthUnit)
    (maximum : Nat) (child : FormatSpanNode) (text : String) :
    formatAccepts (formatSpanNodeRule (.boundedN id unit maximum child)) text =
      (decide (formatLength unit text ≤ maximum) &&
        formatAccepts (formatSpanNodeRule child) text) := by
  simpa [formatSpanNodeRule] using
    formatAccepts_bounded unit maximum (formatSpanNodeRule child) text

private theorem formatSpanNodeMeaning_leaf (id : Nat) (rule : FormatRule) (text : String) :
    formatAccepts (formatSpanNodeRule (.leaf id rule)) text = formatAccepts rule text := by
  simp [formatSpanNodeRule]

private def FormatSpanNodeEquivalent (node : FormatSpanNode) (rule : FormatRule) : Prop :=
  ∀ text, formatAccepts (formatSpanNodeRule node) text = formatAccepts rule text

private inductive FormatSpanNodesEquivalent : List FormatSpanNode → List FormatRule → Prop
  | nil : FormatSpanNodesEquivalent [] []
  | cons : FormatSpanNodeEquivalent node rule →
      FormatSpanNodesEquivalent nodes rules →
      FormatSpanNodesEquivalent (node :: nodes) (rule :: rules)

private theorem binaryFormatSequence_meaning (nodes : List FormatSpanNode)
    (rules : List FormatRule) (equivalent : FormatSpanNodesEquivalent nodes rules)
    (initial : Nat) (text : String) :
    formatAccepts (formatSpanNodeRule ((binaryFormatSequence nodes).run initial).1) text =
      formatAccepts (.sequence rules) text := by
  induction equivalent generalizing initial text with
  | nil =>
    change formatAccepts (formatSpanNodeRule (.epsilon initial)) text =
      formatAccepts (.sequence []) text
    rw [formatSpanNodeMeaning_epsilon, formatAccepts_sequence_nil]
  | cons head tail ih =>
    cases tail with
    | nil =>
      change formatAccepts (formatSpanNodeRule _) text =
        formatAccepts (.sequence [_]) text
      rw [formatAccepts_sequence_singleton]
      exact head text
    | @cons next nextRule nodes rules nextHead rest =>
      change formatAccepts
          (formatSpanNodeRule
            (.sequenceN _ _ ((binaryFormatSequence (next :: nodes)).run initial).1)) text =
        formatAccepts (.sequence (_ :: nextRule :: rules)) text
      apply (Bool.eq_iff_iff).2
      rw [formatSpanNodeRule, formatAccepts_sequence_cons, formatAccepts_sequence_cons]
      constructor
      · rintro ⟨left, right, split, acceptedLeft, acceptedRight⟩
        rw [formatAccepts_sequence_singleton] at acceptedRight
        exact ⟨left, right, split, by rw [← head left]; exact acceptedLeft,
          by rw [← ih initial right]; exact acceptedRight⟩
      · rintro ⟨left, right, split, acceptedLeft, acceptedRight⟩
        refine ⟨left, right, split, by rw [head left]; exact acceptedLeft, ?_⟩
        rw [formatAccepts_sequence_singleton, ih initial right]
        exact acceptedRight

private theorem formatAccepts_choice_of_equivalent (nodes : List FormatSpanNode)
    (rules : List FormatRule) (equivalent : FormatSpanNodesEquivalent nodes rules)
    (text : String) :
    formatAccepts (.choice (nodes.map formatSpanNodeRule)) text =
      formatAccepts (.choice rules) text := by
  induction equivalent with
  | nil => rfl
  | cons head tail ih =>
    rw [formatAccepts_choice, formatAccepts_choice]
    simp only [List.map, List.any_cons]
    rw [head text]
    rw [formatAccepts_choice, formatAccepts_choice] at ih
    exact congrArg (fun accepted => formatAccepts _ text || accepted) ih

private theorem compileFormatSpan_meaning (fuel : Nat) (rule : FormatRule)
    (initial : Nat) (text : String) :
    formatAccepts (formatSpanNodeRule ((compileFormatSpan fuel rule).run initial).1) text =
      formatAccepts rule text := by
  induction fuel generalizing rule initial text with
  | zero =>
    change formatAccepts (formatSpanNodeRule (.leaf initial rule)) text =
      formatAccepts rule text
    exact formatSpanNodeMeaning_leaf initial rule text
  | succ fuel ih =>
    have compileList : ∀ (rules : List FormatRule) (initial : Nat),
        FormatSpanNodesEquivalent
          ((rules.mapM (compileFormatSpan fuel)).run initial).1 rules := by
      intro rules initial
      induction rules generalizing initial with
      | nil =>
        change FormatSpanNodesEquivalent [] []
        exact .nil
      | cons first rest listIH =>
        rw [List.mapM_cons]
        simp only [StateT.run_bind, StateT.run_pure]
        change FormatSpanNodesEquivalent
          (((compileFormatSpan fuel first).run initial).1 ::
            ((rest.mapM (compileFormatSpan fuel)).run
              ((compileFormatSpan fuel first).run initial).2).1)
          (first :: rest)
        exact .cons (ih first initial) (listIH _)
    cases rule with
    | literal value =>
      change formatAccepts
          (formatSpanNodeRule (.literal initial value.toList.toArray)) text =
        formatAccepts (.literal value) text
      simp [formatSpanNodeRule]
    | text =>
      change formatAccepts (formatSpanNodeRule (.text initial)) text =
        formatAccepts .text text
      simp [formatSpanNodeRule]
    | not child =>
      simp only [compileFormatSpan, freshFormatSpanId, StateT.run_bind, StateT.run_pure]
      change formatAccepts
          (formatSpanNodeRule
            (.notN _ ((compileFormatSpan fuel child).run (initial + 1)).1)) text =
        formatAccepts (.not child) text
      rw [formatSpanNodeMeaning_not, formatAccepts_not, ih child (initial + 1) text]
    | choice children =>
      simp only [compileFormatSpan, freshFormatSpanId, StateT.run_bind, StateT.run_pure]
      change formatAccepts
          (formatSpanNodeRule
            (.choiceN _
              ((children.mapM (compileFormatSpan fuel)).run (initial + 1)).1)) text =
        formatAccepts (.choice children) text
      simpa [formatSpanNodeRule] using
        formatAccepts_choice_of_equivalent _ children
          (compileList children (initial + 1)) text
    | sequence children =>
      simp only [compileFormatSpan, StateT.run_bind]
      exact binaryFormatSequence_meaning _ children (compileList children initial)
        ((children.mapM (compileFormatSpan fuel)).run initial).2 text
    | optional child =>
      simp only [compileFormatSpan, freshFormatSpanId, StateT.run_bind, StateT.run_pure]
      change formatAccepts
          (formatSpanNodeRule
            (.optionalN _ ((compileFormatSpan fuel child).run (initial + 1)).1)) text =
        formatAccepts (.optional child) text
      rw [formatSpanNodeMeaning_optional, formatAccepts_optional,
        ih child (initial + 1) text]
    | labels separator minimum maximum total child =>
      simp only [compileFormatSpan, freshFormatSpanId, StateT.run_bind, StateT.run_pure]
      change formatAccepts
          (formatSpanNodeRule
            (.labelsN _ separator.toList.toArray minimum maximum total
              ((compileFormatSpan fuel child).run (initial + 1)).1)) text =
        formatAccepts (.labels separator minimum maximum total child) text
      simp only [formatSpanNodeRule]
      apply (Bool.eq_iff_iff).2
      rw [formatAccepts_labels, formatAccepts_labels]
      simp only [ih child (initial + 1), String.ofList_toList]
    | bounded unit maximum child =>
      simp only [compileFormatSpan, freshFormatSpanId, StateT.run_bind, StateT.run_pure]
      change formatAccepts
          (formatSpanNodeRule
            (.boundedN _ unit maximum
              ((compileFormatSpan fuel child).run (initial + 1)).1)) text =
        formatAccepts (.bounded unit maximum child) text
      rw [formatSpanNodeMeaning_bounded, formatAccepts_bounded,
        ih child (initial + 1) text]
    | asciiDfa spec =>
      change formatAccepts (formatSpanNodeRule (.leaf initial (.asciiDfa spec))) text =
        formatAccepts (.asciiDfa spec) text
      simp [formatSpanNodeRule]
    | identifier first rest exact minimum maximum forbidden =>
      change formatAccepts
          (formatSpanNodeRule
            (.leaf initial (.identifier first rest exact minimum maximum forbidden))) text =
        formatAccepts (.identifier first rest exact minimum maximum forbidden) text
      simp [formatSpanNodeRule]
    | timestamp timestampRule =>
      change formatAccepts
          (formatSpanNodeRule (.leaf initial (.timestamp timestampRule))) text =
        formatAccepts (.timestamp timestampRule) text
      simp [formatSpanNodeRule]
    | absoluteUri maximum =>
      change formatAccepts
          (formatSpanNodeRule (.leaf initial (.absoluteUri maximum))) text =
        formatAccepts (.absoluteUri maximum) text
      simp [formatSpanNodeRule]
    | languageTag grandfathered =>
      change formatAccepts
          (formatSpanNodeRule (.leaf initial (.languageTag grandfathered))) text =
        formatAccepts (.languageTag grandfathered) text
      simp [formatSpanNodeRule]

theorem formatAcceptsFuel_not_of_insufficient (fuel : Nat) (rule : FormatRule) (text : String)
    (insufficient : fuel < formatRuleDepth rule + 1) :
    formatAcceptsFuel fuel (.not rule) text = false := by
  cases fuel with
  | zero => rfl
  | succ fuel =>
    simp only [formatAcceptsFuel, Bool.and_eq_false_iff, decide_eq_false_iff_not]
    left
    omega

private def formatRuleIncludedFuel : Nat → FormatRule → FormatRule → Bool
  | 0, source, destination => formatRuleEqual source destination
  | fuel + 1, source, destination =>
    formatRuleEqual source destination ||
      match destination with
      | .text => true
      | .choice rules => rules.any (formatRuleIncludedFuel fuel source)
      | _ => false

def formatRuleIncluded (source destination : FormatRule) : Bool :=
  formatRuleIncludedFuel (formatRuleDepth destination + 1) source destination

private theorem formatRuleIncludedFuel_sound (fuel : Nat) (source destination : FormatRule)
    (text : String) (included : formatRuleIncludedFuel fuel source destination = true)
    (accepted : formatAccepts source text = true) : formatAccepts destination text = true := by
  induction fuel generalizing destination with
  | zero =>
    have equal := formatRuleEqual_sound source destination included
    subst destination
    exact accepted
  | succ fuel ih =>
    by_cases equal : formatRuleEqual source destination = true
    · have same := formatRuleEqual_sound source destination equal
      subst destination
      exact accepted
    · cases destination with
      | choice rules =>
        simp only [formatRuleIncludedFuel, equal, Bool.false_or, List.any_eq_true] at included
        obtain ⟨rule, member, branch⟩ := included
        rw [formatAccepts_choice, List.any_eq_true]
        exact ⟨rule, member, ih rule branch⟩
      | text => exact formatAccepts_text text
      | literal value => simp [formatRuleIncludedFuel, equal] at included
      | sequence parts => simp [formatRuleIncludedFuel, equal] at included
      | optional rule => simp [formatRuleIncludedFuel, equal] at included
      | labels separator minimum maximum total rule =>
        simp [formatRuleIncludedFuel, equal] at included
      | bounded unit maximum rule => simp [formatRuleIncludedFuel, equal] at included
      | asciiDfa spec => simp [formatRuleIncludedFuel, equal] at included
      | identifier first rest exact minimum maximum forbidden =>
        simp [formatRuleIncludedFuel, equal] at included
      | timestamp calendar => simp [formatRuleIncludedFuel, equal] at included
      | absoluteUri maximum => simp [formatRuleIncludedFuel, equal] at included
      | languageTag grandfathered => simp [formatRuleIncludedFuel, equal] at included
      | not rule => simp [formatRuleIncludedFuel, equal] at included

theorem formatRuleIncluded_sound (source destination : FormatRule) (text : String)
    (included : formatRuleIncluded source destination = true)
    (accepted : formatAccepts source text = true) : formatAccepts destination text = true :=
  formatRuleIncludedFuel_sound (formatRuleDepth destination + 1) source destination text
    included accepted

private def decimalIntegerParts (text : String) : Option (Int × Nat × Int) :=
  if text.trimAscii.toString != text || text.startsWith "+" then none
  else
    match Lean.Json.parse text with
    | .ok (.num number) =>
      let (sign, digits, power) := number.normalize
      if digits == 0 || power >= Int.ofNat (toString digits).length then
        some (sign, digits, power)
      else none
    | _ => none

private def decimalInteger (text : String) : Option Int := do
  let (sign, digits, power) ← decimalIntegerParts text
  let shift := power - Int.ofNat (toString digits).length
  let magnitude := if digits == 0 then 0 else digits * 10 ^ shift.toNat
  some (sign * Int.ofNat magnitude)

def integerValueForForm (form : IntegerForm) (value : JsonValue) : Option Int :=
  match form, value with
  | .number, .num integer => some integer
  | .integralDecimal, .dec text => decimalInteger text
  | .decimalString, .str text => decimalInteger text
  | _, _ => none

def integerBinding (profile : VersionedSemanticProfile)
    (domain : Option String) : Option IntegerDomainBinding :=
  let name := domain.getD profile.defaultIntegerDomain
  profile.integerDomains.find? (fun binding => binding.name == name)

def integerValueForBinding (binding : IntegerDomainBinding)
    (value : JsonValue) : Option Int :=
  binding.forms.findSome? (fun form => integerValueForForm form value)

def integerRangeAccepts (range : IntegerDomain) (value : Int) : Bool :=
  match range with
  | .unbounded => true
  | .inclusive minimum maximum => minimum ≤ value && value ≤ maximum

private def jsonDigit (character : Char) : Bool :=
  '0' ≤ character && character ≤ '9'

private def jsonWholeNumber (characters : List Char) : Bool :=
  match characters with
  | [] => false
  | '0' :: rest => rest.isEmpty
  | first :: rest => '1' ≤ first && first ≤ '9' && rest.all jsonDigit

private def decimalMagnitudeExceedsRangeDigits (minimum maximum : Int) (text : String) : Bool :=
  let unsigned := if text.startsWith "-" then (text.drop 1).toString else text
  if unsigned.startsWith "+" then false
  else
    let lowercaseParts := unsigned.splitOn "e"
    let parts := if lowercaseParts.length = 2 then lowercaseParts else unsigned.splitOn "E"
    match parts with
    | [base, exponentText] =>
      let exponentDigits :=
        if exponentText.startsWith "+" then (exponentText.drop 1).toString else exponentText
      if exponentDigits.startsWith "-" || exponentDigits.isEmpty ||
          !(exponentDigits.toList.all jsonDigit) then false
      else
        match exponentDigits.toNat? with
        | none => false
        | some exponent =>
          match base.splitOn "." with
          | [whole] =>
            if !jsonWholeNumber whole.toList then false
            else
              let significantDigits := (whole.toList.dropWhile (· == '0')).length
              if significantDigits = 0 then false
              else
                let limit := max minimum.natAbs maximum.natAbs
                significantDigits + exponent > (toString limit).length
          | [whole, fraction] =>
            if !jsonWholeNumber whole.toList || fraction.isEmpty ||
                !(fraction.toList.all jsonDigit) || exponent < fraction.length then false
            else
              let digits := whole.toList ++ fraction.toList
              let significantDigits := (digits.dropWhile (· == '0')).length
              if significantDigits = 0 then false
              else
                let limit := max minimum.natAbs maximum.natAbs
                significantDigits + exponent - fraction.length > (toString limit).length
          | _ => false
    | _ => false

def integerValueForBindingInRange (binding : IntegerDomainBinding)
    (value : JsonValue) : Option (Option Int) :=
  match binding.range with
  | .unbounded => (integerValueForBinding binding value).map some
  | range@(.inclusive minimum maximum) =>
    let exceedsRangeDigits :=
      match value with
      | .dec text =>
        binding.forms.contains .integralDecimal &&
          decimalMagnitudeExceedsRangeDigits minimum maximum text
      | .str text =>
        binding.forms.contains .decimalString &&
          decimalMagnitudeExceedsRangeDigits minimum maximum text
      | _ => false
    if exceedsRangeDigits then some none
    else
      match integerValueForBinding binding value with
      | none => none
      | some integer =>
        if integerRangeAccepts range integer then some (some integer) else some none

@[simp] theorem integerValueForBindingInRange_number (binding : IntegerDomainBinding)
    (value : Int) :
    integerValueForBindingInRange binding (.num value) =
      (integerValueForBinding binding (.num value)).map fun integer =>
        if integerRangeAccepts binding.range integer then some integer else none := by
  cases range : binding.range <;>
    cases parsed : integerValueForBinding binding (.num value) <;>
    simp [integerValueForBindingInRange, integerRangeAccepts, range, parsed] <;>
    (repeat' split) <;> simp_all

def integerInDomain (profile : VersionedSemanticProfile) (domain : Option String)
    (value : JsonValue) : Bool :=
  match integerBinding profile domain with
  | none => false
  | some binding => (integerValueForBindingInRange binding value).any Option.isSome
def integerCondition (profile : VersionedSemanticProfile) (spec : IntegerSpec)
    (value : JsonValue) : Option ValueCondition :=
  match integerBinding profile spec.domain with
  | none => some .integerDomain
  | some binding =>
    match integerValueForBindingInRange binding value with
    | none => some (.wrongValueKind "integer")
    | some none => some .integerDomain
    | some (some integer) =>
      if (spec.constValue.map (· != integer)).getD false then some .constMismatch
      else if (spec.enumValues.map (fun values => !values.contains integer)).getD false then
        some .enumMismatch
      else if (spec.minimum.map (fun minimum => decide (integer < minimum))).getD false then
        some .belowMinimum
      else if (spec.maximum.map (fun maximum => decide (maximum < integer))).getD false then
        some .aboveMaximum
      else none

def lengthAccepts (minimum maximum : Option Nat) (length : Nat) : Bool :=
  (minimum.map (fun n => decide (n ≤ length))).getD true &&
    (maximum.map (fun n => decide (length ≤ n))).getD true
def lengthInUnit (profile : VersionedSemanticProfile) (unit : StringLengthUnit)
    (value : String) : Option Nat :=
  match unit with
  | .utf8Bytes => some (utf8Length value)
  | .unicodeScalars => some value.length
  | .graphemes => profile.graphemeRules.map (fun rules => graphemeLength rules value)

def lengthBoundsFailure (profile : VersionedSemanticProfile) (value : String) :
    List LengthBound → Option ValueCondition
  | [] => none
  | bound :: rest =>
    match lengthInUnit profile bound.unit value with
    | none => some .stringLength
    | some length =>
      if lengthAccepts bound.minimum bound.maximum length then
        lengthBoundsFailure profile value rest
      else some .stringLength


def duplicateKey (members : List (String × JsonValue)) : Option String :=
  Necoherence.ExactJson.firstRepeated [] (members.map (·.1))



private def mimeMatches (pattern mime : String) : Bool :=
  if pattern == "*/*" then mime != ""
  else if pattern.endsWith "/*" then mime.startsWith (String.ofList (pattern.toList.dropLast))
  else pattern == mime


def classOf (profile : VersionedSemanticProfile)
    (members : List (String × JsonValue)) : ObjectClass :=
  match profile.tag with
  | some tag =>
    match memberValue tag.key members with
    | some (.str value) =>
      match tag.sealed.find? (fun form => form.tag == value) with
      | some form => .sealed form
      | none =>
        match profile.wrappers.find? (fun wrapper =>
            (memberValue wrapper.key members).isSome) with
        | some wrapper => .wrapper wrapper
        | none => .ordinary
    | _ =>
      match profile.wrappers.find? (fun wrapper =>
          (memberValue wrapper.key members).isSome) with
      | some wrapper => .wrapper wrapper
      | none => .ordinary
  | none =>
    match profile.wrappers.find? (fun wrapper =>
        (memberValue wrapper.key members).isSome) with
    | some wrapper => .wrapper wrapper
    | none => .ordinary

private def namedFormatAccepts (profile : VersionedSemanticProfile)
    (name : String) (value : String) : Bool :=
  match profile.formatBindings.find? (fun binding => binding.name == name) with
  | some binding => formatAcceptsFast binding.rule value
  | none => false

def wrapperPayloadText (profile : VersionedSemanticProfile)
    (wrapper : Wrapper) (value : JsonValue) : Option String := do
  let .obj [(key, .str text)] := value | none
  if key != wrapper.key then none else
    match wrapper.payload with
    | .bytes =>
      let policy ← profile.bytesPolicy
      if (base64Length policy text).isSome then some text else none
    | .text none => if unicodeValid text then some text else none
    | .text (some format) =>
      if unicodeValid text && namedFormatAccepts profile format text then some text else none

def wrapperPayloadFailure (profile : VersionedSemanticProfile)
    (wrapper : Wrapper) (value : JsonValue) : Option ValueCondition :=
  if (wrapperPayloadText profile wrapper value).isSome then none
  else match wrapper.payload with
    | .bytes => some .invalidBytes
    | .text none => some (.wrongValueKind "wrapper text")
    | .text (some format) => some (.format format)

private def sealedStringCondition (profile : VersionedSemanticProfile)
    (spec : StringSpec) (value : String) : Option ValueCondition :=
  if !unicodeValid value then some .invalidDataModel
  else if (spec.constValue.map (· != value)).getD false then some .constMismatch
  else if (spec.enumValues.map (fun values => !values.contains value)).getD false then
    some .enumMismatch
  else match lengthBoundsFailure profile value spec.lengths with
    | some condition => some condition
    | none => match spec.format with
      | none => none
      | some (.named name) =>
        if namedFormatAccepts profile name value then none else some (.format name)
      | some (.inline rule) =>
        if formatAcceptsFast rule value then none else some (.format "inline")

private def sealedIntegerCondition (profile : VersionedSemanticProfile)
    (spec : IntegerSpec) (value : Int) : Option ValueCondition :=
  integerCondition profile spec (.num value)

def sealedLeafFailure (profile : VersionedSemanticProfile)
    (leaf : SealedLeaf) (value : JsonValue) : Option ValueCondition :=
  match leaf, value with
  | .string spec, .str text => sealedStringCondition profile spec text
  | .string spec, .obj members =>
    match classOf profile members with
    | .wrapper wrapper =>
      match wrapperPayloadText profile wrapper value with
      | some text => sealedStringCondition profile spec text
      | none => wrapperPayloadFailure profile wrapper value
    | _ => some (.wrongValueKind "string")
  | .string _, _ => some (.wrongValueKind "string")
  | .integer spec, .num integer => sealedIntegerCondition profile spec integer
  | .integer _, _ => some (.wrongValueKind "integer")

private def tagMemberFailure (profile : VersionedSemanticProfile)
    (members : List (String × JsonValue)) :
    Option (String × ValueCondition × JsonValue) :=
  match profile.tag with
  | none => none
  | some tag =>
    match memberValue tag.key members with
    | none => none
    | some value@(.str text) =>
      if !unicodeValid text then some (tag.key, .invalidDataModel, value)
      else match tag.format with
        | none => none
        | some format =>
          if namedFormatAccepts profile format text then none
          else some (tag.key, .invalidTag, value)
    | some value => some (tag.key, .invalidTag, value)

def tagValueAccepts (profile : VersionedSemanticProfile)
    (members : List (String × JsonValue)) : Bool :=
  (tagMemberFailure profile members).isNone

private def textWrapper (profile : VersionedSemanticProfile) : Option Wrapper :=
  profile.wrappers.find? (fun wrapper => match wrapper.payload with
    | .text _ => true
    | _ => false)

def bytesValueLength (profile : VersionedSemanticProfile) (value : JsonValue) : Option Nat := do
  let policy ← profile.bytesPolicy
  let text ← match policy.wrapper with
    | none => match value with
      | .str text => some text
      | _ => none
    | some name => do
      let wrapper ← profile.wrappers.find? (fun wrapper => wrapper.name == name)
      wrapperPayloadText profile wrapper value
  base64Length policy text

def wrapperTextAccepts (profile : VersionedSemanticProfile) (value : JsonValue) : Bool :=
  match textWrapper profile with
  | some wrapper => (wrapperPayloadText profile wrapper value).isSome
  | none => false


def sealedFieldFailure (profile : VersionedSemanticProfile)
    (members : List (String × JsonValue)) (field : SealedField) :
    Option (String × ValueCondition × JsonValue) :=
  match memberValue field.key members with
  | none =>
    if field.required then some (field.key, .missingRequired, .null) else none
  | some value =>
    (sealedLeafFailure profile field.leaf value).map
      (fun condition => (field.key, condition, value))

def sealedFieldsFailure (profile : VersionedSemanticProfile)
    (form : SealedForm) (members : List (String × JsonValue)) :
    Option (String × ValueCondition × JsonValue) :=
  form.fields.findSome? (sealedFieldFailure profile members)

private def sealedKnownField (tag : TagModel) (form : SealedForm) (key : String) : Bool :=
  key == tag.key || form.fields.any (fun field => field.key == key)


private abbrev DataFailure := ValuePath × ValueCondition × JsonValue

def objectMemberFailure (profile : VersionedSemanticProfile)
    (members : List (String × JsonValue)) : Option DataFailure :=
  match duplicateKey members with
  | some key => some ([], .duplicateField key, .obj members)
  | none =>
    (tagMemberFailure profile members).map
      (fun (key, condition, observed) => ([.field key], condition, observed))

mutual
  private def dataValueFailure (profile : VersionedSemanticProfile) (path : ValuePath) :
      JsonValue → Option DataFailure
    | value@(.num _) =>
      if integerInDomain profile none value then none else some (path, .integerDomain, value)
    | value@(.dec text) =>
      match Lean.Json.parse text with
      | .ok (.num _) =>
        let integralUnbounded :=
          match integerBinding profile none with
          | some binding =>
            binding.range == .unbounded && binding.forms.contains .integralDecimal &&
              (decimalIntegerParts text).isSome
          | none => false
        match integralUnbounded with
        | true => none
        | false =>
          match integerCondition profile { domain := none } value with
          | none => none
          | some .integerDomain => some (path, .integerDomain, value)
          | some _ =>
            if profile.numbers.decimals then none
            else some (path, .invalidDataModel, value)
      | _ => some (path, .invalidDataModel, value)
    | value@(.str text) =>
      if unicodeValid text then none else some (path, .invalidDataModel, value)
    | .arr items => dataItemsFailure profile path 0 items
    | value@(.obj members) =>
      match objectMemberFailure profile members with
      | some (relativePath, condition, observed) =>
        some (path ++ relativePath, condition, observed)
      | none =>
        match classOf profile members with
        | .wrapper wrapper =>
          (wrapperPayloadFailure profile wrapper value).map
            (fun condition => (path, condition, value))
        | .sealed form =>
          match sealedFieldsFailure profile form members with
          | some (key, condition, observed) =>
            some (path ++ [.field key], condition, observed)
          | none =>
            match profile.tag with
            | some tag => dataSealedMembersFailure profile path tag form members
            | none => some (path, .invalidDataModel, value)
        | .ordinary => dataMembersFailure profile path members
    | _ => none

  private def dataItemsFailure (profile : VersionedSemanticProfile) (path : ValuePath)
      (index : Nat) : List JsonValue → Option DataFailure
    | [] => none
    | value :: rest =>
      match dataValueFailure profile (path ++ [.index index]) value with
      | some failure => some failure
      | none => dataItemsFailure profile path (index + 1) rest

  private def dataMembersFailure (profile : VersionedSemanticProfile) (path : ValuePath) :
      List (String × JsonValue) → Option DataFailure
    | [] => none
    | (key, value) :: rest =>
      if !unicodeValid key then some (path ++ [.field key], .invalidDataModel, value)
      else match dataValueFailure profile (path ++ [.field key]) value with
        | some failure => some failure
        | none => dataMembersFailure profile path rest

  private def dataSealedMembersFailure (profile : VersionedSemanticProfile)
      (path : ValuePath) (tag : TagModel) (form : SealedForm) :
      List (String × JsonValue) → Option DataFailure
    | [] => none
    | (key, value) :: rest =>
      if sealedKnownField tag form key then
        dataSealedMembersFailure profile path tag form rest
      else if form.extras == .reject then
        some (path ++ [.field key], .unexpectedField key, value)
      else if !unicodeValid key then
        some (path ++ [.field key], .invalidDataModel, value)
      else match dataValueFailure profile (path ++ [.field key]) value with
        | some failure => some failure
        | none => dataSealedMembersFailure profile path tag form rest
end

def dataValueAccepts (profile : VersionedSemanticProfile) (value : JsonValue) : Bool :=
  (dataValueFailure profile [] value).isNone

def dataValuesAccept (profile : VersionedSemanticProfile) (values : List JsonValue) : Bool :=
  values.all (dataValueAccepts profile)

def dataMembersAccept (profile : VersionedSemanticProfile)
    (members : List (String × JsonValue)) : Bool :=
  members.all (fun (key, value) => unicodeValid key && dataValueAccepts profile value)

mutual
  private def jsonValueFailure (path : ValuePath) : JsonValue → Option DataFailure
    | value@(.str text) => if unicodeValid text then none else some (path, .invalidDataModel, value)
    | value@(.dec text) =>
      match Lean.Json.parse text with
      | .ok (.num _) => none
      | _ => some (path, .invalidDataModel, value)
    | .arr items => jsonItemsFailure path 0 items
    | value@(.obj members) =>
      match duplicateKey members with
      | some key => some (path, .duplicateField key, value)
      | none => jsonMembersFailure path members
    | _ => none

  private def jsonItemsFailure (path : ValuePath) (index : Nat) : List JsonValue → Option DataFailure
    | [] => none
    | value :: rest =>
      match jsonValueFailure (path ++ [.index index]) value with
      | some failure => some failure
      | none => jsonItemsFailure path (index + 1) rest

  private def jsonMembersFailure (path : ValuePath) : List (String × JsonValue) → Option DataFailure
    | [] => none
    | (key, value) :: rest =>
      if !unicodeValid key then some (path ++ [.field key], .invalidDataModel, value)
      else match jsonValueFailure (path ++ [.field key]) value with
        | some failure => some failure
        | none => jsonMembersFailure path rest
end


structure ValueRequirement where
  typeRef : TypeRef
  valuePath : ValuePath
  value : JsonValue
  deriving BEq, Repr

inductive Expansion where
  | requirements (children : List ValueRequirement)
  | rejected (failure : ValueFailure)
  | unresolved (obligations : List SemanticObligation)
  deriving BEq, Repr

private def failureAt (ref : TypeRef) (path : ValuePath) (value : SlotValue)
    (condition : ValueCondition) (trace : List TypeRef := []) : ValueFailure :=
  { typeRef := ref, definitionRef := { source := ref.source, name := ref.definitionName }
    origin := { source := ref.source, pointer := ref.pointer }, valuePath := path
    condition, observed := if condition == .missingRequired then .absent else value, referenceTrace := trace }

private def obligationAt (graph : SemanticGraph) (ref : TypeRef) (path : ValuePath)
    (reason : SemanticReason) (origin : Option OccurrenceRef := none) : SemanticObligation :=
  { typeRef := ref, origin := origin.getD { source := ref.source, pointer := ref.pointer }
    valuePath := path, profile := graph.profile.reference, reason }


def stringCondition (profile : VersionedSemanticProfile) (spec : StringSpec)
    (value : String) : Option ValueCondition :=
  if !unicodeValid value then some .invalidDataModel
  else if (spec.constValue.map (· != value)).getD false then some .constMismatch
  else if (spec.enumValues.map (fun values => !values.contains value)).getD false then some .enumMismatch
  else match lengthBoundsFailure profile value spec.lengths with
    | some condition => some condition
    | none => match spec.format with
      | none => none
      | some (.named name) =>
        match profile.formatBindings.find? (fun binding => binding.name == name) with
        | none => none
        | some binding =>
          if formatAcceptsFast binding.rule value then none else some (.format name)
      | some (.inline rule) =>
        if formatAcceptsFast rule value then none else some (.format "inline")

def stringValueCondition (profile : VersionedSemanticProfile) (spec : StringSpec)
    (value : JsonValue) : Option ValueCondition :=
  match spec.wrapper with
  | none =>
    match value with
    | .str text => stringCondition profile spec text
    | _ => some (.wrongValueKind "string")
  | some name =>
    match value with
    | .obj members =>
      match classOf profile members with
      | .wrapper wrapper =>
        if wrapper.name != name then some (.wrongValueKind "string wrapper")
        else match wrapperPayloadText profile wrapper value with
          | some text => stringCondition profile spec text
          | none => wrapperPayloadFailure profile wrapper value
      | _ => some (.wrongValueKind "string wrapper")
    | _ => some (.wrongValueKind "string wrapper")


private def classificationObligations (graph : SemanticGraph)
    (ref : TypeRef) : List SemanticObligation :=
  if graph.profile.bytesPolicy.isNone then
    [obligationAt graph ref [] .missingBytesPolicy]
  else []

def nodeMeaningObligations (graph : SemanticGraph) (ref : TypeRef) : List SemanticObligation :=
  match graph.findType ref with
  | none => [obligationAt graph ref [] .unresolvedType]
  | some node =>
    match node.shape with
    | .string spec =>
      (if spec.lengths.any (fun bound => bound.unit == .graphemes) &&
          graph.profile.graphemeRules.isNone then
        [obligationAt graph ref [] .missingGraphemeRules] else []) ++
      (match spec.format with
       | none | some (.inline _) => []
       | some (.named name) =>
         if graph.profile.formatBindings.any (fun binding => binding.name == name) then []
         else [obligationAt graph ref [] (.unknownFormat name)]) ++
      (match spec.wrapper with
       | none => []
       | some name =>
         match graph.profile.wrappers.find? (fun wrapper => wrapper.name == name) with
         | none => [obligationAt graph ref [] (.unknownWrapper name)]
         | some wrapper => match wrapper.payload with
           | .text _ => []
           | .bytes => [obligationAt graph ref [] (.wrapperPayload name)])
    | .integer spec =>
      match integerBinding graph.profile spec.domain with
      | none =>
        [obligationAt graph ref [] (.unknownIntegerDomain
          (spec.domain.getD graph.profile.defaultIntegerDomain))]
      | some binding =>
        match binding.range with
        | .unbounded => []
        | .inclusive domainMinimum domainMaximum =>
          if spec.minimum.any (fun minimum => minimum < domainMinimum) ||
              spec.maximum.any (fun maximum => domainMaximum < maximum) then
            [obligationAt graph ref [] .integerBound]
          else []
    | .decimal _ =>
      if graph.profile.numbers.decimals then [] else
        [obligationAt graph ref [] .decimalNotAdmitted]
    | .bytes _ | .rawBody _ =>
      if graph.profile.bytesPolicy.isNone then [obligationAt graph ref [] .missingBytesPolicy] else []
    | .sealed tag _ =>
      if graph.profile.tag.any (fun model => model.sealed.any (fun form => form.tag == tag)) then []
      else [obligationAt graph ref [] (.unknownSealedTag tag)]
    | .taggedUnion spec =>
      if spec.branches.any (fun branch => branch.selector == .internalTag) &&
          graph.profile.tag.isNone then
        [obligationAt graph ref [] .missingTagModel]
      else []
    | .unknown _ | .product _ => []
    | .opaque name => [obligationAt graph ref [] (.opaqueType name)]
    | _ => []

private def reachableTypes (graph : SemanticGraph) : Nat → List TypeRef → List TypeRef → List TypeRef
  | 0, _, seen => seen
  | _ + 1, [], seen => seen
  | fuel + 1, ref :: pending, seen =>
    if seen.contains ref then reachableTypes graph fuel pending seen
    else
      let children := (graph.findType ref).map (fun node => typeChildren node.shape) |>.getD []
      reachableTypes graph fuel (children ++ pending) (ref :: seen)

def meaningObligations (graph : SemanticGraph) (refs : List TypeRef) : List SemanticObligation :=
  let edges := graph.nodes.foldl (fun count node => count + (typeChildren node.shape).length) 0
  (reachableTypes graph (refs.length + graph.nodes.length + edges + 1) refs []).flatMap
    (nodeMeaningObligations graph)

def MeaningDefined (graph : SemanticGraph) (ref : TypeRef) : Prop :=
  meaningObligations graph [ref] = []

private def meaningPredicate : SemanticReason → Option MeaningObligation
  | .unknownFormat _ => some .mo01
  | .missingGraphemeRules => some .mo02
  | .missingBytesPolicy => some .mo03
  | .unknownIntegerDomain _ => some .mo04
  | .unknownWrapper _ => some .mo05
  | .wrapperPayload _ => some .mo06
  | .unknownSealedTag _ => some .mo07
  | .decimalNotAdmitted => some .mo08
  | .integerBound => some .mo09
  | .opaqueType _ => some .mo10
  | .missingTagModel => some .mo11
  | _ => none

def checkMeaningDefined (graph : SemanticGraph) (refs : List TypeRef) :
    Except MeaningFailure Unit :=
  match (meaningObligations graph refs).findSome? fun obligation =>
      (meaningPredicate obligation.reason).map fun predicate =>
        ({ typeRef := obligation.typeRef, predicate,
           location := obligation.valuePath.map reprStr } : MeaningFailure) with
  | some failure => .error failure
  | none => .ok ()

def slotRequirements (graph : SemanticGraph) (parent : TypeRef) (path : ValuePath)
    (members : List (String × JsonValue)) : List FieldSpec → Expansion
  | [] => .requirements []
  | field :: rest =>
    let here := path ++ [.field field.wireName]
    let value := memberValue field.wireName members
    let request : Option ValueRequirement := match value with
      | none => none
      | some .null => none
      | some value => some { typeRef := field.slot.typeRef, valuePath := here, value }
    if value.isNone && field.slot.required then
      .rejected (failureAt field.slot.typeRef here .absent .missingRequired)
    else if (match value with | some .null => true | _ => false) && !field.slot.nullable then
      .rejected (failureAt field.slot.typeRef here .null .nullNotAllowed)
    else match slotRequirements graph parent path members rest with
      | .requirements children => .requirements (request.toList ++ children)
      | other => other

def formatUseAccepts (profile : VersionedSemanticProfile)
    (use : FormatUse) (text : String) : Bool :=
  match use with
  | .named name => namedFormatAccepts profile name text
  | .inline rule => formatAcceptsFast rule text
def extraMembersFailure (graph : SemanticGraph) (spec : ProductSpec)
    (members : List (String × JsonValue)) : Option DataFailure :=
  members.findSome? fun (key, value) =>
    if spec.fields.any (fun field => field.wireName == key) ||
        (graph.profile.tag.map (fun tag => key == tag.key)).getD false then none
    else match spec.extras with
      | .reject => some ([.field key], .unexpectedField key, value)
      | .allow keyFormat _ =>
        if !unicodeValid key then some ([.field key], .invalidDataModel, value)
        else if (keyFormat.map (fun use => !formatUseAccepts graph.profile use key)).getD false then
          some ([.field key], .keyFormat key, value)
        else none

def elementRequirements (contract : ElementContract) (path : ValuePath)
    (value : JsonValue) : List ValueRequirement :=
  let requirement := { typeRef := contract.typeRef, valuePath := path, value }
  match value with
  | .null => if contract.nullable then [] else [requirement]
  | _ => [requirement]

def extraFieldRequirements (graph : SemanticGraph) (path : ValuePath)
    (spec : ProductSpec) : List (String × JsonValue) → List ValueRequirement
  | [] => []
  | (key, value) :: rest =>
    let later := extraFieldRequirements graph path spec rest
    if spec.fields.any (fun field => field.wireName == key) ||
        (graph.profile.tag.map (fun tag => key == tag.key)).getD false then later
    else match spec.extras with
      | .reject => later
      | .allow _ contract =>
        elementRequirements contract (path ++ [.field key]) value ++ later
def productRequirements (graph : SemanticGraph) (parent : TypeRef)
    (path : ValuePath) (spec : ProductSpec)
    (members : List (String × JsonValue)) : Expansion :=
  match slotRequirements graph parent path members spec.fields with
  | .requirements fields =>
    .requirements (fields ++ extraFieldRequirements graph path spec members)
  | other => other



private def memberTestMatches (profile : VersionedSemanticProfile)
    (members : List (String × JsonValue)) (test : String × MemberTest) : Bool :=
  match test.2 with
  | .absent => (memberValue test.1 members).isNone
  | .format name =>
    match memberValue test.1 members with
    | some (.str text) => namedFormatAccepts profile name text
    | _ => false

def valueKindMatches (kind : ValueKind) : JsonValue → Bool
  | .null => decide (kind = .null)
  | .bool _ => decide (kind = .boolean)
  | .num _ | .dec _ => decide (kind = .number)
  | .str _ => decide (kind = .string)
  | .arr _ => decide (kind = .array)
  | .obj _ => decide (kind = .object)

def selectorMatches (profile : VersionedSemanticProfile)
    (branch : UnionBranch) (value : JsonValue) : Bool :=
  match branch.selector with
  | .internalTag =>
    match profile.tag, value with
    | some tag, .obj members =>
      match memberValue tag.key members with
      | some (.str text) => text == branch.wireTag
      | _ => false
    | _, _ => false
  | .memberShape tests =>
    match value with
    | .obj members => tests.all (memberTestMatches profile members)
    | _ => false
  | .kind kind => valueKindMatches kind value
  | .otherwise => true

def selectUnionBranch (profile : VersionedSemanticProfile)
    (spec : UnionSpec) (value : JsonValue) : Option UnionBranch :=
  spec.branches.find? (fun branch => selectorMatches profile branch value)
private def selectorPrecedesInternalTag (branch : UnionBranch) (tag : String) : Bool :=
  match branch.selector with
  | .internalTag => branch.wireTag != tag
  | .kind kind => kind != .object
  | _ => false

private def projectableTagBranch : List UnionBranch → String → Option UnionBranch
  | [], _ => none
  | branch :: rest, tag =>
    if branch.wireTag == tag then
      match branch.selector with
      | .internalTag => some branch
      | _ => none
    else if selectorPrecedesInternalTag branch tag then
      projectableTagBranch rest tag
    else none

private theorem projectableTagBranch_selects (profile : VersionedSemanticProfile)
    (branches : List UnionBranch) (tagModel : TagModel) (tag : String)
    (members : List (String × JsonValue))
    (profileTag : profile.tag = some tagModel)
    (tagMember : memberValue tagModel.key members = some (.str tag))
    (branch : UnionBranch)
    (projectable : projectableTagBranch branches tag = some branch) :
    selectUnionBranch profile { branches } (.obj members) = some branch := by
  induction branches with
  | nil => simp [projectableTagBranch] at projectable
  | cons first rest ih =>
    by_cases wire : first.wireTag = tag
    · subst tag
      cases selector : first.selector with
      | internalTag =>
        have same : first = branch := by
          simpa [projectableTagBranch, selector] using projectable
        subst branch
        simp [selectUnionBranch, selectorMatches, profileTag, tagMember, selector]
      | memberShape tests =>
        simp [projectableTagBranch, selector] at projectable
      | kind kind =>
        simp [projectableTagBranch, selector] at projectable
      | otherwise =>
        simp [projectableTagBranch, selector] at projectable
    · cases precedes : selectorPrecedesInternalTag first tag with
      | false => simp [projectableTagBranch, wire, precedes] at projectable
      | true =>
        have firstMisses : selectorMatches profile first (.obj members) = false := by
          cases selected : first.selector with
          | internalTag =>
            have opposite : ¬tag = first.wireTag := fun equal => wire equal.symm
            simp [selectorMatches, selected, profileTag, tagMember, opposite]
          | memberShape tests =>
            simp [selectorPrecedesInternalTag, selected] at precedes
          | kind kind =>
            cases kind with
            | null => simp [selectorMatches, selected, valueKindMatches] <;> decide
            | boolean => simp [selectorMatches, selected, valueKindMatches] <;> decide
            | number => simp [selectorMatches, selected, valueKindMatches] <;> decide
            | string => simp [selectorMatches, selected, valueKindMatches] <;> decide
            | array => simp [selectorMatches, selected, valueKindMatches] <;> decide
            | object =>
              simp only [selectorPrecedesInternalTag, selected] at precedes
              have impossible : (ValueKind.object != ValueKind.object) = false := by decide
              rw [impossible] at precedes
              contradiction
          | otherwise =>
            simp [selectorPrecedesInternalTag, selected] at precedes
        have restProjectable : projectableTagBranch rest tag = some branch := by
          simpa [projectableTagBranch, wire, precedes] using projectable
        simpa [selectUnionBranch, firstMisses] using ih restProjectable


private def compareDecimalBound (text : String) (bound : DecimalBound) : Option Ordering := do
  let .ok (.num number) := Lean.Json.parse text | none
  let (sign, digits, power) := number.normalize
  let valueMantissa := sign * Int.ofNat digits
  let exponent := power + Int.ofNat bound.scale
  if exponent ≥ 0 then
    compare (valueMantissa * Int.ofNat (10 ^ exponent.toNat)) bound.mantissa
  else
    compare valueMantissa (bound.mantissa * Int.ofNat (10 ^ (-exponent).toNat))

private def decimalCondition (spec : DecimalSpec) (text : String) : Option ValueCondition :=
  match Lean.Json.parse text with
  | .error _ => some .invalidDataModel
  | .ok (.num _) =>
      match spec.minimum.bind (compareDecimalBound text) with
      | some .lt => some .belowMinimum
      | some .eq =>
        if (spec.minimum.map (·.exclusive)).getD false then some .belowMinimum else none
      | _ =>
        match spec.maximum.bind (compareDecimalBound text) with
        | some .gt => some .aboveMaximum
        | some .eq =>
          if (spec.maximum.map (·.exclusive)).getD false then some .aboveMaximum else none
        | _ => none
  | .ok _ => some .invalidDataModel

private def sealedRefinementFailure (profile : VersionedSemanticProfile)
    (members : List (String × JsonValue)) (refinements : List SealedRefinement) :
    Option (String × ValueCondition × JsonValue) :=
  refinements.findSome? fun refinement =>
    match memberValue refinement.key members with
    | none => none
    | some value => (sealedLeafFailure profile refinement.leaf value).map
        (fun condition => (refinement.key, condition, value))


def expandNode (graph : SemanticGraph) (ref : TypeRef) (path : ValuePath)
    (value : JsonValue) (node : Option TypeNode) : Expansion :=
  let reject := fun condition => Expansion.rejected (failureAt ref path (.present value) condition)
  match node with
  | none => .unresolved [obligationAt graph ref path .unresolvedType]
  | some node =>
    match node.shape, value with
    | .boolean spec, .bool actual =>
      if (spec.constValue.map (· != actual)).getD false then reject .constMismatch else .requirements []
    | .integer spec, _ =>
      match integerCondition graph.profile spec value with
      | none => .requirements [] | some condition => reject condition
    | .decimal spec, .dec text =>
      match decimalCondition spec text with
      | none => .requirements [] | some condition => reject condition
    | .string spec, _ =>
      match stringValueCondition graph.profile spec value with
      | none => .requirements [] | some condition => reject condition
    | .bytes spec, _ =>
      match bytesValueLength graph.profile value with
      | none => reject .invalidBytes
      | some length => if lengthAccepts spec.minimum spec.maximum length then .requirements []
        else reject .bytesLength
    | .product spec, .obj members =>
      match objectMemberFailure graph.profile members with
      | some (relativePath, condition, observed) =>
        .rejected (failureAt ref (path ++ relativePath) (.present observed) condition)
      | none =>
        match classOf graph.profile members with
        | .ordinary =>
          match extraMembersFailure graph spec members with
          | some (fieldPath, condition, observed) =>
            .rejected (failureAt ref (path ++ fieldPath) (.present observed) condition)
          | none =>
            productRequirements graph ref path spec members
        | _ => reject (.wrongValueKind "plain data object")
    | .array spec, .arr items =>
      if !lengthAccepts spec.minLength spec.maxLength items.length then reject .arrayLength
      else .requirements (items.zipIdx.flatMap fun (item, index) =>
        elementRequirements spec.item (path ++ [.index index]) item)
    | .alias target _, _ => .requirements [{ typeRef := target, valuePath := path, value }]
    | .taggedUnion spec, _ =>
      match value with
      | .obj members =>
        match objectMemberFailure graph.profile members with
        | some (relativePath, condition, observed) =>
          .rejected (failureAt ref (path ++ relativePath) (.present observed) condition)
        | none =>
          match selectUnionBranch graph.profile spec value with
          | some branch =>
            .requirements [{ typeRef := branch.target, valuePath := path, value }]
          | none => reject .noBranchSelected
      | _ =>
        match selectUnionBranch graph.profile spec value with
        | some branch =>
          .requirements [{ typeRef := branch.target, valuePath := path, value }]
        | none => reject .noBranchSelected
    | .sealed tag refinements, .obj members =>
      match objectMemberFailure graph.profile members with
      | some (relativePath, condition, observed) =>
        .rejected (failureAt ref (path ++ relativePath) (.present observed) condition)
      | none =>
        match classOf graph.profile members with
        | .sealed form =>
          if form.tag != tag then reject .invalidDataModel
          else
            match sealedFieldsFailure graph.profile form members with
            | some (key, condition, observed) =>
              .rejected (failureAt ref (path ++ [.field key]) (.present observed) condition)
            | none =>
              match sealedRefinementFailure graph.profile members refinements with
              | some (key, condition, observed) =>
                .rejected (failureAt ref (path ++ [.field key]) (.present observed) condition)
              | none => .requirements []
        | _ => reject (.wrongValueKind "sealed object")
    | .never, _ => reject .invalidDataModel
    | .unknown .ordinaryObject, .obj members =>
      match objectMemberFailure graph.profile members with
      | some (relativePath, condition, observed) =>
        .rejected (failureAt ref (path ++ relativePath) (.present observed) condition)
      | none =>
        if classOf graph.profile members != .ordinary then
          reject (.wrongValueKind "ordinary object")
        else match dataValueFailure graph.profile path value with
          | none => .requirements []
          | some (here, condition, observed) =>
            .rejected (failureAt ref here (.present observed) condition)
    | .unknown .ordinaryObject, _ => reject (.wrongValueKind "ordinary object")
    | .unknown .any, _ =>
      match dataValueFailure graph.profile path value with
      | none => .requirements []
      | some (here, condition, observed) =>
        .rejected (failureAt ref here (.present observed) condition)
    | .unit, .null => .requirements []
    | .rawBody _, _ =>
      if (bytesValueLength graph.profile value).isSome then
        .requirements []
      else reject .invalidBytes
    | .opaque name, _ => .unresolved [obligationAt graph ref path (.opaqueType name)]
    | .boolean _, _ => reject (.wrongValueKind "boolean")
    | .decimal _, _ => reject (.wrongValueKind "decimal")
    | .sealed _ _, _ => reject (.wrongValueKind "sealed object")
    | .product _, _ => reject (.wrongValueKind "object")
    | .array _, _ => reject (.wrongValueKind "array")
    | .unit, _ => reject (.wrongValueKind "unit")

def expandValue (graph : SemanticGraph) (ref : TypeRef) (path : ValuePath)
    (value : JsonValue) : Expansion :=
  expandNode graph ref path value (graph.findType ref)

inductive ValueMember (graph : SemanticGraph) : TypeRef → ValuePath → JsonValue → Prop where
  | step (ref : TypeRef) (path : ValuePath) (value : JsonValue) (children : List ValueRequirement)
      (expansion : expandValue graph ref path value = .requirements children)
      (members : ∀ child ∈ children, ValueMember graph child.typeRef child.valuePath child.value) :
      ValueMember graph ref path value

inductive SlotMember (graph : SemanticGraph) : SlotContract → SlotValue → Prop where
  | absent (slot : SlotContract) (optional : slot.required = false) : SlotMember graph slot .absent
  | null (slot : SlotContract) (nullable : slot.nullable = true) : SlotMember graph slot .null
  | present (slot : SlotContract) (value : JsonValue)
      (member : ValueMember graph slot.typeRef [] value) : SlotMember graph slot (.present value)

def Values (graph : SemanticGraph) (ref : TypeRef) (value : JsonValue) : Prop :=
  MeaningDefined graph ref ∧ ValueMember graph ref [] value

def Slots (graph : SemanticGraph) (slot : SlotContract) (value : SlotValue) : Prop :=
  MeaningDefined graph slot.typeRef ∧ SlotMember graph slot value

inductive MemberProof where
  | node (children : List MemberProof)
  deriving BEq, Repr

structure MemberCertificate where
  profile : ProfileRef
  sourceRefs : List SourceRef
  contract : SlotContract
  value : SlotValue
  proof : Option MemberProof
  deriving BEq, Repr

inductive ValidationFailure where
  | value (failure : ValueFailure)
  | unresolved (obligations : List SemanticObligation)
  | certificateMismatch (condition : String)
  deriving BEq, Repr

inductive MembershipResult (graph : SemanticGraph) (ref : TypeRef) (path : ValuePath)
    (value : JsonValue) where
  | accepted (proof : MemberProof) (member : ValueMember graph ref path value)
  | rejected (failure : ValueFailure)
  | unresolved (obligations : List SemanticObligation)
  | invalidCertificate (condition : String)

private structure CheckedRequirements (graph : SemanticGraph) (children : List ValueRequirement) where
  proofs : List MemberProof
  members : ∀ child ∈ children, ValueMember graph child.typeRef child.valuePath child.value

private def checkValueFuel (graph : SemanticGraph) :
    Nat → List (TypeRef × ValuePath) → (ref : TypeRef) → (path : ValuePath) → (value : JsonValue) →
      Option MemberProof → MembershipResult graph ref path value
  | 0, _, ref, path, _, _ => .unresolved [obligationAt graph ref path .membershipBound]
  | fuel + 1, seen, ref, path, value, expected =>
    if seen.contains (ref, path) then .rejected (failureAt ref path (.present value) .referenceCycle (seen.map (·.1)))
    else
      match hexpansion : expandValue graph ref path value with
      | .rejected failure => .rejected { failure with referenceTrace := seen.map (·.1) }
      | .unresolved obligations => .unresolved obligations
      | .requirements children =>
        let wanted := expected.map fun | .node proofs => proofs
        let rec checkChildren (children : List ValueRequirement) (wanted : Option (List MemberProof)) :
            Except ValidationFailure (CheckedRequirements graph children) :=
          match children, wanted with
          | [], none | [], some [] => .ok { proofs := [], members := by simp }
          | [], some (_ :: _) => .error (.certificateMismatch "extra membership children")
          | _ :: _, some [] => .error (.certificateMismatch "missing membership children")
          | child :: rest, wanted =>
            let headProof := wanted.bind (fun proofs => proofs.head?)
            let tailProofs := wanted.map (fun proofs => proofs.drop 1)
            match checkValueFuel graph fuel ((ref, path) :: seen) child.typeRef child.valuePath child.value headProof with
            | .rejected failure => .error (.value failure)
            | .unresolved obligations => .error (.unresolved obligations)
            | .invalidCertificate condition => .error (.certificateMismatch condition)
            | .accepted proof member =>
              match checkChildren rest tailProofs with
              | .error failure => .error failure
              | .ok checked => .ok
                { proofs := proof :: checked.proofs
                  members := by
                    intro request present
                    rcases List.mem_cons.mp present with same | later
                    · subst request
                      exact member
                    · exact checked.members request later }
        match checkChildren children wanted with
        | .error (.value failure) => .rejected failure
        | .error (.unresolved obligations) => .unresolved obligations
        | .error (.certificateMismatch condition) => .invalidCertificate condition
        | .ok checked => .accepted (.node checked.proofs)
            (.step ref path value children hexpansion checked.members)

structure ValidatedValue (graph : SemanticGraph) (ref : TypeRef) (value : JsonValue) where
  proof : MemberProof
  meaning : MeaningDefined graph ref
  member : ValueMember graph ref [] value

structure ValidatedSlot (graph : SemanticGraph) (slot : SlotContract) (value : SlotValue) where
  certificate : MemberCertificate
  meaning : MeaningDefined graph slot.typeRef
  member : SlotMember graph slot value

def validateValue (graph : SemanticGraph) (ref : TypeRef) (value : JsonValue)
    (proof : Option MemberProof := none) :
    Except ValidationFailure (ValidatedValue graph ref value) :=
  match hmeaning : meaningObligations graph [ref] with
  | _ :: _ => .error (.unresolved (meaningObligations graph [ref]))
  | [] =>
    match checkValueFuel graph ((Necoherence.ExactJson.jsonSize value + 1) * (graph.nodes.length + 1))
        [] ref [] value proof with
    | .accepted proof member => .ok { proof, meaning := hmeaning, member }
    | .rejected failure => .error (.value failure)
    | .unresolved obligations => .error (.unresolved obligations)
    | .invalidCertificate condition => .error (.certificateMismatch condition)

def validateSlot (graph : SemanticGraph) (slot : SlotContract) (value : SlotValue) :
    Except ValidationFailure (ValidatedSlot graph slot value) :=
  let certificate := fun proof =>
    { profile := graph.profile.reference, sourceRefs := graph.sourceRefs
      contract := slot, value, proof : MemberCertificate }
  match hmeaning : meaningObligations graph [slot.typeRef] with
  | _ :: _ => .error (.unresolved (meaningObligations graph [slot.typeRef]))
  | [] =>
    match value with
    | .absent => if h : slot.required = false then
        .ok { certificate := certificate none, meaning := hmeaning, member := .absent slot h }
      else .error (.value (failureAt slot.typeRef [] value .missingRequired))
    | .null => if h : slot.nullable = true then
        .ok { certificate := certificate none, meaning := hmeaning, member := .null slot h }
      else .error (.value (failureAt slot.typeRef [] value .nullNotAllowed))
    | .present actual =>
      match validateValue graph slot.typeRef actual with
      | .error failure => .error failure
      | .ok checked => .ok
        { certificate := certificate (some checked.proof), meaning := hmeaning
          member := .present slot actual checked.member }

private def decisionOf {α : Type} (graph : SemanticGraph) (ref : TypeRef) :
    Except ValidationFailure α → ValueDecision
  | .ok _ => .accepted
  | .error (.value failure) => .rejected failure
  | .error (.unresolved obligations) => .unresolved obligations
  | .error (.certificateMismatch condition) =>
    .unresolved [obligationAt graph ref [] (.certificateMismatch condition)]

def acceptsValue (graph : SemanticGraph) (ref : TypeRef) (value : JsonValue) : ValueDecision :=
  decisionOf graph ref (validateValue graph ref value)

def acceptsSlot (graph : SemanticGraph) (slot : SlotContract) (value : SlotValue) : ValueDecision :=
  decisionOf graph slot.typeRef (validateSlot graph slot value)

def checkMemberCertificate (graph : SemanticGraph) (slot : SlotContract) (value : SlotValue)
    (certificate : MemberCertificate) : Except ValidationFailure (ValidatedSlot graph slot value) := do
  if certificate.profile != graph.profile.reference then
    throw (.certificateMismatch "profile revision")
  if certificate.sourceRefs != graph.sourceRefs then
    throw (.certificateMismatch "source revisions")
  if certificate.contract != slot || certificate.value != value then
    throw (.certificateMismatch "contract or value")
  match hvalue : value with
  | .present actual =>
    match certificate.proof with
    | none => throw (.certificateMismatch "missing value derivation")
    | some proof =>
      let checked ← validateValue graph slot.typeRef actual (some proof)
      pure {
        certificate := certificate
        meaning := checked.meaning
        member := by
          rw [hvalue]
          exact .present slot actual checked.member
      }
  | _ =>
    if certificate.proof.isSome then throw (.certificateMismatch "unexpected value derivation")
    else validateSlot graph slot value

theorem validated_value_member (graph : SemanticGraph) (ref : TypeRef) (value : JsonValue)
    (checked : ValidatedValue graph ref value) :
    MeaningDefined graph ref ∧ ValueMember graph ref [] value :=
  ⟨checked.meaning, checked.member⟩

theorem validated_slot_member (graph : SemanticGraph) (slot : SlotContract) (value : SlotValue)
    (checked : ValidatedSlot graph slot value) :
    MeaningDefined graph slot.typeRef ∧ SlotMember graph slot value :=
  ⟨checked.meaning, checked.member⟩

theorem required_absent_rejected (graph : SemanticGraph) (slot : SlotContract)
    (required : slot.required = true) : ¬ SlotMember graph slot .absent := by
  intro member
  cases member with
  | absent optional => simp [required] at optional

theorem nonnullable_null_rejected (graph : SemanticGraph) (slot : SlotContract)
    (nonnull : slot.nullable = false) : ¬ SlotMember graph slot .null := by
  intro member
  cases member with
  | null nullable => simp [nonnull] at nullable

theorem present_has_value_member (graph : SemanticGraph) (slot : SlotContract) (value : JsonValue)
    (member : SlotMember graph slot (.present value)) : ValueMember graph slot.typeRef [] value := by
  cases member with
  | present _ valueMember => exact valueMember

theorem member_expansion_has_members (graph : SemanticGraph) (ref : TypeRef) (path : ValuePath)
    (value : JsonValue) (member : ValueMember graph ref path value) :
    ∃ children, expandValue graph ref path value = .requirements children ∧
      ∀ child ∈ children, ValueMember graph child.typeRef child.valuePath child.value := by
  cases member with
  | step _ _ _ children expansion members => exact ⟨children, expansion, members⟩

private def originAt (ref : TypeRef) (keys : List String := []) : OccurrenceRef :=
  { source := ref.source, pointer := ref.pointer ++ keys }

private def validProfileReference (reference : ProfileRef) : Bool :=
  reference.identity != "" && reference.revision != "" && reference.contentDigest != ""

def formatRuleWellFormed : Nat → FormatRule → Bool
  | 0, _ => false
  | _ + 1, .asciiDfa spec =>
    spec.stateCount > 0 && spec.initialState < spec.stateCount &&
      spec.acceptingStates.all (· < spec.stateCount) &&
      spec.transitions.all (fun transition => transition.fromState < spec.stateCount &&
        transition.toState < spec.stateCount && transition.first ≤ transition.last && transition.last < 128) &&
      spec.transitions.zipIdx.all (fun (transition, index) =>
        (spec.transitions.drop (index + 1)).all fun other =>
          transition.fromState != other.fromState || transition.last < other.first || other.last < transition.first)
  | _ + 1, .timestamp rule => rule.minimumYear ≤ rule.maximumYear && rule.maximumYear ≤ 9999
  | _ + 1, .identifier first rest exact minimum maximum forbidden =>
    first != "" && rest != "" &&
      (maximum.map (fun bound => decide (minimum ≤ bound))).getD true &&
      ascii first && ascii rest && forbidden.all unicodeValid &&
      (exact.map (fun length => decide (minimum ≤ length) &&
        (maximum.map (fun bound => decide (length ≤ bound))).getD true)).getD true
  | fuel + 1, .sequence rules => rules.all (formatRuleWellFormed fuel)
  | fuel + 1, .optional rule => formatRuleWellFormed fuel rule
  | fuel + 1, .labels separator _ _ _ rule => separator != "" && formatRuleWellFormed fuel rule
  | fuel + 1, .bounded _ _ rule => formatRuleWellFormed fuel rule
  | fuel + 1, .choice rules => rules.all (formatRuleWellFormed fuel)
  | fuel + 1, .text => true
  | fuel + 1, .not rule => formatRuleWellFormed fuel rule
  | _ + 1, _ => true

private def profileNamesUnique (names : List String) : Bool :=
  names.all (· != "") && names.eraseDups.length == names.length

private def profileRangeValid : IntegerDomain → Bool
  | .unbounded => true
  | .inclusive minimum maximum => minimum ≤ maximum

private def profileLengthValid (bound : LengthBound) : Bool :=
  match bound.minimum, bound.maximum with
  | some minimum, some maximum => minimum ≤ maximum
  | _, _ => true

def checkProfile (profile : VersionedSemanticProfile) : Except ProfileFailure CheckedProfile := do
  let fail := fun predicate location =>
    throw ({ reference := profile.reference, predicate, location } : ProfileFailure)
  let formats := profile.formatBindings.map (·.name)
  let wrapperNames := profile.wrappers.map (·.name)
  let wrapperKeys := profile.wrappers.map (·.key)
  if !validProfileReference profile.reference ||
      profile.integerDomains.any (fun binding => !validProfileReference binding.reference) ||
      profile.formatBindings.any (fun binding => !validProfileReference binding.reference) ||
      profile.bytesPolicy.any (fun policy => !validProfileReference policy.reference) ||
      profile.graphemeRules.any (fun rules => !validProfileReference rules.reference) then
    fail .pr01 ["profile"]
  if !profileNamesUnique (profile.integerDomains.map (·.name)) then
    fail .pr02 ["integer_domains"]
  if profile.integerDomains.any (fun binding => !profileRangeValid binding.range) then
    fail .pr03 ["integer_domains"]
  if profile.integerDomains.any (·.forms.isEmpty) then
    fail .pr04 ["integer_domains"]
  if !profile.integerDomains.any (fun binding => binding.name == profile.defaultIntegerDomain) then
    fail .pr05 ["default_integer_domain"]
  if !profileNamesUnique formats then
    fail .pr06 ["format_bindings"]
  if profile.formatBindings.any (fun binding =>
      !formatRuleWellFormed (formatRuleDepth binding.rule) binding.rule) then
    fail .pr07 ["format_bindings"]
  if !profileNamesUnique wrapperNames || !profileNamesUnique wrapperKeys then
    fail .pr08 ["wrappers"]
  if profile.wrappers.any (fun wrapper => match wrapper.payload with
      | .text (some format) => !formats.contains format
      | _ => false) then
    fail .pr09 ["wrappers"]
  if profile.bytesPolicy.any (fun policy => match policy.wrapper with
      | none => false
      | some name => !profile.wrappers.any (fun wrapper =>
          wrapper.name == name && wrapper.payload == .bytes)) then
    fail .pr10 ["bytes_policy", "wrapper"]
  match profile.tag with
  | none => pure ()
  | some tag =>
    if tag.key == "" || wrapperKeys.contains tag.key then
      fail .pr11 ["tag", "key"]
    if tag.format.any (fun format => !formats.contains format) then
      fail .pr12 ["tag", "format"]
    let sealedTags := tag.sealed.map (·.tag)
    if !profileNamesUnique sealedTags || tag.sealed.any (fun form =>
        tag.format.any (fun format => match profile.formatBindings.find? (fun binding => binding.name == format) with
          | none => true
          | some binding => !formatAcceptsFast binding.rule form.tag)) then
      fail .pr13 ["tag", "sealed"]
    if tag.sealed.any (fun form =>
        let keys := form.fields.map (·.key)
        !profileNamesUnique keys || keys.contains tag.key || keys.any wrapperKeys.contains) then
      fail .pr14 ["tag", "sealed", "fields"]
    if tag.sealed.any (fun form => form.fields.any (fun field => match field.leaf with
        | .string spec =>
          spec.wrapper.any (fun name => !profile.wrappers.any (fun wrapper =>
            wrapper.name == name && match wrapper.payload with | .text _ => true | _ => false)) ||
          spec.format.any (fun format => match format with
            | .named name => !formats.contains name
            | .inline rule => !formatRuleWellFormed (formatRuleDepth rule + 1) rule) ||
          spec.lengths.any (fun bound => !profileLengthValid bound)
        | .integer spec =>
          spec.domain.any (fun name => !profile.integerDomains.any (fun binding => binding.name == name)))) then
      fail .pr15 ["tag", "sealed", "fields"]
  if profile.graphemeRules.any (fun rules =>
      rules.properties.any (fun range => range.last < range.first) ||
      rules.extendedPictographic.any (fun range => range.last < range.first) ||
      rules.indicConjunct.any (fun range => range.last < range.first)) then
    fail .pr16 ["grapheme_rules"]
  pure { profile := profile }

structure DefaultApplication where
  valuePath : ValuePath
  typeRef : TypeRef
  origin : OccurrenceRef
  value : JsonValue
  deriving BEq, Repr

private structure DefaultDraft where
  value : JsonValue
  applications : List DefaultApplication

private def declaredDefault (graph : SemanticGraph) : Nat → TypeRef → Option (TypeRef × JsonValue)
  | 0, _ => none
  | fuel + 1, ref => do
    let node ← graph.findType ref
    match node.shape with
    | .alias target _ => declaredDefault graph fuel target
    | shape => (typeDefault shape).map (ref, ·)

private def defaultDraft (graph : SemanticGraph) :
    Nat → TypeRef → ValuePath → JsonValue → Except ValidationFailure DefaultDraft
  | 0, ref, path, _ => .error (.unresolved [obligationAt graph ref path .membershipBound])
  | fuel + 1, ref, path, value => do
    let some node := graph.findType ref |
      throw (.unresolved [obligationAt graph ref path .unresolvedType])
    match node.shape, value with
    | .alias target _, _ => defaultDraft graph fuel target path value
    | .taggedUnion spec, .obj members =>
      match memberValue ((graph.profile.tag.map (fun (model : TagModel) => model.key)).getD "") members with
      | some (.str tag) =>
        match spec.branches.find? (fun branch => branch.wireTag == tag) with
        | some branch => defaultDraft graph fuel branch.target path value
        | none => pure { value, applications := [] }
      | _ => pure { value, applications := [] }
    | .array spec, .arr items =>
      let (values, applications) ← items.zipIdx.foldlM (init := ([], [])) fun (values, applications) (item, index) => do
        let draft ← defaultDraft graph fuel spec.item.typeRef (path ++ [.index index]) item
        pure (draft.value :: values, draft.applications.reverse ++ applications)
      pure { value := .arr values.reverse, applications := applications.reverse }
    | .product spec, .obj members =>
      let (retained, applications) ← members.foldlM (init := ([], [])) fun (retained, applications) (key, value) => do
        match spec.fields.find? (fun field => field.wireName == key) with
        | none => pure ((key, value) :: retained, applications)
        | some field =>
          match value with
          | .null => pure ((key, value) :: retained, applications)
          | _ =>
            let draft ← defaultDraft graph fuel field.slot.typeRef (path ++ [.field key]) value
            pure ((key, draft.value) :: retained, draft.applications.reverse ++ applications)
      let (inserted, applications) ← spec.fields.foldlM (init := ([], applications)) fun (inserted, applications) field => do
        if (memberValue field.wireName members).isSome then pure (inserted, applications)
        else match declaredDefault graph (graph.nodes.length + 1) field.slot.typeRef with
          | none => pure (inserted, applications)
          | some (defaultRef, value) =>
            let _ ← validateValue graph defaultRef value
            let application : DefaultApplication :=
              { valuePath := path ++ [.field field.wireName], typeRef := defaultRef
                origin := originAt defaultRef ["default"], value }
            pure ((field.wireName, value) :: inserted, application :: applications)
      pure { value := .obj (retained.reverse ++ inserted.reverse), applications := applications.reverse }
    | _, _ => pure { value, applications := [] }

private def tagMatches (profile : VersionedSemanticProfile)
    (members : List (String × JsonValue)) (tag : String) : Bool :=
  match profile.tag with
  | none => false
  | some model =>
    match memberValue model.key members with
    | some (.str actual) => actual == tag
    | _ => false

def valueAtPath (profile : VersionedSemanticProfile) : JsonValue → ValuePath → SlotValue
  | value, [] => .present value
  | .null, _ :: _ => .null
  | .obj members, .field name :: rest =>
    match memberValue name members with
    | none => .absent
    | some .null => .null
    | some value => valueAtPath profile value rest
  | .arr items, .index index :: rest =>
    match items[index]? with
    | none => .absent
    | some .null => .null
    | some value => valueAtPath profile value rest
  | value@(.obj members), .variant tag :: rest =>
    if tagMatches profile members tag then valueAtPath profile value rest else .absent
  | _, _ :: _ => .absent

def checkDefaultApplications (graph : SemanticGraph) (before after : JsonValue)
    (applications : List DefaultApplication) : Bool :=
  applications.all fun application =>
    (valueAtPath graph.profile before application.valuePath == .absent) &&
    ((valueAtPath graph.profile after application.valuePath == .present application.value) &&
    ((application.origin == originAt application.typeRef ["default"]) &&
    ((graph.findType application.typeRef).bind (fun node => typeDefault node.shape) == some application.value)))

structure DefaultedValue (graph : SemanticGraph) (ref : TypeRef) (before : JsonValue) where
  value : JsonValue
  applications : List DefaultApplication
  checked : ValidatedValue graph ref value
  witness : checkDefaultApplications graph before value applications = true

def materializeDefaults (graph : SemanticGraph) (ref : TypeRef) (value : JsonValue) :
    Except ValidationFailure (DefaultedValue graph ref value) := do
  let draft ← defaultDraft graph ((Necoherence.ExactJson.jsonSize value + 1) * (graph.nodes.length + 1))
    ref [] value
  let checked ← validateValue graph ref draft.value
  if h : checkDefaultApplications graph value draft.value draft.applications = true then
    pure { value := draft.value, applications := draft.applications, checked, witness := h }
  else throw (.certificateMismatch "default source, absence, or result")

theorem materialized_value_member (graph : SemanticGraph) (ref : TypeRef) (before : JsonValue)
    (defaulted : DefaultedValue graph ref before) :
    ValueMember graph ref [] defaulted.value ∧
      ∀ application ∈ defaulted.applications,
        valueAtPath graph.profile before application.valuePath == .absent := by
  refine ⟨defaulted.checked.member, ?_⟩
  intro application present
  have conditions := List.all_eq_true.mp defaulted.witness application present
  simp only [Bool.and_eq_true] at conditions
  exact conditions.1

inductive ProjectionAssumption where
  | present (path : ValuePath)
  | nonNull (path : ValuePath)
  | variant (path : ValuePath) (tag : String)
  | indexPresent (path : ValuePath) (index : Nat)
  deriving Repr, DecidableEq

structure ProjectionCertificate where
  profile : ProfileRef
  sourceRefs : List SourceRef
  source : SlotContract
  path : ValuePath
  assumptions : List ProjectionAssumption
  destination : SlotContract
  deriving Repr, DecidableEq

inductive ProjectionFailure where
  | wrongShape (ref : TypeRef) (path : ValuePath)
  | missingField (ref : TypeRef) (name : String)
  | missingVariant (ref : TypeRef) (tag : String)
  | branchAssumptionRequired (path : ValuePath) (tag : String)
  | variantSelectionUndetermined (path : ValuePath) (tag : String)
  | unresolved (obligations : List SemanticObligation)
  | certificateMismatch (condition : String)
  deriving BEq, Repr

private def strengthenProjection (slot : SlotContract) (path : ValuePath)
    (assumptions : List ProjectionAssumption) : SlotContract :=
  let observed := assumptions.any fun assumption => match assumption with
    | .present observed | .variant observed _ | .indexPresent observed _ => decide (observed = path)
    | _ => false
  if observed then { slot with required := true, nullable := false }
  else if decide (ProjectionAssumption.nonNull path ∈ assumptions) then { slot with nullable := false }
  else slot

private def projectContract (graph : SemanticGraph) (assumptions : List ProjectionAssumption) :
    Nat → SlotContract → ValuePath → ValuePath → Except ProjectionFailure SlotContract
  | 0, slot, path, _ => .error (.unresolved [obligationAt graph slot.typeRef path .membershipBound])
  | fuel + 1, slot, traversed, remaining => do
    let slot := strengthenProjection slot traversed assumptions
    match remaining with
    | [] => pure slot
    | step :: rest =>
      let some node := graph.findType slot.typeRef |
        throw (.unresolved [obligationAt graph slot.typeRef traversed .unresolvedType])
      match node.shape with
      | .alias target _ => projectContract graph assumptions fuel { slot with typeRef := target } traversed remaining
      | .product spec =>
        match step with
        | .field name =>
          let some field := spec.fields.find? (fun field => field.wireName == name) |
            throw (.missingField slot.typeRef name)
          projectContract graph assumptions fuel
            { typeRef := field.slot.typeRef, required := slot.required && field.slot.required
              nullable := slot.nullable || field.slot.nullable } (traversed ++ [step]) rest
        | _ => throw (.wrongShape slot.typeRef traversed)
      | .array spec =>
        match step with
        | .index index =>
          let present := index < spec.minLength.getD 0 || decide (ProjectionAssumption.indexPresent traversed index ∈ assumptions)
          projectContract graph assumptions fuel
            { typeRef := spec.item.typeRef, required := slot.required && present,
              nullable := true }
            (traversed ++ [step]) rest
        | _ => throw (.wrongShape slot.typeRef traversed)
      | .taggedUnion spec =>
        match step with
        | .variant tag =>
          if !decide (ProjectionAssumption.variant traversed tag ∈ assumptions) then
            throw (.branchAssumptionRequired traversed tag)
          let some branch := spec.branches.find? (fun branch => branch.wireTag == tag) |
            throw (.missingVariant slot.typeRef tag)
          if graph.profile.tag.isNone then
            throw (.variantSelectionUndetermined traversed tag)
          let some selected := projectableTagBranch spec.branches tag |
            throw (.variantSelectionUndetermined traversed tag)
          if same : selected = branch then
            projectContract graph assumptions fuel { slot with typeRef := branch.target }
              (traversed ++ [step]) rest
          else throw (.variantSelectionUndetermined traversed tag)
        | _ => throw (.wrongShape slot.typeRef traversed)
      | _ => throw (.wrongShape slot.typeRef traversed)

def projectSlot (graph : SemanticGraph) (source : SlotContract) (path : ValuePath)
    (assumptions : List ProjectionAssumption := []) :
    Except ProjectionFailure ProjectionCertificate := do
  let obligations := meaningObligations graph [source.typeRef]
  if !obligations.isEmpty then throw (.unresolved obligations)
  let destination ← projectContract graph assumptions
    ((path.length + 1) * (graph.nodes.length + 1)) source [] path
  let destinationObligations := meaningObligations graph [destination.typeRef]
  if !destinationObligations.isEmpty then throw (.unresolved destinationObligations)
  pure { profile := graph.profile.reference, sourceRefs := graph.sourceRefs,
         source, path, assumptions, destination }

def checkProjectionCertificate (graph : SemanticGraph) (certificate : ProjectionCertificate) :
    Except ProjectionFailure ProjectionCertificate := do
  if certificate.profile != graph.profile.reference ||
      certificate.sourceRefs != graph.sourceRefs then
    throw (.certificateMismatch "profile or source revisions")
  let computed ← projectSlot graph certificate.source certificate.path certificate.assumptions
  if computed = certificate then pure computed
  else throw (.certificateMismatch "projection contract or guards")

def assumptionHolds (profile : VersionedSemanticProfile)
    (value : JsonValue) : ProjectionAssumption → Bool
  | .present path => match valueAtPath profile value path with | .present _ => true | _ => false
  | .nonNull path => match valueAtPath profile value path with | .null | .present (.null) => false | _ => true
  | .variant path tag => match valueAtPath profile value path with
    | .present (.obj members) => tagMatches profile members tag
    | _ => false
  | .indexPresent path index => match valueAtPath profile value path with
    | .present (.arr values) => index < values.length
    | _ => false

def slotAssumptionHolds (profile : VersionedSemanticProfile)
    (source : SlotValue) (assumption : ProjectionAssumption) : Bool :=
  match source with
  | .present value => assumptionHolds profile value assumption
  | .absent => match assumption with | .nonNull _ => true | _ => false
  | .null => false

def projectedValue (profile : VersionedSemanticProfile)
    (source : SlotValue) (path : ValuePath) : SlotValue :=
  match source with
  | .absent => .absent
  | .null => .null
  | .present value => valueAtPath profile value path

def projectValue (graph : SemanticGraph) (certificate : ProjectionCertificate) (source : SlotValue) :
    Except ValidationFailure
      (ValidatedSlot graph certificate.destination (projectedValue graph.profile source certificate.path)) := do
  match checkProjectionCertificate graph certificate with
  | .error failure => throw (.certificateMismatch (reprStr failure))
  | .ok _ => pure ()
  let _ ← validateSlot graph certificate.source source
  if !certificate.assumptions.all (slotAssumptionHolds graph.profile source) then
    throw (.certificateMismatch "projection guard not satisfied")
  validateSlot graph certificate.destination (projectedValue graph.profile source certificate.path)

inductive MembershipProjection (graph : SemanticGraph) :
    ValueRequirement → ValueRequirement → Prop where
  | identity (value : ValueRequirement) : MembershipProjection graph value value
  | child (source child target : ValueRequirement) (children : List ValueRequirement)
      (expansion : expandValue graph source.typeRef source.valuePath source.value = .requirements children)
      (present : child ∈ children) (rest : MembershipProjection graph child target) :
      MembershipProjection graph source target

theorem projection_member_sound (graph : SemanticGraph) (source target : ValueRequirement)
    (projection : MembershipProjection graph source target)
    (member : ValueMember graph source.typeRef source.valuePath source.value) :
    ValueMember graph target.typeRef target.valuePath target.value := by
  induction projection with
  | identity _ => exact member
  | child source child target children expansion present rest ih =>
    obtain ⟨actualChildren, actualExpansion, members⟩ := member_expansion_has_members
      graph source.typeRef source.valuePath source.value member
    have same : actualChildren = children := by
      rw [expansion] at actualExpansion
      exact Expansion.requirements.inj actualExpansion.symm
    subst actualChildren
    exact ih (members child present)


def AliasClosed (graph : SemanticGraph) (refs : List TypeRef) : Prop :=
  ∀ ref ∈ refs, ∃ node target text,
    graph.findType ref = some node ∧ node.shape = .alias target text ∧ target ∈ refs

theorem alias_closed_has_no_member (graph : SemanticGraph) (refs : List TypeRef)
    (closed : AliasClosed graph refs) (ref : TypeRef) (present : ref ∈ refs)
    (path : ValuePath) (value : JsonValue) : ¬ ValueMember graph ref path value := by
  have impossible : ∀ ref path value, ValueMember graph ref path value → ref ∈ refs → False := by
    intro ref path value member
    induction member with
    | step ref path value children expansion members ih =>
      intro present
      obtain ⟨node, target, text, lookup, shape, targetPresent⟩ := closed ref present
      have expected : children = [{ typeRef := target, valuePath := path, value }] := by
        simpa [expandValue, expandNode, lookup, shape] using expansion.symm
      subst children
      exact ih { typeRef := target, valuePath := path, value } (by simp) targetPresent
  exact fun member => impossible ref path value member present

private def trimTableField (text : String) : String :=
  String.ofList (((text.toList.dropWhile Char.isWhitespace).reverse.dropWhile Char.isWhitespace).reverse)

private def hexadecimalNat (text : String) : Option Nat :=
  if text == "" then none
  else text.foldl (fun result c => do
    let value ← result
    let digit ← if '0' ≤ c && c ≤ '9' then some (c.toNat - '0'.toNat)
      else if 'A' ≤ c && c ≤ 'F' then some (c.toNat - 'A'.toNat + 10)
      else if 'a' ≤ c && c ≤ 'f' then some (c.toNat - 'a'.toNat + 10) else none
    pure (value * 16 + digit)) (some 0)

private def unicodeTableRange (reference : ProfileRef) (text : String) :
    Except DeclarationFailure CodepointRange := do
  let parse := fun text => match hexadecimalNat text with
    | some value => Except.ok value
    | none => Except.error (.invalidProfile reference ("Unicode range " ++ text))
  let (first, last) ← match text.splitOn ".." with
    | [point] => do let point ← parse point; pure (point, point)
    | [first, last] => pure (← parse first, ← parse last)
    | _ => throw (.invalidProfile reference ("Unicode range " ++ text))
  if last < first || last > 1114111 then throw (.invalidProfile reference ("Unicode range " ++ text))
  pure { first, last }

private def unicodeTableRows (text : String) : List (List String) :=
  (text.splitOn "\n").filterMap fun line =>
    let body := trimTableField ((line.splitOn "#").head?.getD "")
    if body == "" then none else some ((body.splitOn ";").map trimTableField)

private def parseGraphemeProperty (name : String) : Option GraphemeProperty :=
  match name with
  | "Other" => some .other | "CR" => some .cr | "LF" => some .lf | "Control" => some .control
  | "Extend" => some .extend | "ZWJ" => some .zwj | "Regional_Indicator" => some .regionalIndicator
  | "Prepend" => some .prepend | "SpacingMark" => some .spacingMark
  | "L" => some .l | "V" => some .v | "T" => some .t | "LV" => some .lv | "LVT" => some .lvt
  | _ => none

def parseGraphemeTables (reference : ProfileRef) (graphemeBreakProperty emojiData derivedCoreProperties : String) :
    Except DeclarationFailure GraphemeRules := do
  let properties ← (unicodeTableRows graphemeBreakProperty).mapM fun row => match row with
    | [range, property] => do
      let range ← unicodeTableRange reference range
      let some property := parseGraphemeProperty property |
        throw (.invalidProfile reference ("Grapheme property " ++ property))
      pure { first := range.first, last := range.last, property : GraphemeRange }
    | _ => throw (.invalidProfile reference "Grapheme property row")
  let extendedPictographic ← (unicodeTableRows emojiData).foldlM (init := []) fun ranges row => match row with
    | [range, "Extended_Pictographic"] => do
      pure ((← unicodeTableRange reference range) :: ranges)
    | _ => pure ranges
  let indicConjunct ← (unicodeTableRows derivedCoreProperties).foldlM (init := []) fun ranges row => match row with
    | [range, "InCB", property] => do
      let range ← unicodeTableRange reference range
      let property ← match property with
        | "Consonant" => pure IndicProperty.consonant
        | "Extend" => pure IndicProperty.extend
        | "Linker" => pure IndicProperty.linker
        | "None" => pure IndicProperty.other
        | _ => throw (.invalidProfile reference ("Indic conjunct property " ++ property))
      pure ({ first := range.first, last := range.last, property } :: ranges)
    | _ => pure ranges
  let rules : GraphemeRules :=
    { reference, properties, extendedPictographic := extendedPictographic.reverse, indicConjunct := indicConjunct.reverse }
  if rules.properties.isEmpty || rules.extendedPictographic.isEmpty || rules.indicConjunct.isEmpty then
    throw (.invalidProfile reference "missing Unicode property tables")
  pure rules

theorem integer_member_has_integer_value (graph : SemanticGraph) (ref : TypeRef) (path : ValuePath)
    (node : TypeNode) (spec : IntegerSpec) (lookup : graph.findType ref = some node)
    (shape : node.shape = .integer spec) (value : JsonValue)
    (member : ValueMember graph ref path value) :
    ∃ integer,
      (integerBinding graph.profile spec.domain).bind
          (fun binding => integerValueForBinding binding value) = some integer ∧
        integerCondition graph.profile spec value = none := by
  obtain ⟨children, expansion, members⟩ :=
    member_expansion_has_members graph ref path value member
  have accepted : integerCondition graph.profile spec value = none := by
    cases condition : integerCondition graph.profile spec value with
    | none => rfl
    | some failed => simp [expandValue, expandNode, lookup, shape, condition] at expansion
  have acceptedCondition := accepted
  unfold integerCondition at accepted
  cases binding : integerBinding graph.profile spec.domain with
  | none => simp [binding] at accepted
  | some domain =>
    cases parsed : integerValueForBindingInRange domain value with
    | none => simp [binding, parsed] at accepted
    | some parsedInteger =>
      cases parsedInteger with
      | none => simp [binding, parsed] at accepted
      | some integer =>
        have original : integerValueForBinding domain value = some integer := by
          unfold integerValueForBindingInRange at parsed
          cases range : domain.range with
          | unbounded => simpa [range] using parsed
          | inclusive minimum maximum =>
            rw [range] at parsed
            let exceedsRangeDigits :=
              match value with
              | .dec text =>
                domain.forms.contains .integralDecimal &&
                  decimalMagnitudeExceedsRangeDigits minimum maximum text
              | .str text =>
                domain.forms.contains .decimalString &&
                  decimalMagnitudeExceedsRangeDigits minimum maximum text
              | _ => false
            change (if exceedsRangeDigits then some none
              else match integerValueForBinding domain value with
                | none => none
                | some actual =>
                  if integerRangeAccepts (.inclusive minimum maximum) actual then
                    some (some actual)
                  else some none) = some (some integer) at parsed
            by_cases exceeds : exceedsRangeDigits = true
            · simp [exceeds] at parsed
            · cases original : integerValueForBinding domain value with
              | none => simp [exceeds, original] at parsed
              | some actual =>
                by_cases inRange :
                    integerRangeAccepts (.inclusive minimum maximum) actual = true
                · simp [exceeds, original, inRange] at parsed
                  simpa [parsed] using original
                · simp [exceeds, original, inRange] at parsed
        exact ⟨integer, by simp [binding, original], acceptedCondition⟩

theorem validated_integer_has_integer_value (graph : SemanticGraph) (ref : TypeRef)
    (node : TypeNode) (spec : IntegerSpec) (lookup : graph.findType ref = some node)
    (shape : node.shape = .integer spec) (value : JsonValue) (checked : ValidatedValue graph ref value) :
    ∃ integer,
      (integerBinding graph.profile spec.domain).bind
          (fun binding => integerValueForBinding binding value) = some integer ∧
        integerCondition graph.profile spec value = none :=
  integer_member_has_integer_value graph ref [] node spec lookup shape value checked.member

theorem member_certificate_sound (graph : SemanticGraph) (slot : SlotContract) (value : SlotValue)
    (certificate : MemberCertificate) (checked : ValidatedSlot graph slot value)
    (_verified : checkMemberCertificate graph slot value certificate = .ok checked) :
    Slots graph slot value :=
  ⟨checked.meaning, checked.member⟩

theorem expandValue_rejected_not_member (graph : SemanticGraph) (ref : TypeRef)
    (path : ValuePath) (value : JsonValue) (failure : ValueFailure)
    (rejected : expandValue graph ref path value = .rejected failure) :
    ¬ ValueMember graph ref path value := by
  intro member
  obtain ⟨children, expansion, _⟩ := member_expansion_has_members graph ref path value member
  rw [rejected] at expansion
  contradiction

theorem expandValue_unresolved_not_member (graph : SemanticGraph) (ref : TypeRef)
    (path : ValuePath) (value : JsonValue) (obligations : List SemanticObligation)
    (unresolved : expandValue graph ref path value = .unresolved obligations) :
    ¬ ValueMember graph ref path value := by
  intro member
  obtain ⟨children, expansion, _⟩ := member_expansion_has_members graph ref path value member
  rw [unresolved] at expansion
  contradiction

theorem slotRequirements_parent_irrelevant (graph : SemanticGraph) (source destination : TypeRef)
    (path : ValuePath) (members : List (String × JsonValue)) (fields : List FieldSpec) :
    slotRequirements graph source path members fields = slotRequirements graph destination path members fields := by
  induction fields with
  | nil => rfl
  | cons field rest ih => simp only [slotRequirements, ih]
theorem productRequirements_parent_irrelevant (graph : SemanticGraph)
    (source destination : TypeRef) (path : ValuePath)
    (spec : ProductSpec) (members : List (String × JsonValue)) :
    productRequirements graph source path spec members =
      productRequirements graph destination path spec members := by
  unfold productRequirements
  rw [slotRequirements_parent_irrelevant graph source destination path]


set_option maxRecDepth 4096 in
theorem same_shape_expansion_requirements (graph : SemanticGraph) (source destination : TypeRef)
    (sourceNode destinationNode : TypeNode) (path : ValuePath) (value : JsonValue)
    (children : List ValueRequirement) (sourceLookup : graph.findType source = some sourceNode)
    (destinationLookup : graph.findType destination = some destinationNode)
    (same : sourceNode.shape = destinationNode.shape)
    (expansion : expandValue graph source path value = .requirements children) :
    expandValue graph destination path value = .requirements children := by
  unfold expandValue at expansion ⊢
  rw [sourceLookup] at expansion
  rw [destinationLookup]
  cases sourceNode with
  | mk ref shape description attributes extensions =>
    cases destinationNode with
    | mk ref' shape' description' attributes' extensions' =>
      dsimp only at same
      subst shape'
      cases shape <;> cases value <;>
        simp only [expandNode, objectMemberFailure] at expansion ⊢
      all_goals repeat' (first | contradiction | split at expansion)
      all_goals try simp_all only [reduceCtorEq, ite_true, ite_false,
        productRequirements_parent_irrelevant graph source destination path]


mutual
  private theorem dataValueFailure_none_path (profile : VersionedSemanticProfile)
      (source destination : ValuePath) (value : JsonValue)
      (accepted : dataValueFailure profile source value = none) :
      dataValueFailure profile destination value = none := by
    cases value <;> simp only [dataValueFailure] at accepted ⊢ <;>
      repeat' (first | contradiction | split at accepted)
    all_goals try simp_all only [ite_true, ite_false, reduceCtorEq]
    all_goals try simp_all
    all_goals first
      | exact dataItemsFailure_none_path profile source destination 0 _ accepted
      | exact dataMembersFailure_none_path profile source destination _ accepted
      | exact dataSealedMembersFailure_none_path profile source destination _ _ _ accepted
    termination_by structural value
  private theorem dataItemsFailure_none_path (profile : VersionedSemanticProfile)
      (source destination : ValuePath) (index : Nat) (values : List JsonValue)
      (accepted : dataItemsFailure profile source index values = none) :
      dataItemsFailure profile destination index values = none := by
    cases values with
    | nil => rfl
    | cons value rest =>
      cases hv : dataValueFailure profile (source ++ [.index index]) value with
      | some failed => simp [dataItemsFailure, hv] at accepted
      | none =>
        have target := dataValueFailure_none_path profile _ (destination ++ [.index index]) value hv
        have tail : dataItemsFailure profile source (index + 1) rest = none := by
          simpa [dataItemsFailure, hv] using accepted
        simp only [dataItemsFailure, target]
        exact dataItemsFailure_none_path profile source destination (index + 1) rest tail
    termination_by structural values
  private theorem dataMembersFailure_none_path (profile : VersionedSemanticProfile)
      (source destination : ValuePath) (values : List (String × JsonValue))
      (accepted : dataMembersFailure profile source values = none) :
      dataMembersFailure profile destination values = none := by
    cases values with
    | nil => rfl
    | cons pair rest =>
      obtain ⟨key, value⟩ := pair
      cases hk : unicodeValid key with
      | false => simp [dataMembersFailure, hk] at accepted
      | true =>
        cases hv : dataValueFailure profile (source ++ [.field key]) value with
        | some failed => simp [dataMembersFailure, hk, hv] at accepted
        | none =>
          have target := dataValueFailure_none_path profile _ (destination ++ [.field key]) value hv
          have tail : dataMembersFailure profile source rest = none := by
            simpa [dataMembersFailure, hk, hv] using accepted
          simp only [dataMembersFailure, hk, Bool.not_true, Bool.false_eq_true, ↓reduceIte, target]
          exact dataMembersFailure_none_path profile source destination rest tail
    termination_by structural values
  private theorem dataSealedMembersFailure_none_path (profile : VersionedSemanticProfile)
      (source destination : ValuePath) (tag : TagModel) (form : SealedForm)
      (values : List (String × JsonValue))
      (accepted : dataSealedMembersFailure profile source tag form values = none) :
      dataSealedMembersFailure profile destination tag form values = none := by
    cases values with
    | nil => rfl
    | cons pair rest =>
      obtain ⟨key, value⟩ := pair
      cases known : sealedKnownField tag form key with
      | true =>
        simpa [dataSealedMembersFailure, known] using
          dataSealedMembersFailure_none_path profile source destination tag form rest
            (by simpa [dataSealedMembersFailure, known] using accepted)
      | false =>
        cases reject : (form.extras == .reject) with
        | true => simp [dataSealedMembersFailure, known, reject] at accepted
        | false =>
          cases hk : unicodeValid key with
          | false => simp [dataSealedMembersFailure, known, reject, hk] at accepted
          | true =>
            cases hv : dataValueFailure profile (source ++ [.field key]) value with
            | some failed =>
              simp [dataSealedMembersFailure, known, reject, hk, hv] at accepted
            | none =>
              have target := dataValueFailure_none_path profile _
                (destination ++ [.field key]) value hv
              have tail : dataSealedMembersFailure profile source tag form rest = none := by
                simpa [dataSealedMembersFailure, known, reject, hk, hv] using accepted
              simpa [dataSealedMembersFailure, known, reject, hk, target] using
                dataSealedMembersFailure_none_path profile source destination tag form rest tail
    termination_by structural values
end

mutual
  private theorem jsonValueFailure_none_path (source destination : ValuePath) (value : JsonValue)
      (accepted : jsonValueFailure source value = none) :
      jsonValueFailure destination value = none := by
    cases value <;> simp only [jsonValueFailure] at accepted ⊢ <;>
      repeat' (first | contradiction | split at accepted)
    all_goals try simp_all only [ite_true]
    all_goals first
      | exact jsonItemsFailure_none_path source destination 0 _ accepted
      | exact jsonMembersFailure_none_path source destination _ accepted
    termination_by structural value
  private theorem jsonItemsFailure_none_path (source destination : ValuePath)
      (index : Nat) (values : List JsonValue)
      (accepted : jsonItemsFailure source index values = none) :
      jsonItemsFailure destination index values = none := by
    cases values with
    | nil => rfl
    | cons value rest =>
      cases hv : jsonValueFailure (source ++ [.index index]) value with
      | some failed => simp [jsonItemsFailure, hv] at accepted
      | none =>
        have target := jsonValueFailure_none_path _ (destination ++ [.index index]) value hv
        have tail : jsonItemsFailure source (index + 1) rest = none := by
          simpa [jsonItemsFailure, hv] using accepted
        simp only [jsonItemsFailure, target]
        exact jsonItemsFailure_none_path source destination (index + 1) rest tail
    termination_by structural values
  private theorem jsonMembersFailure_none_path (source destination : ValuePath)
      (values : List (String × JsonValue))
      (accepted : jsonMembersFailure source values = none) :
      jsonMembersFailure destination values = none := by
    cases values with
    | nil => rfl
    | cons pair rest =>
      obtain ⟨key, value⟩ := pair
      cases hk : unicodeValid key with
      | false => simp [jsonMembersFailure, hk] at accepted
      | true =>
        cases hv : jsonValueFailure (source ++ [.field key]) value with
        | some failed => simp [jsonMembersFailure, hk, hv] at accepted
        | none =>
          have target := jsonValueFailure_none_path _ (destination ++ [.field key]) value hv
          have tail : jsonMembersFailure source rest = none := by
            simpa [jsonMembersFailure, hk, hv] using accepted
          simp only [jsonMembersFailure, hk, Bool.not_true, Bool.false_eq_true, ↓reduceIte, target]
          exact jsonMembersFailure_none_path source destination rest tail
    termination_by structural values
end

private def requirementValues (expansion : Expansion) : Option (List (TypeRef × JsonValue)) :=
  match expansion with
  | .requirements children => some (children.map (fun child => (child.typeRef, child.value)))
  | _ => none

private theorem slotRequirements_path_values (graph : SemanticGraph) (ref : TypeRef)
    (source destination : ValuePath) (entries : List (String × JsonValue)) (fields : List FieldSpec) :
    requirementValues (slotRequirements graph ref source entries fields) =
      requirementValues (slotRequirements graph ref destination entries fields) := by
  induction fields with
  | nil => rfl
  | cons field rest ih =>
    cases hs : slotRequirements graph ref source entries rest <;>
      cases hd : slotRequirements graph ref destination entries rest <;>
      simp only [hs, hd, requirementValues, Option.some.injEq, reduceCtorEq] at ih
    all_goals try contradiction
    all_goals cases hv : memberValue field.wireName entries
    all_goals try (rename_i value; cases value)
    all_goals simp only [slotRequirements, hv]
    all_goals repeat' (first | split | split at ih)
    all_goals simp_all [requirementValues]

private theorem option_isNone_eq_of_none_iff {α : Type} (left right : Option α)
    (same : left = none ↔ right = none) : left.isNone = right.isNone := by
  cases left <;> cases right <;> simp_all
private theorem elementRequirements_path_values (contract : ElementContract)
    (source destination : ValuePath) (value : JsonValue) :
    (elementRequirements contract source value).map (fun child => (child.typeRef, child.value)) =
      (elementRequirements contract destination value).map (fun child => (child.typeRef, child.value)) := by
  cases value <;> simp [elementRequirements] <;> split <;> simp_all
private theorem append_congr {α : Type} {left right tailLeft tailRight : List α}
    (head : left = right) (tail : tailLeft = tailRight) :
    left ++ tailLeft = right ++ tailRight := by
  rw [head, tail]
private theorem elementRequirements_list_path_values (contract : ElementContract)
    (source destination : ValuePath) (entries : List (JsonValue × Nat)) :
    entries.flatMap (fun (value, index) =>
      (elementRequirements contract (source ++ [.index index]) value).map
        (fun child => (child.typeRef, child.value))) =
    entries.flatMap (fun (value, index) =>
      (elementRequirements contract (destination ++ [.index index]) value).map
        (fun child => (child.typeRef, child.value))) := by
  induction entries with
  | nil => rfl
  | cons entry rest ih =>
    simp only [List.flatMap_cons]
    exact append_congr
      (elementRequirements_path_values contract
        (source ++ [.index entry.2]) (destination ++ [.index entry.2]) entry.1) ih
private theorem extraFieldRequirements_path_values (graph : SemanticGraph)
    (source destination : ValuePath) (spec : ProductSpec)
    (entries : List (String × JsonValue)) :
    (extraFieldRequirements graph source spec entries).map (fun child => (child.typeRef, child.value)) =
      (extraFieldRequirements graph destination spec entries).map
        (fun child => (child.typeRef, child.value)) := by
  induction entries with
  | nil => rfl
  | cons entry rest ih =>
    by_cases skip :
        (spec.fields.any (fun field => field.wireName == entry.1) ||
          (graph.profile.tag.map (fun tag => entry.1 == tag.key)).getD false) = true
    · simpa [extraFieldRequirements, skip] using ih
    · cases extras : spec.extras with
      | reject => simpa [extraFieldRequirements, skip, extras] using ih
      | allow keyFormat contract =>
        simpa [extraFieldRequirements, skip, extras, List.map_append] using
          append_congr
            (elementRequirements_path_values contract
              (source ++ [.field entry.1]) (destination ++ [.field entry.1]) entry.2) ih

private theorem productRequirements_path_values (graph : SemanticGraph) (ref : TypeRef)
    (source destination : ValuePath) (spec : ProductSpec)
    (entries : List (String × JsonValue)) :
    requirementValues (productRequirements graph ref source spec entries) =
      requirementValues (productRequirements graph ref destination spec entries) := by
  have slots := slotRequirements_path_values graph ref source destination entries spec.fields
  unfold productRequirements
  cases hs : slotRequirements graph ref source entries spec.fields <;>
    cases hd : slotRequirements graph ref destination entries spec.fields <;>
    simp only [hs, hd, requirementValues, Option.some.injEq, reduceCtorEq] at slots ⊢
  all_goals try contradiction
  simp only [List.map_append, slots,
    extraFieldRequirements_path_values graph source destination spec entries]


private theorem dataValueFailure_isNone_path (profile : VersionedSemanticProfile)
    (source destination : ValuePath) (value : JsonValue) :
    (dataValueFailure profile source value).isNone = (dataValueFailure profile destination value).isNone :=
  option_isNone_eq_of_none_iff _ _
    ⟨dataValueFailure_none_path profile source destination value,
      dataValueFailure_none_path profile destination source value⟩

private theorem dataMembersFailure_isNone_path (profile : VersionedSemanticProfile)
    (source destination : ValuePath) (values : List (String × JsonValue)) :
    (dataMembersFailure profile source values).isNone = (dataMembersFailure profile destination values).isNone :=
  option_isNone_eq_of_none_iff _ _
    ⟨dataMembersFailure_none_path profile source destination values,
      dataMembersFailure_none_path profile destination source values⟩

private theorem jsonValueFailure_isNone_path (source destination : ValuePath) (value : JsonValue) :
    (jsonValueFailure source value).isNone = (jsonValueFailure destination value).isNone :=
  option_isNone_eq_of_none_iff _ _
    ⟨jsonValueFailure_none_path source destination value,
      jsonValueFailure_none_path destination source value⟩

private theorem jsonMembersFailure_isNone_path (source destination : ValuePath)
    (values : List (String × JsonValue)) :
    (jsonMembersFailure source values).isNone = (jsonMembersFailure destination values).isNone :=
  option_isNone_eq_of_none_iff _ _
    ⟨jsonMembersFailure_none_path source destination values,
      jsonMembersFailure_none_path destination source values⟩

private theorem requirementValues_ite (condition : Prop) [Decidable condition]
    (positive negative : Expansion) :
    requirementValues (if condition then positive else negative) =
      if condition then requirementValues positive else requirementValues negative := by
  split <;> rfl

private theorem failureAtChoiceValues (failed : Option DataFailure) (ref : TypeRef) :
    requirementValues (match failed with
      | none => .requirements []
      | some (here, condition, observed) =>
        .rejected (failureAt ref here (.present observed) condition)) =
      if failed.isNone then some [] else none := by
  cases failed with
  | none => rfl
  | some failure => obtain ⟨here, condition, observed⟩ := failure; rfl

private theorem failureAtOrValues (failed : Option DataFailure) (ref : TypeRef)
    (next : Expansion) :
    requirementValues (match failed with
      | none => next
      | some (here, condition, observed) =>
        .rejected (failureAt ref here (.present observed) condition)) =
      if failed.isNone then requirementValues next else none := by
  cases failed with
  | none => rfl
  | some failure => obtain ⟨here, condition, observed⟩ := failure; rfl

private theorem optionIsNone_ite {α : Type} (condition : Prop) [Decidable condition]
    (positive negative : Option α) :
    (if condition then positive else negative).isNone =
      if condition then positive.isNone else negative.isNone := by
  split <;> rfl

private theorem expandValue_path_values (graph : SemanticGraph) (ref : TypeRef)
    (source destination : ValuePath) (value : JsonValue) :
    requirementValues (expandValue graph ref source value) =
      requirementValues (expandValue graph ref destination value) := by
  cases lookup : graph.findType ref with
  | none => simp [expandValue, lookup, expandNode, requirementValues]
  | some node =>
    cases node with
    | mk identity shape description attributes extensions =>
      cases shape <;> cases value
      all_goals simp only [expandValue, lookup]
      all_goals simp only [expandNode, objectMemberFailure]
      all_goals try simp only [requirementValues_ite, failureAtChoiceValues,
        failureAtOrValues, optionIsNone_ite,
        dataValueFailure_isNone_path graph.profile source destination,
        dataMembersFailure_isNone_path graph.profile source destination,
        jsonValueFailure_isNone_path source destination,
        jsonMembersFailure_isNone_path source destination]
      all_goals repeat' (first | rfl | (split <;>
        try simp only [requirementValues_ite, failureAtChoiceValues, failureAtOrValues,
          optionIsNone_ite,
          dataValueFailure_isNone_path graph.profile source destination,
          dataMembersFailure_isNone_path graph.profile source destination,
          jsonValueFailure_isNone_path source destination,
          jsonMembersFailure_isNone_path source destination]))
      all_goals try simp_all only [requirementValues, List.map_map, Function.comp_def,
        List.map_flatMap, elementRequirements_path_values]
      all_goals try exact productRequirements_path_values graph ref source destination _ _
      all_goals try exact congrArg some (elementRequirements_list_path_values _ source destination _)
      all_goals try exact slotRequirements_path_values graph ref source destination _ _

theorem valueMember_path_irrelevant (graph : SemanticGraph) (ref : TypeRef)
    (source destination : ValuePath) (value : JsonValue)
    (member : ValueMember graph ref source value) : ValueMember graph ref destination value := by
  induction member generalizing destination with
  | step ref source value children expansion members ih =>
    have same := expandValue_path_values graph ref source destination value
    rw [expansion] at same
    cases targetExpansion : expandValue graph ref destination value with
    | rejected failure => simp [targetExpansion, requirementValues] at same
    | unresolved obligations => simp [targetExpansion, requirementValues] at same
    | requirements targets =>
      have equal : children.map (fun child => (child.typeRef, child.value)) =
          targets.map (fun child => (child.typeRef, child.value)) := by
        simpa [targetExpansion, requirementValues] using same
      refine .step ref destination value targets targetExpansion ?_
      intro target present
      have declared : (target.typeRef, target.value) ∈
          children.map (fun child => (child.typeRef, child.value)) := by
        rw [equal]
        exact List.mem_map.mpr ⟨target, present, rfl⟩
      obtain ⟨child, childPresent, childEqual⟩ := List.mem_map.mp declared
      have transported := ih child childPresent target.valuePath
      have identities := Prod.mk.inj childEqual
      simpa only [identities.1, identities.2] using transported

private theorem slotRequirements_field_sound (graph : SemanticGraph) (ref : TypeRef)
    (path : ValuePath) (entries : List (String × JsonValue)) (fields : List FieldSpec)
    (children : List ValueRequirement)
    (expansion : slotRequirements graph ref path entries fields = .requirements children)
    (members : ∀ child ∈ children, ValueMember graph child.typeRef child.valuePath child.value)
    (field : FieldSpec) (declared : field ∈ fields) :
    SlotMember graph field.slot (valueAtPath graph.profile (.obj entries) [.field field.wireName]) := by
  induction fields generalizing children with
  | nil => simp at declared
  | cons first rest ih =>
    cases hv : memberValue first.wireName entries with
    | none =>
      have optional : first.slot.required = false := by
        cases h : first.slot.required
        · rfl
        · simp [slotRequirements, hv, h] at expansion
      have tail : slotRequirements graph ref path entries rest = .requirements children := by
        cases ht : slotRequirements graph ref path entries rest <;>
          simpa [slotRequirements, hv, optional, ht] using expansion
      rcases List.mem_cons.mp declared with equal | present
      · subst field
        simpa [valueAtPath, hv] using SlotMember.absent first.slot optional
      · exact ih children tail members present
    | some value =>
      cases value with
      | null =>
        have nullable : first.slot.nullable = true := by
          cases h : first.slot.nullable
          · simp [slotRequirements, hv, h] at expansion
          · rfl
        have tail : slotRequirements graph ref path entries rest = .requirements children := by
          cases ht : slotRequirements graph ref path entries rest <;>
            simpa [slotRequirements, hv, nullable, ht] using expansion
        rcases List.mem_cons.mp declared with equal | present
        · subst field
          simpa [valueAtPath, hv] using SlotMember.null first.slot nullable
        · exact ih children tail members present
      | bool b | num b | dec b | str b | arr b | obj b =>
        cases ht : slotRequirements graph ref path entries rest with
        | rejected failure => simp [slotRequirements, hv, ht] at expansion
        | unresolved obligations => simp [slotRequirements, hv, ht] at expansion
        | requirements tail =>
          have identity : children =
              { typeRef := first.slot.typeRef, valuePath := path ++ [.field first.wireName],
                value := (memberValue first.wireName entries).getD .null } :: tail := by
            simpa [slotRequirements, hv, ht] using expansion.symm
          subst children
          rcases List.mem_cons.mp declared with equal | present
          · subst field
            have childMember := members
              { typeRef := first.slot.typeRef, valuePath := path ++ [.field first.wireName],
                value := (memberValue first.wireName entries).getD .null } List.mem_cons_self
            have rooted := valueMember_path_irrelevant graph _ _ [] _ childMember
            simpa [valueAtPath, hv] using SlotMember.present first.slot _ rooted
          · exact ih tail ht (fun child present => members child (List.mem_cons_of_mem _ present)) present

private theorem product_member_field_sound (graph : SemanticGraph) (ref : TypeRef)
    (node : TypeNode) (spec : ProductSpec) (lookup : graph.findType ref = some node)
    (shape : node.shape = .product spec) (entries : List (String × JsonValue))
    (member : ValueMember graph ref [] (.obj entries)) (field : FieldSpec)
    (declared : field ∈ spec.fields) :
    SlotMember graph field.slot (valueAtPath graph.profile (.obj entries) [.field field.wireName]) := by
  obtain ⟨children, expansion, members⟩ := member_expansion_has_members graph ref [] _ member
  simp only [expandValue, expandNode, objectMemberFailure, lookup, shape] at expansion
  repeat' (first | contradiction | split at expansion)
  all_goals try simp_all only [reduceCtorEq]
  unfold productRequirements at expansion
  cases fieldsExpansion : slotRequirements graph ref [] entries spec.fields with
  | rejected failure => simp [fieldsExpansion] at expansion
  | unresolved obligations => simp [fieldsExpansion] at expansion
  | requirements fields =>
    have identity :
        children = fields ++ extraFieldRequirements graph [] spec entries := by
      simpa [fieldsExpansion] using expansion.symm
    subst children
    exact slotRequirements_field_sound graph ref [] entries spec.fields fields fieldsExpansion
      (fun child present => members child (List.mem_append_left _ present)) field declared

private theorem valueAtPath_append (profile : VersionedSemanticProfile)
    (value : JsonValue) (before suffix : ValuePath) :
    projectedValue profile (valueAtPath profile value before) suffix =
      valueAtPath profile value (before ++ suffix) := by
  induction before generalizing value with
  | nil => simp [valueAtPath, projectedValue]
  | cons step rest ih =>
    cases value with
    | obj members =>
      cases step with
      | field name =>
        cases h : memberValue name members with
        | none => simp [valueAtPath, projectedValue, h]
        | some inner =>
          cases inner <;> first
            | (simp only [List.cons_append, valueAtPath, h]; rfl)
            | (simp only [List.cons_append, valueAtPath, h]; exact ih _)
      | index index => simp [valueAtPath, projectedValue]
      | variant tag =>
        by_cases h : tagMatches profile members tag = true
        · simp only [List.cons_append, valueAtPath, h, if_true]
          exact ih _
        · simp [valueAtPath, projectedValue, h]
    | arr items =>
      cases step with
      | index index =>
        cases h : items[index]? with
        | none => simp [valueAtPath, projectedValue, h]
        | some inner =>
          cases inner <;> first
            | (simp only [List.cons_append, valueAtPath, h]; rfl)
            | (simp only [List.cons_append, valueAtPath, h]; exact ih _)
      | field name => simp [valueAtPath, projectedValue]
      | variant tag => simp [valueAtPath, projectedValue]
    | null => cases step <;> simp [valueAtPath, projectedValue]
    | bool _ => cases step <;> simp [valueAtPath, projectedValue]
    | num _ => cases step <;> simp [valueAtPath, projectedValue]
    | dec _ => cases step <;> simp [valueAtPath, projectedValue]
    | str _ => cases step <;> simp [valueAtPath, projectedValue]

private theorem projectedValue_append (profile : VersionedSemanticProfile)
    (source : SlotValue) (before suffix : ValuePath) :
    projectedValue profile (projectedValue profile source before) suffix =
      projectedValue profile source (before ++ suffix) := by
  cases source with
  | absent => rfl
  | null => rfl
  | present value => exact valueAtPath_append profile value before suffix

private theorem observedAssumption_present (profile : VersionedSemanticProfile)
    (source : SlotValue) (path : ValuePath)
    (assumption : ProjectionAssumption)
    (observed : (match assumption with
      | .present observed | .variant observed _ | .indexPresent observed _ => decide (observed = path)
      | _ => false) = true)
    (guarded : slotAssumptionHolds profile source assumption = true) :
    ∃ value, projectedValue profile source path = .present value := by
  cases assumption with
  | nonNull observedPath => simp at observed
  | present observedPath =>
    have same : observedPath = path := by simpa using observed
    subst same
    cases source with
    | absent => simp [slotAssumptionHolds] at guarded
    | null => simp [slotAssumptionHolds] at guarded
    | present value =>
      cases here : valueAtPath profile value observedPath with
      | absent => simp [slotAssumptionHolds, assumptionHolds, here] at guarded
      | null => simp [slotAssumptionHolds, assumptionHolds, here] at guarded
      | present actual => exact ⟨actual, here⟩
  | variant observedPath tag =>
    have same : observedPath = path := by simpa using observed
    subst same
    cases source with
    | absent => simp [slotAssumptionHolds] at guarded
    | null => simp [slotAssumptionHolds] at guarded
    | present value =>
      cases here : valueAtPath profile value observedPath with
      | absent => simp [slotAssumptionHolds, assumptionHolds, here] at guarded
      | null => simp [slotAssumptionHolds, assumptionHolds, here] at guarded
      | present actual => exact ⟨actual, here⟩
  | indexPresent observedPath index =>
    have same : observedPath = path := by simpa using observed
    subst same
    cases source with
    | absent => simp [slotAssumptionHolds] at guarded
    | null => simp [slotAssumptionHolds] at guarded
    | present value =>
      cases here : valueAtPath profile value observedPath with
      | absent => simp [slotAssumptionHolds, assumptionHolds, here] at guarded
      | null => simp [slotAssumptionHolds, assumptionHolds, here] at guarded
      | present actual => exact ⟨actual, here⟩

private theorem nonNullAssumption_not_null (profile : VersionedSemanticProfile)
    (source : SlotValue) (path : ValuePath)
    (guarded : slotAssumptionHolds profile source (.nonNull path) = true) :
    projectedValue profile source path ≠ .null := by
  intro same
  cases source with
  | absent => simp [projectedValue] at same
  | null => simp [slotAssumptionHolds] at guarded
  | present value =>
    have here : valueAtPath profile value path = .null := same
    simp [slotAssumptionHolds, assumptionHolds, here] at guarded

private theorem strengthenProjection_member_sound (graph : SemanticGraph) (source : SlotValue)
    (slot : SlotContract) (path : ValuePath) (assumptions : List ProjectionAssumption)
    (guarded : ∀ assumption ∈ assumptions, slotAssumptionHolds graph.profile source assumption = true)
    (member : SlotMember graph slot (projectedValue graph.profile source path)) :
    SlotMember graph (strengthenProjection slot path assumptions) (projectedValue graph.profile source path) := by
  let observed := assumptions.any fun assumption => match assumption with
    | .present observed | .variant observed _ | .indexPresent observed _ => decide (observed = path)
    | _ => false
  have present : observed = true → ∃ value, projectedValue graph.profile source path = .present value := by
    intro yes
    obtain ⟨assumption, declared, here⟩ := List.any_eq_true.mp yes
    exact observedAssumption_present graph.profile source path assumption here (guarded assumption declared)
  have nonnull : .nonNull path ∈ assumptions → projectedValue graph.profile source path ≠ .null := by
    intro declared
    exact nonNullAssumption_not_null graph.profile source path (guarded _ declared)
  have shape : strengthenProjection slot path assumptions =
      if observed = true then { slot with required := true, nullable := false }
      else if decide (ProjectionAssumption.nonNull path ∈ assumptions) then { slot with nullable := false }
      else slot := rfl
  generalize valueEq : projectedValue graph.profile source path = value at member
  cases member with
  | absent optional =>
    have noObserved : observed = false := by
      cases ho : observed
      · rfl
      · obtain ⟨actual, impossible⟩ := present ho
        rw [valueEq] at impossible
        contradiction
    rw [shape, if_neg (by simp [noObserved])]
    split <;> exact .absent _ optional
  | null nullable =>
    have noObserved : observed = false := by
      cases ho : observed
      · rfl
      · obtain ⟨actual, impossible⟩ := present ho
        rw [valueEq] at impossible
        contradiction
    have noNonNull : ProjectionAssumption.nonNull path ∉ assumptions := fun declared => nonnull declared valueEq
    rw [shape, if_neg (by simp [noObserved]), if_neg (by simpa using noNonNull)]
    exact .null _ nullable
  | present actual accepted =>
    rw [shape]
    split <;> try split
    all_goals exact .present _ actual accepted

private theorem slotMember_type_transport (graph : SemanticGraph) (slot : SlotContract) (target : TypeRef)
    (values : ∀ value, ValueMember graph slot.typeRef [] value → ValueMember graph target [] value)
    (value : SlotValue) (member : SlotMember graph slot value) :
    SlotMember graph { slot with typeRef := target } value := by
  cases member with
  | absent optional => exact .absent _ optional
  | null nullable => exact .null _ nullable
  | present value accepted => exact .present _ value (values value accepted)

private theorem alias_member_target (graph : SemanticGraph) (ref target : TypeRef)
    (node : TypeNode) (text : String) (lookup : graph.findType ref = some node)
    (shape : node.shape = .alias target text) (value : JsonValue)
    (member : ValueMember graph ref [] value) : ValueMember graph target [] value := by
  obtain ⟨children, expansion, members⟩ := member_expansion_has_members graph ref [] value member
  have identity : children = [{ typeRef := target, valuePath := [], value }] := by
    simpa [expandValue, expandNode, lookup, shape] using expansion.symm
  subst children
  exact members { typeRef := target, valuePath := [], value } List.mem_cons_self

theorem lengthAccepts_minimum (minimum maximum : Option Nat) (length : Nat)
    (accepted : lengthAccepts minimum maximum length = true) :
    minimum.getD 0 ≤ length := by
  cases minimum with
  | none => simp
  | some lower =>
    simp only [lengthAccepts, Option.map_some, Option.getD_some, Bool.and_eq_true,
      decide_eq_true_eq] at accepted
    simpa using accepted.1

private theorem zipIdx_contains_get (values : List JsonValue) (index offset : Nat) (value : JsonValue)
    (found : values[index]? = some value) : (value, offset + index) ∈ values.zipIdx offset := by
  induction values generalizing index offset with
  | nil => simp at found
  | cons head rest ih =>
    cases index with
    | zero =>
      have equal : head = value := by simpa using found
      subst head
      simp
    | succ index =>
      have tail : rest[index]? = some value := by simpa using found
      simpa [Nat.add_assoc, Nat.add_comm, Nat.add_left_comm] using
        List.mem_cons_of_mem (head, offset) (ih index (offset + 1) tail)

private theorem array_member_parts (graph : SemanticGraph) (ref : TypeRef)
    (node : TypeNode) (spec : ArraySpec) (lookup : graph.findType ref = some node)
    (shape : node.shape = .array spec) (values : List JsonValue)
    (member : ValueMember graph ref [] (.arr values)) :
    spec.minLength.getD 0 ≤ values.length ∧
      ∀ (index : Nat) (value : JsonValue), values[index]? = some value →
        match value with
        | .null => spec.item.nullable = true ∨ ValueMember graph spec.item.typeRef [] .null
        | value => ValueMember graph spec.item.typeRef [] value := by
  obtain ⟨children, expansion, members⟩ := member_expansion_has_members graph ref [] _ member
  have accepted : lengthAccepts spec.minLength spec.maxLength values.length = true := by
    cases length : lengthAccepts spec.minLength spec.maxLength values.length
    · simp [expandValue, expandNode, lookup, shape, length] at expansion
    · rfl
  have identity : children = values.zipIdx.flatMap (fun (value, index) =>
      elementRequirements spec.item [.index index] value) := by
    simpa [expandValue, expandNode, lookup, shape, accepted] using expansion.symm
  subst children
  refine ⟨lengthAccepts_minimum _ _ _ accepted, ?_⟩
  intro index value found
  have declared : (value, index) ∈ values.zipIdx := by
    simpa using zipIdx_contains_get values index 0 value found
  cases value with
  | null =>
    cases nullable : spec.item.nullable
    · right
      have child := members
        { typeRef := spec.item.typeRef, valuePath := [.index index], value := .null }
        (List.mem_flatMap.mpr ⟨(.null, index), declared, by
          simp [elementRequirements, nullable]⟩)
      exact valueMember_path_irrelevant graph _ _ [] .null child
    · exact Or.inl rfl
  | bool value =>
    have child := members
      { typeRef := spec.item.typeRef, valuePath := [.index index], value := .bool value }
      (List.mem_flatMap.mpr ⟨(.bool value, index), declared, by simp [elementRequirements]⟩)
    exact valueMember_path_irrelevant graph _ _ [] _ child
  | num value =>
    have child := members
      { typeRef := spec.item.typeRef, valuePath := [.index index], value := .num value }
      (List.mem_flatMap.mpr ⟨(.num value, index), declared, by simp [elementRequirements]⟩)
    exact valueMember_path_irrelevant graph _ _ [] _ child
  | dec value =>
    have child := members
      { typeRef := spec.item.typeRef, valuePath := [.index index], value := .dec value }
      (List.mem_flatMap.mpr ⟨(.dec value, index), declared, by simp [elementRequirements]⟩)
    exact valueMember_path_irrelevant graph _ _ [] _ child
  | str value =>
    have child := members
      { typeRef := spec.item.typeRef, valuePath := [.index index], value := .str value }
      (List.mem_flatMap.mpr ⟨(.str value, index), declared, by simp [elementRequirements]⟩)
    exact valueMember_path_irrelevant graph _ _ [] _ child
  | arr value =>
    have child := members
      { typeRef := spec.item.typeRef, valuePath := [.index index], value := .arr value }
      (List.mem_flatMap.mpr ⟨(.arr value, index), declared, by simp [elementRequirements]⟩)
    exact valueMember_path_irrelevant graph _ _ [] _ child
  | obj value =>
    have child := members
      { typeRef := spec.item.typeRef, valuePath := [.index index], value := .obj value }
      (List.mem_flatMap.mpr ⟨(.obj value, index), declared, by simp [elementRequirements]⟩)
    exact valueMember_path_irrelevant graph _ _ [] _ child

private theorem variantAssumption_current (profile : VersionedSemanticProfile)
    (source : SlotValue) (path : ValuePath) (tag : String)
    (guarded : slotAssumptionHolds profile source (.variant path tag) = true) :
    ∃ entries, projectedValue profile source path = .present (.obj entries) ∧
      tagMatches profile entries tag = true := by
  cases source with
  | absent => simp [slotAssumptionHolds] at guarded
  | null => simp [slotAssumptionHolds] at guarded
  | present value =>
    cases here : valueAtPath profile value path with
    | absent => simp [slotAssumptionHolds, assumptionHolds, here] at guarded
    | null => simp [slotAssumptionHolds, assumptionHolds, here] at guarded
    | present actual =>
      cases actual <;> simp only [slotAssumptionHolds, assumptionHolds, here, Bool.false_eq_true] at guarded
      exact ⟨_, here, guarded⟩

private theorem indexAssumption_current (profile : VersionedSemanticProfile)
    (source : SlotValue) (path : ValuePath) (index : Nat)
    (values : List JsonValue) (here : projectedValue profile source path = .present (.arr values))
    (guarded : slotAssumptionHolds profile source (.indexPresent path index) = true) :
    index < values.length := by
  cases source with
  | absent => simp [projectedValue] at here
  | null => simp [projectedValue] at here
  | present value =>
    simpa [slotAssumptionHolds, assumptionHolds,
      show valueAtPath profile value path = .present (.arr values) from here] using guarded

private theorem union_member_selected (graph : SemanticGraph) (ref : TypeRef)
    (node : TypeNode) (spec : UnionSpec) (lookup : graph.findType ref = some node)
    (shape : node.shape = .taggedUnion spec) (entries : List (String × JsonValue))
    (member : ValueMember graph ref [] (.obj entries)) (branch : UnionBranch)
    (selected : selectUnionBranch graph.profile spec (.obj entries) = some branch) :
    ValueMember graph branch.target [] (.obj entries) := by
  obtain ⟨children, expansion, members⟩ :=
    member_expansion_has_members graph ref [] _ member
  cases duplicate : duplicateKey entries with
  | some key =>
    simp [expandValue, expandNode, objectMemberFailure, lookup, shape, duplicate] at expansion
  | none =>
    cases tag : tagMemberFailure graph.profile entries with
    | some failure =>
      simp [expandValue, expandNode, objectMemberFailure, lookup, shape, duplicate, tag]
        at expansion
    | none =>
      have identity :
          children = [{ typeRef := branch.target, valuePath := [], value := .obj entries }] := by
        simpa [expandValue, expandNode, objectMemberFailure, lookup, shape, duplicate, tag,
          selected] using expansion.symm
      subst children
      exact members _ List.mem_cons_self

private theorem product_member_object (graph : SemanticGraph) (ref : TypeRef)
    (node : TypeNode) (spec : ProductSpec) (lookup : graph.findType ref = some node)
    (shape : node.shape = .product spec) (value : JsonValue)
    (member : ValueMember graph ref [] value) : ∃ entries, value = .obj entries := by
  obtain ⟨children, expansion, _⟩ := member_expansion_has_members graph ref [] value member
  cases value <;> try simp [expandValue, expandNode, lookup, shape] at expansion
  exact ⟨_, rfl⟩

private theorem array_member_array (graph : SemanticGraph) (ref : TypeRef)
    (node : TypeNode) (spec : ArraySpec) (lookup : graph.findType ref = some node)
    (shape : node.shape = .array spec) (value : JsonValue)
    (member : ValueMember graph ref [] value) : ∃ values, value = .arr values := by
  obtain ⟨children, expansion, _⟩ := member_expansion_has_members graph ref [] value member
  cases value <;> try simp [expandValue, expandNode, lookup, shape] at expansion
  exact ⟨_, rfl⟩

private theorem fieldPresence_member_sound (graph : SemanticGraph) (parent child : SlotContract)
    (value : SlotValue) (member : SlotMember graph child value) :
    SlotMember graph { typeRef := child.typeRef, required := parent.required && child.required, nullable := parent.nullable || child.nullable } value := by
  cases member with
  | absent optional => exact .absent _ (by simp [optional])
  | null nullable => exact .null _ (by simp [nullable])
  | present actual accepted => exact .present _ actual accepted

private theorem fieldProjection_member_sound (graph : SemanticGraph) (source : SlotValue)
    (slot : SlotContract) (node : TypeNode) (spec : ProductSpec)
    (lookup : graph.findType slot.typeRef = some node) (shape : node.shape = .product spec)
    (member : SlotMember graph slot source) (field : FieldSpec) (declared : field ∈ spec.fields) :
    SlotMember graph { typeRef := field.slot.typeRef, required := slot.required && field.slot.required, nullable := slot.nullable || field.slot.nullable }
      (projectedValue graph.profile source [.field field.wireName]) := by
  cases member with
  | absent optional => exact .absent _ (by simp [optional])
  | null nullable => exact .null _ (by simp [nullable])
  | present value accepted =>
    obtain ⟨entries, equal⟩ := product_member_object graph slot.typeRef node spec lookup shape value accepted
    subst value
    exact fieldPresence_member_sound graph slot field.slot _
      (product_member_field_sound graph slot.typeRef node spec lookup shape entries accepted field declared)

private theorem indexProjection_member_sound (graph : SemanticGraph) (source : SlotValue)
    (slot : SlotContract) (node : TypeNode) (spec : ArraySpec)
    (lookup : graph.findType slot.typeRef = some node) (shape : node.shape = .array spec)
    (member : SlotMember graph slot source) (index : Nat) (present : Bool)
    (bounded : present = true → ∀ values, source = .present (.arr values) → index < values.length) :
    SlotMember graph {
      typeRef := spec.item.typeRef
      required := slot.required && present
      nullable := true }
      (projectedValue graph.profile source [.index index]) := by
  cases member with
  | absent optional => exact .absent _ (by simp [optional])
  | null nullable => exact .null _ (by simp [nullable])
  | present value accepted =>
    obtain ⟨values, equal⟩ := array_member_array graph slot.typeRef node spec lookup shape value accepted
    subst value
    have parts := array_member_parts graph slot.typeRef node spec lookup shape values accepted
    cases selected : values[index]? with
    | none =>
      have optional : present = false := by
        cases condition : present
        · rfl
        · have within := bounded condition values rfl
          have missing : values.length ≤ index := by simpa using selected
          omega
      simpa [projectedValue, valueAtPath, selected] using
        SlotMember.absent (graph := graph) {
          typeRef := spec.item.typeRef
          required := slot.required && present
          nullable := true } (by simp [optional])
    | some actual =>
      cases actual with
      | null =>
        simpa [projectedValue, valueAtPath, selected] using
          SlotMember.null (graph := graph) {
            typeRef := spec.item.typeRef
            required := slot.required && present
            nullable := true } rfl
      | bool value | num value | dec value | str value | arr value | obj value =>
        simpa [projectedValue, valueAtPath, selected] using
          SlotMember.present {
            typeRef := spec.item.typeRef
            required := slot.required && present
            nullable := true } _ (parts.2 index _ selected)

private theorem projectContract_member_sound (graph : SemanticGraph)
    (assumptions : List ProjectionAssumption) (source : SlotValue)
    (guarded : ∀ assumption ∈ assumptions, slotAssumptionHolds graph.profile source assumption = true)
    (fuel : Nat) (slot : SlotContract) (traversed remaining : ValuePath) (destination : SlotContract)
    (computed : projectContract graph assumptions fuel slot traversed remaining = .ok destination)
    (member : SlotMember graph slot (projectedValue graph.profile source traversed)) :
    SlotMember graph destination (projectedValue graph.profile source (traversed ++ remaining)) := by
  induction fuel generalizing slot traversed remaining destination with
  | zero => simp [projectContract] at computed
  | succ fuel ih =>
    obtain ⟨strengthened, hs⟩ : ∃ s, strengthenProjection slot traversed assumptions = s := ⟨_, rfl⟩
    have accepted : SlotMember graph strengthened (projectedValue graph.profile source traversed) := by
      rw [← hs]
      exact strengthenProjection_member_sound graph source slot traversed assumptions guarded member
    cases remaining with
    | nil =>
      have equal : strengthened = destination := by
        simp [projectContract, hs] at computed
        exact Except.ok.inj computed
      subst destination
      simpa using accepted
    | cons step rest =>
      cases lookup : graph.findType strengthened.typeRef with
      | none => simp [projectContract, hs, lookup] at computed
      | some node =>
        cases shape : node.shape with
        | alias target text =>
          apply ih { strengthened with typeRef := target } traversed (step :: rest) destination
            (by simpa [projectContract, hs, lookup, shape] using computed)
          exact slotMember_type_transport graph strengthened target
            (alias_member_target graph strengthened.typeRef target node text lookup shape)
            _ accepted
        | product spec =>
          cases step with
          | index index => simp [projectContract, hs, lookup, shape] at computed
          | variant tag => simp [projectContract, hs, lookup, shape] at computed
          | field name =>
            cases selected : spec.fields.find? (fun field => field.wireName == name) with
            | none => simp [projectContract, hs, lookup, shape, selected] at computed
            | some field =>
              have declared := List.mem_of_find?_eq_some selected
              have sameName : field.wireName = name := by simpa using List.find?_some selected
              have nextMember := fieldProjection_member_sound graph (projectedValue graph.profile source traversed)
                strengthened node spec lookup shape accepted field declared
              let next : SlotContract := { typeRef := field.slot.typeRef, required := strengthened.required && field.slot.required, nullable := strengthened.nullable || field.slot.nullable }
              have nextAccepted : SlotMember graph next (projectedValue graph.profile source (traversed ++ [.field name])) := by
                rw [← projectedValue_append]
                simpa only [sameName] using nextMember
              have nextComputed : projectContract graph assumptions fuel next
                  (traversed ++ [.field name]) rest = .ok destination := by
                simpa [projectContract, hs, lookup, shape, selected, next] using computed
              simpa [List.append_assoc] using ih next _ rest destination nextComputed nextAccepted
        | array spec =>
          cases step with
          | field name => simp [projectContract, hs, lookup, shape] at computed
          | variant tag => simp [projectContract, hs, lookup, shape] at computed
          | index index =>
            let present := index < spec.minLength.getD 0 ||
              decide (ProjectionAssumption.indexPresent traversed index ∈ assumptions)
            have bounded : present = true → ∀ values,
                projectedValue graph.profile source traversed = .present (.arr values) → index < values.length := by
              intro yes values here
              have yes' : (index < spec.minLength.getD 0 ||
                  decide (ProjectionAssumption.indexPresent traversed index ∈ assumptions)) = true := yes
              simp only [Bool.or_eq_true, decide_eq_true_eq] at yes'
              rcases yes' with lower | declared
              · have actual : ValueMember graph strengthened.typeRef [] (.arr values) := by
                  apply present_has_value_member graph strengthened
                  simpa only [here] using accepted
                have parts := array_member_parts graph strengthened.typeRef node spec lookup shape values actual
                omega
              · exact indexAssumption_current graph.profile source traversed index values here
                  (guarded _ declared)
            let next : SlotContract := {
              typeRef := spec.item.typeRef
              required := strengthened.required && present
              nullable := true }
            have nextMember := indexProjection_member_sound graph (projectedValue graph.profile source traversed)
              strengthened node spec lookup shape accepted index present bounded
            have nextAccepted : SlotMember graph next (projectedValue graph.profile source (traversed ++ [.index index])) := by
              rw [← projectedValue_append]
              exact nextMember
            have nextComputed : projectContract graph assumptions fuel next
                (traversed ++ [.index index]) rest = .ok destination := by
              simpa [projectContract, hs, lookup, shape, next, present] using computed
            simpa [List.append_assoc] using ih next _ rest destination nextComputed nextAccepted
        | taggedUnion spec =>
          cases step with
          | field name => simp [projectContract, hs, lookup, shape] at computed
          | index index => simp [projectContract, hs, lookup, shape] at computed
          | variant tag =>
            have declared : ProjectionAssumption.variant traversed tag ∈ assumptions := by
              by_cases present : ProjectionAssumption.variant traversed tag ∈ assumptions
              · exact present
              · exfalso
                simp [projectContract, hs, lookup, shape, present] at computed <;> cases computed
            cases selected : spec.branches.find? (fun branch => branch.wireTag == tag) with
            | none => simp [projectContract, hs, lookup, shape, declared, selected] at computed
            | some branch =>
              cases profileTag : graph.profile.tag with
              | none =>
                simp [projectContract, hs, lookup, shape, declared, selected, profileTag,
                  Bind.bind, Except.bind, throw, throwThe, MonadExceptOf.throw] at computed
              | some tagModel =>
                cases projectable :
                    projectableTagBranch spec.branches tag with
                | none =>
                  simp [projectContract, hs, lookup, shape, declared, selected,
                    profileTag, projectable] at computed
                | some projected =>
                  by_cases same : projected = branch
                  · subst projected
                    obtain ⟨entries, here, discriminator⟩ :=
                      variantAssumption_current graph.profile source traversed tag
                        (guarded _ declared)
                    have tagMember :
                        memberValue tagModel.key entries = some (.str tag) := by
                      simp [tagMatches, profileTag] at discriminator
                      cases member : memberValue tagModel.key entries with
                      | none => simp [member] at discriminator
                      | some actual =>
                        cases actual <;> simp [member] at discriminator
                        rename_i actualTag
                        subst actualTag
                        rfl
                    have branchSelected :
                        selectUnionBranch graph.profile spec (.obj entries) = some branch :=
                      projectableTagBranch_selects graph.profile spec.branches tagModel tag
                        entries profileTag tagMember branch projectable
                    have actual : ValueMember graph strengthened.typeRef [] (.obj entries) := by
                      apply present_has_value_member graph strengthened
                      simpa only [here] using accepted
                    have target := union_member_selected graph strengthened.typeRef node spec
                      lookup shape entries actual branch branchSelected
                    let next := { strengthened with typeRef := branch.target }
                    have nextAccepted : SlotMember graph next
                        (projectedValue graph.profile source (traversed ++ [.variant tag])) := by
                      rw [← projectedValue_append graph.profile, here]
                      simpa [projectedValue, valueAtPath, discriminator] using
                        SlotMember.present next (.obj entries) target
                    have nextComputed : projectContract graph assumptions fuel next
                        (traversed ++ [.variant tag]) rest = .ok destination := by
                      simpa [projectContract, hs, lookup, shape, declared, selected,
                        profileTag, projectable, next] using computed
                    simpa [List.append_assoc] using
                      ih next _ rest destination nextComputed nextAccepted
                  · simp [projectContract, hs, lookup, shape, declared, selected,
                      profileTag, projectable, same] at computed
        | boolean spec => simp [projectContract, hs, lookup, shape] at computed
        | integer spec => simp [projectContract, hs, lookup, shape] at computed
        | decimal spec => simp [projectContract, hs, lookup, shape] at computed
        | string spec => simp [projectContract, hs, lookup, shape] at computed
        | bytes spec => simp [projectContract, hs, lookup, shape] at computed
        | sealed tag refinements => simp [projectContract, hs, lookup, shape] at computed
        | never => simp [projectContract, hs, lookup, shape] at computed
        | unknown => simp [projectContract, hs, lookup, shape] at computed
        | unit => simp [projectContract, hs, lookup, shape] at computed
        | rawBody encoding => simp [projectContract, hs, lookup, shape] at computed
        | «opaque» name => simp [projectContract, hs, lookup, shape] at computed

private theorem checkedProjection_recomputes (graph : SemanticGraph)
    (certificate verified : ProjectionCertificate)
    (checked : checkProjectionCertificate graph certificate = .ok verified) :
    projectSlot graph certificate.source certificate.path certificate.assumptions = .ok certificate := by
  unfold checkProjectionCertificate at checked
  split at checked
  · simp [Bind.bind, Except.bind, throw, throwThe, MonadExceptOf.throw] at checked
  · cases computed : projectSlot graph certificate.source certificate.path certificate.assumptions with
    | error failure =>
      simp [computed, Bind.bind, Except.bind] at checked
    | ok actual =>
      by_cases same : actual = certificate
      · subst same
        rfl
      · simp [computed, same, Bind.bind, Except.bind, throw, throwThe, MonadExceptOf.throw] at checked

theorem projectionSlotsSound (graph : SemanticGraph) (certificate verified : ProjectionCertificate)
    (source : SlotValue) (checked : checkProjectionCertificate graph certificate = .ok verified)
    (accepted : Slots graph certificate.source source)
    (guarded : certificate.assumptions.all (slotAssumptionHolds graph.profile source) = true) :
    Slots graph certificate.destination (projectedValue graph.profile source certificate.path) := by
  have computed := checkedProjection_recomputes graph certificate verified checked
  obtain ⟨fuel, hfuel⟩ : ∃ fuel, fuel = (certificate.path.length + 1) * (graph.nodes.length + 1) := ⟨_, rfl⟩
  cases contract : projectContract graph certificate.assumptions fuel certificate.source [] certificate.path with
  | error failure =>
    simp [projectSlot, ← hfuel, contract, show meaningObligations graph [certificate.source.typeRef] = [] from accepted.1,
      Bind.bind, Except.bind] at computed
  | ok destination =>
    have targetDefined : MeaningDefined graph destination.typeRef := by
      unfold MeaningDefined
      cases obligations : meaningObligations graph [destination.typeRef] with
      | nil => rfl
      | cons obligation rest =>
        simp [projectSlot, ← hfuel, contract, obligations,
          show meaningObligations graph [certificate.source.typeRef] = [] from accepted.1,
          Bind.bind, Except.bind] at computed
    have equal : destination = certificate.destination := by
      let expected : ProjectionCertificate := {
        profile := graph.profile.reference
        sourceRefs := graph.sourceRefs
        source := certificate.source
        path := certificate.path
        assumptions := certificate.assumptions
        destination := destination
      }
      have identity : expected = certificate := by
        have reduced := computed
        simp [projectSlot, ← hfuel, contract,
          show meaningObligations graph [certificate.source.typeRef] = [] from accepted.1,
          show meaningObligations graph [destination.typeRef] = [] from targetDefined,
          Bind.bind, Except.bind, Pure.pure, Except.pure] at reduced
        exact reduced
      exact congrArg ProjectionCertificate.destination identity
    subst destination
    refine ⟨targetDefined, ?_⟩
    have guards : ∀ assumption ∈ certificate.assumptions, slotAssumptionHolds graph.profile source assumption = true :=
      List.all_eq_true.mp guarded
    have sourceMember : SlotMember graph certificate.source (projectedValue graph.profile source []) := by
      cases source <;> simpa [projectedValue, valueAtPath] using accepted.2
    simpa using projectContract_member_sound graph certificate.assumptions source guards fuel
      certificate.source [] certificate.path certificate.destination contract sourceMember

private theorem graphemeOffsetsLower (rules : GraphemeRules) (state : GraphemeState)
    (offset : Nat) (chars : List Char) :
    ∀ position ∈ graphemeBoundaryOffsets rules state offset chars, offset ≤ position := by
  induction chars generalizing state offset with
  | nil => simp [graphemeBoundaryOffsets]
  | cons c cs ih =>
    simp only [graphemeBoundaryOffsets]
    split
    · intro position member
      rcases List.mem_cons.mp member with h | h
      · omega
      · have bound := ih (graphemeStep rules state c) (offset + 1) position h
        omega
    · intro position member
      have bound := ih (graphemeStep rules state c) (offset + 1) position member
      omega

private theorem graphemeOffsetsEnd (rules : GraphemeRules) (state : GraphemeState)
    (offset : Nat) (chars : List Char) :
    offset + chars.length ∈ graphemeBoundaryOffsets rules state offset chars := by
  induction chars generalizing state offset with
  | nil => simp [graphemeBoundaryOffsets]
  | cons c cs ih =>
    have endMember := ih (graphemeStep rules state c) (offset + 1)
    simp only [graphemeBoundaryOffsets]
    split <;> simpa [List.mem_cons, Nat.add_assoc, Nat.add_comm, Nat.add_left_comm] using
      (show offset + 1 + cs.length ∈ graphemeBoundaryOffsets rules (graphemeStep rules state c)
        (offset + 1) cs from endMember)

private theorem graphemeOffsetsIncreasing (rules : GraphemeRules) (state : GraphemeState)
    (offset : Nat) (chars : List Char) :
    (graphemeBoundaryOffsets rules state offset chars).Pairwise (· < ·) := by
  induction chars generalizing state offset with
  | nil => simp [graphemeBoundaryOffsets]
  | cons c cs ih =>
    simp only [graphemeBoundaryOffsets]
    split
    · apply List.pairwise_cons.mpr
      refine ⟨?_, ih _ _⟩
      intro position member
      have bound := graphemeOffsetsLower rules (graphemeStep rules state c) (offset + 1) cs position member
      omega
    · exact ih _ _

private theorem graphemeOffsetsCount (rules : GraphemeRules) (state : GraphemeState)
    (offset : Nat) (chars : List Char) :
    (graphemeBoundaryOffsets rules state offset chars).length + state.count =
      (chars.foldl (graphemeStep rules) state).count + 1 := by
  induction chars generalizing state offset with
  | nil => simp [graphemeBoundaryOffsets, Nat.add_comm]
  | cons c cs ih =>
    have tailCount := ih (graphemeStep rules state c) (offset + 1)
    have nextCount : (graphemeStep rules state c).count = state.count +
        if graphemeBreak state (graphemeProperty rules c) (indicProperty rules c) (pictographic rules c)
          then 1 else 0 := rfl
    cases broken : graphemeBreak state (graphemeProperty rules c) (indicProperty rules c) (pictographic rules c)
    · simp only [broken, Bool.false_eq_true, ite_false, Nat.add_zero] at nextCount
      simp [graphemeBoundaryOffsets, nextCount, List.foldl_cons]
      omega
    · simp only [broken, ite_true] at nextCount
      simp [graphemeBoundaryOffsets, nextCount, List.foldl_cons]
      omega

theorem sealedFieldFailureRejects (graph : SemanticGraph) (ref : TypeRef)
    (path : ValuePath) (node : TypeNode) (tag : String)
    (refinements : List SealedRefinement) (members : List (String × JsonValue))
    (form : SealedForm) (key : String) (condition : ValueCondition)
    (observed : JsonValue)
    (shape : node.shape = .sealed tag refinements)
    (membersValid : objectMemberFailure graph.profile members = none)
    (classified : classOf graph.profile members = .sealed form)
    (tagMatches : form.tag = tag)
    (failed : sealedFieldsFailure graph.profile form members =
      some (key, condition, observed)) :
    expandNode graph ref path (.obj members) (some node) =
      .rejected (failureAt ref (path ++ [.field key]) (.present observed) condition) := by
  simp [expandNode, shape, membersValid, classified, tagMatches, failed]

theorem sealedValuePreserved (graph : SemanticGraph) (ref : TypeRef)
    (path : ValuePath) (node : TypeNode) (tag : String)
    (refinements : List SealedRefinement) (members : List (String × JsonValue))
    (form : SealedForm)
    (shape : node.shape = .sealed tag refinements)
    (membersValid : objectMemberFailure graph.profile members = none)
    (classified : classOf graph.profile members = .sealed form)
    (tagMatches : form.tag = tag)
    (fieldsValid : sealedFieldsFailure graph.profile form members = none)
    (refinementsValid :
      sealedRefinementFailure graph.profile members refinements = none) :
    expandNode graph ref path (.obj members) (some node) = .requirements [] := by
  simp [expandNode, shape, membersValid, classified, tagMatches, fieldsValid,
    refinementsValid]

theorem sealedStringFormatFailureRejects (graph : SemanticGraph) (ref : TypeRef)
    (path : ValuePath) (node : TypeNode) (tag : String)
    (refinements : List SealedRefinement) (members : List (String × JsonValue))
    (form : SealedForm) (key format text : String)
    (shape : node.shape = .sealed tag refinements)
    (membersValid : objectMemberFailure graph.profile members = none)
    (classified : classOf graph.profile members = .sealed form)
    (tagMatches : form.tag = tag)
    (fieldsValid : sealedFieldsFailure graph.profile form members = none)
    (failed : sealedRefinementFailure graph.profile members refinements =
      some (key, .format format, .str text)) :
    expandNode graph ref path (.obj members) (some node) =
      .rejected (failureAt ref (path ++ [.field key]) (.present (.str text))
        (.format format)) := by
  simp [expandNode, shape, membersValid, classified, tagMatches, fieldsValid, failed]

theorem sealedIntegerMaximumFailureRejects (graph : SemanticGraph) (ref : TypeRef)
    (path : ValuePath) (node : TypeNode) (tag : String)
    (refinements : List SealedRefinement) (members : List (String × JsonValue))
    (form : SealedForm) (key : String) (integer : Int)
    (shape : node.shape = .sealed tag refinements)
    (membersValid : objectMemberFailure graph.profile members = none)
    (classified : classOf graph.profile members = .sealed form)
    (tagMatches : form.tag = tag)
    (fieldsValid : sealedFieldsFailure graph.profile form members = none)
    (failed : sealedRefinementFailure graph.profile members refinements =
      some (key, .aboveMaximum, .num integer)) :
    expandNode graph ref path (.obj members) (some node) =
      .rejected (failureAt ref (path ++ [.field key]) (.present (.num integer))
        .aboveMaximum) := by
  simp [expandNode, shape, membersValid, classified, tagMatches, fieldsValid, failed]

/-- Empty strings have no grapheme boundaries (Unicode UAX #29 GB1 and GB2). -/
theorem graphemeBoundariesEmpty (rules : GraphemeRules) :
    graphemeBoundaries rules "" = [] := rfl

/-- Nonempty strings begin at zero, end at the scalar count, and have strictly increasing
boundaries (Unicode UAX #29 GB1 and GB2). -/
theorem graphemeBoundariesInvariant (rules : GraphemeRules) (text : String)
    (nonempty : text.toList ≠ []) :
    0 ∈ graphemeBoundaries rules text ∧ text.toList.length ∈ graphemeBoundaries rules text ∧
      (graphemeBoundaries rules text).Pairwise (· < ·) := by
  cases chars : text.toList with
  | nil => exact False.elim (nonempty chars)
  | cons c cs =>
    have start : 0 ∈ graphemeBoundaryOffsets rules {} 0 (c :: cs) := by
      simp [graphemeBoundaryOffsets, graphemeStep, graphemeBreak]
    exact ⟨by simpa [graphemeBoundaries, chars] using start,
      by simpa [graphemeBoundaries, chars] using graphemeOffsetsEnd rules {} 0 (c :: cs),
      by simpa [graphemeBoundaries, chars] using graphemeOffsetsIncreasing rules {} 0 (c :: cs)⟩

/-- The allocation-free cluster count equals the number of boundary intervals
(Unicode UAX #29). -/
theorem graphemeLengthFromBoundaries (rules : GraphemeRules) (text : String) :
    graphemeLength rules text = (graphemeBoundaries rules text).length - 1 := by
  cases chars : text.toList with
  | nil => simp [graphemeLength, String.foldl_eq_foldl_toList, chars, graphemeBoundaries]
  | cons c cs =>
    have count := graphemeOffsetsCount rules {} 0 (c :: cs)
    simp only [Nat.add_zero] at count
    simp only [graphemeLength, String.foldl_eq_foldl_toList, chars, graphemeBoundaries]
    omega


private theorem formatSpanSubstring_toList (context : FormatSpanContext) (start finish : Nat) :
    formatSpanSubstring context start finish =
      String.ofList ((context.chars.toList.drop start).take (finish - start)) := by
  simp [formatSpanSubstring, Array.toList_extract]

private theorem formatSpanSubstring_append (context : FormatSpanContext)
    (start split finish : Nat)
    (start_le : start ≤ split) (split_le : split ≤ finish)
    (finish_le : finish ≤ context.chars.size) :
    formatSpanSubstring context start finish =
      formatSpanSubstring context start split ++ formatSpanSubstring context split finish := by
  rw [formatSpanSubstring_toList, formatSpanSubstring_toList, formatSpanSubstring_toList]
  have lengths : finish - start = (split - start) + (finish - split) := by omega
  rw [lengths, List.take_add]
  have split_offset : start + (split - start) = split := by omega
  rw [← split_offset, List.drop_drop]
  simp [String.ofList_append]
private theorem formatSpanSubstring_split_exists (context : FormatSpanContext)
    (start finish : Nat) (start_le : start ≤ finish)
    (finish_le : finish ≤ context.chars.size) (left right : String)
    (joined : formatSpanSubstring context start finish = left ++ right) :
    ∃ split, start ≤ split ∧ split ≤ finish ∧
      left = formatSpanSubstring context start split ∧
      right = formatSpanSubstring context split finish := by
  rw [formatSpanSubstring_toList] at joined
  have charsJoined : (context.chars.toList.drop start).take (finish - start) =
      left.toList ++ right.toList := by
    have := congrArg String.toList joined
    simpa using this
  have charsLength : ((context.chars.toList.drop start).take (finish - start)).length =
      finish - start := by
    simp [List.length_take, List.length_drop]
    omega
  have partsLength : left.toList.length + right.toList.length = finish - start := by
    rw [charsJoined] at charsLength
    simp only [List.length_append] at charsLength
    omega
  let split := start + left.toList.length
  have splitLower : start ≤ split := by simp [split]
  have splitUpper : split ≤ finish := by
    dsimp [split]
    omega
  have splitStart : split - start = left.toList.length := by
    dsimp [split]
    omega
  have splitFinish : finish - split = right.toList.length := by
    dsimp [split]
    omega
  refine ⟨split, splitLower, splitUpper, ?_, ?_⟩
  · apply String.toList_inj.mp
    rw [formatSpanSubstring_toList, splitStart]
    have leftLengthLe : left.toList.length ≤ finish - start := by omega
    have first := congrArg (List.take left.toList.length) charsJoined
    rw [List.take_take, Nat.min_eq_left leftLengthLe] at first
    rw [List.take_append_of_le_length (by simp)] at first
    simpa using first.symm
  · apply String.toList_inj.mp
    rw [formatSpanSubstring_toList, splitFinish]
    have splitDrop : context.chars.toList.drop split =
        (context.chars.toList.drop start).drop left.toList.length := by
      dsimp [split]
      rw [List.drop_drop]
    rw [splitDrop]
    have second := congrArg (List.drop left.toList.length) charsJoined
    rw [List.drop_take, List.drop_append_length] at second
    rw [show finish - start - left.toList.length = right.toList.length by omega] at second
    simpa only [String.toList_ofList] using second.symm

private theorem formatAccepts_sequence_span (context : FormatSpanContext)
    (start finish : Nat) (start_le : start ≤ finish)
    (finish_le : finish ≤ context.chars.size) (rule : FormatRule)
    (rules : List FormatRule) :
    formatAccepts (.sequence (rule :: rules)) (formatSpanSubstring context start finish) = true ↔
      ∃ split, start ≤ split ∧ split ≤ finish ∧
        formatAccepts rule (formatSpanSubstring context start split) = true ∧
        formatAccepts (.sequence rules) (formatSpanSubstring context split finish) = true := by
  rw [formatAccepts_sequence_cons]
  constructor
  · rintro ⟨left, right, joined, acceptedLeft, acceptedRight⟩
    obtain ⟨split, lower, upper, leftEq, rightEq⟩ :=
      formatSpanSubstring_split_exists context start finish start_le finish_le left right joined
    exact ⟨split, lower, upper, by simpa [leftEq] using acceptedLeft,
      by simpa [rightEq] using acceptedRight⟩
  · rintro ⟨split, lower, upper, acceptedLeft, acceptedRight⟩
    refine ⟨formatSpanSubstring context start split,
      formatSpanSubstring context split finish, ?_, acceptedLeft, acceptedRight⟩
    exact formatSpanSubstring_append context start split finish lower upper finish_le
private theorem formatSpanSequenceAny_iff (context : FormatSpanContext)
    (start finish : Nat) (start_le : start ≤ finish)
    (finish_le : finish ≤ context.chars.size) (rule : FormatRule)
    (rules : List FormatRule) :
    (formatSpanSplitPoints start finish).any (fun split =>
      formatAccepts rule (formatSpanSubstring context start split) &&
        formatAccepts (.sequence rules) (formatSpanSubstring context split finish)) = true ↔
      formatAccepts (.sequence (rule :: rules))
        (formatSpanSubstring context start finish) = true := by
  rw [formatSpanSplitPoints_any start finish _ start_le]
  rw [formatAccepts_sequence_span context start finish start_le finish_le rule rules]
  simp only [Bool.and_eq_true]



private def memoOracle_consistent
    (oracle : (Nat × Nat × Nat × UInt64) → String → Bool) (memo : FormatSpanMemo) : Prop :=
  ∀ key source value, (source, value) ∈ memo.getD key [] → value = oracle key source

private theorem memoOracle_empty
    (oracle : (Nat × Nat × Nat × UInt64) → String → Bool) :
    memoOracle_consistent oracle ({} : FormatSpanMemo) := by
  intro key source value member
  simp at member

private theorem memoOracle_find
    (oracle : (Nat × Nat × Nat × UInt64) → String → Bool)
    (memo : FormatSpanMemo) (key : Nat × Nat × Nat × UInt64)
    (wanted source : String) (value : Bool)
    (consistent : memoOracle_consistent oracle memo)
    (found : ((memo.getD key []).find? (fun (entry : String × Bool) =>
      entry.1 == wanted)) = some (source, value)) :
    value = oracle key wanted := by
  have member := List.mem_of_find?_eq_some found
  have selected := List.find?_some found
  have same : source = wanted := by simpa using selected
  rw [← same]
  exact consistent key source value member

private theorem memoOracle_insert
    (oracle : (Nat × Nat × Nat × UInt64) → String → Bool)
    (memo : FormatSpanMemo) (key : Nat × Nat × Nat × UInt64)
    (source : String) (accepted : Bool) (bucket : List (String × Bool))
    (consistent : memoOracle_consistent oracle memo)
    (bucketConsistent : ∀ source value, (source, value) ∈ bucket →
      value = oracle key source)
    (acceptedConsistent : accepted = oracle key source) :
    memoOracle_consistent oracle (memo.insert key ((source, accepted) :: bucket)) := by
  intro query entrySource value member
  by_cases same : query = key
  · subst query
    rw [Std.HashMap.getD_insert_self] at member
    rcases List.mem_cons.mp member with first | rest
    · cases first
      exact acceptedConsistent
    · exact bucketConsistent entrySource value rest
  · rw [Std.HashMap.getD_insert] at member
    have different : key ≠ query := fun equal => same equal.symm
    simp [different] at member
    exact consistent query entrySource value member
private theorem memoOracle_sequenceAndRun_sound
    (oracle : (Nat × Nat × Nat × UInt64) → String → Bool)
    (expectedLeft expectedRight : Bool)
    (left right : FormatSpanMemo → Bool × FormatSpanMemo)
    (leftSound : ∀ memo, memoOracle_consistent oracle memo →
      (left memo).1 = expectedLeft ∧ memoOracle_consistent oracle (left memo).2)
    (rightSound : ∀ memo, memoOracle_consistent oracle memo →
      (right memo).1 = expectedRight ∧ memoOracle_consistent oracle (right memo).2) :
    ∀ memo, memoOracle_consistent oracle memo →
      let result := formatSpanAndRun left right memo
      result.1 = (expectedLeft && expectedRight) ∧
        memoOracle_consistent oracle result.2 := by
  intro memo consistent
  rcases leftResult : left memo with ⟨leftValue, leftMemo⟩
  have leftProof := leftSound memo consistent
  rw [leftResult] at leftProof
  rcases leftProof with ⟨leftCorrect, leftConsistent⟩
  by_cases acceptedLeft : expectedLeft = true
  · rcases rightResult : right leftMemo with ⟨rightValue, rightMemo⟩
    have rightProof := rightSound leftMemo leftConsistent
    rw [rightResult] at rightProof
    rcases rightProof with ⟨rightCorrect, rightConsistent⟩
    simp [formatSpanAndRun, leftResult, rightResult, leftCorrect, acceptedLeft,
      rightCorrect, rightConsistent]
  · simp [formatSpanAndRun, leftResult, leftCorrect, acceptedLeft, leftConsistent]

private theorem memoOracle_sequenceAnd_sound
    (oracle : (Nat × Nat × Nat × UInt64) → String → Bool)
    (expectedLeft expectedRight : Bool)
    (left right : StateM FormatSpanMemo Bool)
    (leftSound : ∀ memo, memoOracle_consistent oracle memo →
      let result := left.run memo
      result.1 = expectedLeft ∧ memoOracle_consistent oracle result.2)
    (rightSound : ∀ memo, memoOracle_consistent oracle memo →
      let result := right.run memo
      result.1 = expectedRight ∧ memoOracle_consistent oracle result.2) :
    ∀ memo, memoOracle_consistent oracle memo →
      let result := (formatSpanAnd left right).run memo
      result.1 = (expectedLeft && expectedRight) ∧
        memoOracle_consistent oracle result.2 := by
  intro memo consistent
  have result := memoOracle_sequenceAndRun_sound oracle expectedLeft expectedRight
    (fun state => left.run state) (fun state => right.run state)
    leftSound rightSound memo consistent
  simpa [formatSpanAnd, StateT.run, StateT.pure, Pure.pure] using result


private def memoOracle_shortCircuitResult {α} (target : Bool) (oracle : α → Bool) :
    List α → Bool
  | [] => !target
  | item :: rest =>
    if oracle item == target then target
    else memoOracle_shortCircuitResult target oracle rest

private theorem memoOracle_shortCircuitResult_eq_any_all {α}
    (target : Bool) (oracle : α → Bool) (items : List α) :
    memoOracle_shortCircuitResult target oracle items =
      if target then items.any oracle else items.all oracle := by
  cases target with
  | false =>
    induction items with
    | nil => simp [memoOracle_shortCircuitResult]
    | cons item rest ih => simp [memoOracle_shortCircuitResult, ih]
  | true =>
    induction items with
    | nil => simp [memoOracle_shortCircuitResult]
    | cons item rest ih => simp [memoOracle_shortCircuitResult, ih]

private theorem memoOracle_shortCircuitRun_sound {α}
    (oracle : (Nat × Nat × Nat × UInt64) → String → Bool)
    (expected : α → Bool) (target : Bool)
    (check : α → FormatSpanMemo → Bool × FormatSpanMemo)
    (items : List α) :
    (∀ item, item ∈ items → ∀ memo, memoOracle_consistent oracle memo →
      (check item memo).1 = expected item ∧
        memoOracle_consistent oracle (check item memo).2) →
    ∀ memo, memoOracle_consistent oracle memo →
      let result := formatSpanShortCircuitRun target check items memo
      result.1 = memoOracle_shortCircuitResult target expected items ∧
        memoOracle_consistent oracle result.2 := by
  induction items with
  | nil =>
    intro checkSound memo consistent
    simp [formatSpanShortCircuitRun, memoOracle_shortCircuitResult]
    exact consistent
  | cons item rest ih =>
    intro checkSound memo consistent
    rcases child : check item memo with ⟨accepted, nextMemo⟩
    have childSound := checkSound item List.mem_cons_self memo consistent
    rw [child] at childSound
    rcases childSound with ⟨acceptedCorrect, memoCorrect⟩
    have acceptedEq : accepted = expected item := by simpa using acceptedCorrect
    by_cases expectedStops : expected item = target
    · simp [formatSpanShortCircuitRun, child, expectedStops, acceptedEq,
        memoOracle_shortCircuitResult, memoCorrect]
    · have tailSound : ∀ element, element ∈ rest →
        ∀ tailMemo, memoOracle_consistent oracle tailMemo →
          (check element tailMemo).1 = expected element ∧
            memoOracle_consistent oracle (check element tailMemo).2 := by
        intro element member tailMemo tailConsistent
        exact checkSound element (List.mem_cons_of_mem item member) tailMemo tailConsistent
      have restSound := ih tailSound nextMemo memoCorrect
      simp [formatSpanShortCircuitRun, child, expectedStops, acceptedEq,
        memoOracle_shortCircuitResult, restSound]

private theorem memoOracle_shortCircuit_sound {α}
    (oracle : (Nat × Nat × Nat × UInt64) → String → Bool)
    (expected : α → Bool) (target : Bool)
    (check : α → StateM FormatSpanMemo Bool) (items : List α) :
    (∀ item, item ∈ items → ∀ memo, memoOracle_consistent oracle memo →
      let result := (check item).run memo
      result.1 = expected item ∧ memoOracle_consistent oracle result.2) →
    ∀ memo, memoOracle_consistent oracle memo →
      let result := (formatSpanShortCircuit target check items).run memo
      result.1 = (if target then items.any expected else items.all expected) ∧
        memoOracle_consistent oracle result.2 := by
  intro checkSound memo consistent
  have runSound := memoOracle_shortCircuitRun_sound oracle expected target
    (fun item state => (check item).run state) items
    (fun item member state stateConsistent =>
      checkSound item member state stateConsistent) memo consistent
  simpa [formatSpanShortCircuit, StateT.run, StateT.pure, Pure.pure,
    memoOracle_shortCircuitResult_eq_any_all] using runSound
private def formatSpanNodeDomain : FormatSpanNode → List FormatSpanNode
  | node@(.epsilon _) | node@(.literal _ _) | node@(.text _) | node@(.leaf _ _) => [node]
  | node@(.notN _ child) | node@(.optionalN _ child)
  | node@(.labelsN _ _ _ _ _ child) | node@(.boundedN _ _ _ child) =>
    node :: formatSpanNodeDomain child
  | node@(.choiceN _ children) =>
    node :: children.flatMap formatSpanNodeDomain
  | node@(.sequenceN _ left right) =>
    node :: formatSpanNodeDomain left ++ formatSpanNodeDomain right

private def formatSpanNodeChildren : FormatSpanNode → List FormatSpanNode
  | .notN _ child | .optionalN _ child | .labelsN _ _ _ _ _ child
  | .boundedN _ _ _ child => [child]
  | .choiceN _ children => children
  | .sequenceN _ left right => [left, right]
  | .epsilon _ | .literal _ _ | .text _ | .leaf _ _ => []

private def formatSpanContextValid (context : FormatSpanContext) : Prop :=
  context.chars = context.source.toList.toArray ∧
    context.sourceHash = String.hash context.source
private theorem formatSpanFoldSize_ge (nodes : List FormatSpanNode) (initial : Nat) :
    initial ≤ nodes.foldl (fun size node => size + node.size) initial := by
  induction nodes generalizing initial with
  | nil => simp
  | cons first rest ih =>
    simp only [List.foldl_cons]
    exact Nat.le_trans (Nat.le_add_right initial first.size) (ih (initial + first.size))

private theorem formatSpanNode_size_pos (node : FormatSpanNode) : 1 ≤ node.size := by
  cases node with
  | epsilon _ => simp [FormatSpanNode.size]
  | literal _ _ => simp [FormatSpanNode.size]
  | text _ => simp [FormatSpanNode.size]
  | leaf _ _ => simp [FormatSpanNode.size]
  | notN _ child => simp [FormatSpanNode.size]
  | optionalN _ child => simp [FormatSpanNode.size]
  | labelsN _ _ _ _ _ child => simp [FormatSpanNode.size]
  | boundedN _ _ _ child => simp [FormatSpanNode.size]
  | choiceN _ children =>
    simp only [FormatSpanNode.size]
    exact formatSpanFoldSize_ge children 1
  | sequenceN _ left right => simp [FormatSpanNode.size]


private theorem formatSpanFoldSize_mono (nodes : List FormatSpanNode) {small large : Nat}
    (ordered : small ≤ large) :
    nodes.foldl (fun size node => size + node.size) small ≤
      nodes.foldl (fun size node => size + node.size) large := by
  induction nodes generalizing small large with
  | nil => exact ordered
  | cons first rest ih =>
    simp only [List.foldl_cons]
    exact ih (Nat.add_le_add_right ordered first.size)

private theorem formatSpanFoldSize_mem_lt (nodes : List FormatSpanNode)
    (child : FormatSpanNode) (initial : Nat) (initial_positive : 1 ≤ initial)
    (member : child ∈ nodes) :
    child.size < nodes.foldl (fun size node => size + node.size) initial := by
  induction nodes generalizing child initial with
  | nil => simp at member
  | cons first rest ih =>
    simp only [List.mem_cons, List.foldl_cons] at member ⊢
    rcases member with same | member
    · cases same
      have enough := formatSpanFoldSize_ge rest (initial + first.size)
      omega
    · exact ih child (initial + first.size) (by omega) member

private theorem formatSpanNodeChild_size_lt (parent child : FormatSpanNode)
    (member : child ∈ formatSpanNodeChildren parent) : child.size < parent.size := by
  cases parent with
  | epsilon id => simp [formatSpanNodeChildren] at member
  | literal id value => simp [formatSpanNodeChildren] at member
  | text id => simp [formatSpanNodeChildren] at member
  | leaf id rule => simp [formatSpanNodeChildren] at member
  | notN id nested =>
    simp [formatSpanNodeChildren] at member
    subst child
    simp [FormatSpanNode.size]
  | optionalN id nested =>
    simp [formatSpanNodeChildren] at member
    subst child
    simp [FormatSpanNode.size]
  | labelsN id separator minimum maximum total nested =>
    simp [formatSpanNodeChildren] at member
    subst child
    simp [FormatSpanNode.size]
  | boundedN id unit maximum nested =>
    simp [formatSpanNodeChildren] at member
    subst child
    simp [FormatSpanNode.size]
  | choiceN id children =>
    have memberChildren : child ∈ children := by
      simpa [formatSpanNodeChildren] using member
    simpa [FormatSpanNode.size] using
      formatSpanFoldSize_mem_lt children child 1 (by omega) memberChildren
  | sequenceN id left right =>
    simp [formatSpanNodeChildren] at member
    rcases member with rfl | rfl
    · simp [FormatSpanNode.size]
      have rightPositive := formatSpanNode_size_pos right
      omega
    · simp [FormatSpanNode.size]
      have leftPositive := formatSpanNode_size_pos left
      omega

private theorem formatSpanNodeDomain_child_sublist (parent child : FormatSpanNode)
    (member : child ∈ formatSpanNodeChildren parent) :
    List.Sublist (formatSpanNodeDomain child) (formatSpanNodeDomain parent) := by
  cases parent with
  | epsilon id => simp [formatSpanNodeChildren] at member
  | literal id value => simp [formatSpanNodeChildren] at member
  | text id => simp [formatSpanNodeChildren] at member
  | leaf id rule => simp [formatSpanNodeChildren] at member
  | notN id nested =>
    simp [formatSpanNodeChildren] at member
    subst child
    simpa [formatSpanNodeDomain] using
      List.Sublist.cons (FormatSpanNode.notN id nested)
        (List.Sublist.refl (formatSpanNodeDomain nested))
  | optionalN id nested =>
    simp [formatSpanNodeChildren] at member
    subst child
    simpa [formatSpanNodeDomain] using
      List.Sublist.cons (FormatSpanNode.optionalN id nested)
        (List.Sublist.refl (formatSpanNodeDomain nested))
  | labelsN id separator minimum maximum total nested =>
    simp [formatSpanNodeChildren] at member
    subst child
    simpa [formatSpanNodeDomain] using
      List.Sublist.cons (FormatSpanNode.labelsN id separator minimum maximum total nested)
        (List.Sublist.refl (formatSpanNodeDomain nested))
  | boundedN id unit maximum nested =>
    simp [formatSpanNodeChildren] at member
    subst child
    simpa [formatSpanNodeDomain] using
      List.Sublist.cons (FormatSpanNode.boundedN id unit maximum nested)
        (List.Sublist.refl (formatSpanNodeDomain nested))
  | choiceN id children =>
    simp only [formatSpanNodeChildren] at member
    have nested : formatSpanNodeDomain child ∈ children.map formatSpanNodeDomain :=
      List.mem_map.mpr ⟨child, member, rfl⟩
    simpa only [formatSpanNodeDomain, List.flatMap_def] using
      List.Sublist.cons (FormatSpanNode.choiceN id children)
        (List.sublist_flatten_of_mem nested)
  | sequenceN id left right =>
    simp [formatSpanNodeChildren] at member
    rcases member with rfl | rfl
    · have inAppend : List.Sublist (formatSpanNodeDomain child)
          (formatSpanNodeDomain child ++ formatSpanNodeDomain right) :=
        List.sublist_append_of_sublist_left (List.Sublist.refl _)
      simpa [formatSpanNodeDomain] using
        List.Sublist.cons (FormatSpanNode.sequenceN id child right) inAppend
    · have inAppend : List.Sublist (formatSpanNodeDomain child)
          (formatSpanNodeDomain left ++ formatSpanNodeDomain child) :=
        List.sublist_append_of_sublist_right (List.Sublist.refl _)
      simpa [formatSpanNodeDomain] using
        List.Sublist.cons (FormatSpanNode.sequenceN id left child) inAppend

private theorem formatSpanContextOfString_valid (text : String) :
    formatSpanContextValid (formatSpanContextOfString text) := by
  simp [formatSpanContextValid, formatSpanContextOfString]

private theorem formatSpanSubstring_length (context : FormatSpanContext)
    (start finish : Nat) (contextValid : formatSpanContextValid context)
    (start_le : start ≤ finish) (finish_le : finish ≤ context.chars.size) :
    (formatSpanSubstring context start finish).length = finish - start := by
  rw [formatSpanSubstring_toList, String.length_ofList]
  simp [List.length_take, List.length_drop]
  omega

private theorem formatSpanSubstring_eq_empty (context : FormatSpanContext)
    (start finish : Nat) (contextValid : formatSpanContextValid context)
    (start_le : start ≤ finish) (finish_le : finish ≤ context.chars.size) :
    (formatSpanSubstring context start finish == "") = (start == finish) := by
  apply Bool.eq_iff_iff.mpr
  simp only [beq_iff_eq]
  constructor
  · intro empty
    have lengths := congrArg String.length empty
    rw [formatSpanSubstring_length context start finish contextValid start_le finish_le] at lengths
    simp at lengths
    omega
  · intro equal
    have same : start = finish := by simpa using equal
    subst finish
    simp [formatSpanSubstring]

private theorem formatSpanLiteral_sound (context : FormatSpanContext) (value : Array Char)
    (start finish : Nat) (contextValid : formatSpanContextValid context)
    (start_le : start ≤ finish) (finish_le : finish ≤ context.chars.size) :
    formatSpanLiteral context value start finish =
      decide (formatSpanSubstring context start finish = String.ofList value.toList) := by
  apply Bool.eq_iff_iff.mpr
  simp only [formatSpanLiteral, Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq,
    List.all_eq_true]
  constructor
  · rintro ⟨lengthEq, elements⟩
    apply String.toList_inj.mp
    rw [formatSpanSubstring_toList, String.toList_ofList]
    apply List.ext_getElem?
    intro index
    by_cases indexBound : index < value.size
    · have indexValue := elements index (by simpa using indexBound)
      simpa [List.getElem?_take, lengthEq, indexBound, List.getElem?_drop,
        contextValid.1, Array.getElem?_toList] using indexValue
    · have sliceLength :
          ((context.chars.toList.drop start).take (finish - start)).length = value.size := by
        simp [List.length_take, List.length_drop]
        omega
      have sliceBound :
          ¬ index < ((context.chars.toList.drop start).take (finish - start)).length := by
        omega
      simp [List.getElem?_eq_none (Nat.le_of_not_gt sliceBound),
        List.getElem?_eq_none (Nat.le_of_not_gt indexBound)]
  · intro equal
    have lengths := congrArg String.length equal
    rw [formatSpanSubstring_length context start finish contextValid start_le finish_le] at lengths
    simp at lengths
    have lengthEq : finish - start = value.size := by omega
    refine ⟨lengthEq, ?_⟩
    intro offset offsetMember
    have offsetBound : offset < value.size := by simpa using offsetMember
    have charsEqual := congrArg String.toList equal
    rw [formatSpanSubstring_toList, String.toList_ofList] at charsEqual
    have elementEqual := congrArg (fun items => items[offset]?) charsEqual
    simpa [List.getElem?_take, lengthEq, offsetBound, List.getElem?_drop,
      contextValid.1, Array.getElem?_toList] using elementEqual

private theorem formatSpanNodeDomain_child_ids_nodup (parent child : FormatSpanNode)
    (member : child ∈ formatSpanNodeChildren parent)
    (unique : ((formatSpanNodeDomain parent).map FormatSpanNode.id).Nodup) :
    ((formatSpanNodeDomain child).map FormatSpanNode.id).Nodup :=
  List.Nodup.sublist
    (List.Sublist.map FormatSpanNode.id (formatSpanNodeDomain_child_sublist parent child member))
    unique


private theorem formatSpanNode_mem_domain (node : FormatSpanNode) :
    node ∈ formatSpanNodeDomain node := by
  cases node <;> simp [formatSpanNodeDomain]

private theorem evalFormatSpan_oracle_sound
    (oracle : (Nat × Nat × Nat × UInt64) → String → Bool)
    (fuel : Nat) (context : FormatSpanContext) (node : FormatSpanNode)
    (start finish : Nat) (memo : FormatSpanMemo)
    (contextValid : formatSpanContextValid context)
    (bounds : start ≤ finish ∧ finish ≤ context.chars.size)
    (enough : node.size ≤ fuel)
    (oracleMatches : ∀ candidate ∈ formatSpanNodeDomain node,
      ∀ candidateContext : FormatSpanContext, formatSpanContextValid candidateContext →
      ∀ candidateStart candidateFinish,
        candidateStart ≤ candidateFinish →
        candidateFinish ≤ candidateContext.chars.size →
        oracle (candidate.id, candidateStart, candidateFinish, candidateContext.sourceHash)
            candidateContext.source =
          formatAccepts (formatSpanNodeRule candidate)
            (formatSpanSubstring candidateContext candidateStart candidateFinish))
    (consistent : memoOracle_consistent oracle memo) :
    let result := (evalFormatSpan fuel context node start finish).run memo
    result.1 =
        formatAccepts (formatSpanNodeRule node)
          (formatSpanSubstring context start finish) ∧
      memoOracle_consistent oracle result.2 := by
  induction fuel generalizing context node start finish memo with
  | zero =>
    have positive := formatSpanNode_size_pos node
    omega
  | succ fuel ih =>
    let key := (node.id, start, finish, context.sourceHash)
    let bucket := memo.getD key []
    have bucketConsistent : ∀ source value, (source, value) ∈ bucket →
        value = oracle key source := by
      intro source value member
      exact consistent key source value member
    have nodeOracle :
        oracle key context.source =
          formatAccepts (formatSpanNodeRule node)
            (formatSpanSubstring context start finish) := by
      exact oracleMatches node (formatSpanNode_mem_domain node) context contextValid
        start finish bounds.1 bounds.2
    have storeSound (nextMemo : FormatSpanMemo)
        (nextConsistent : memoOracle_consistent oracle nextMemo)
        (accepted : Bool)
        (correct : accepted =
          formatAccepts (formatSpanNodeRule node)
            (formatSpanSubstring context start finish)) :
        memoOracle_consistent oracle
          (nextMemo.insert key ((context.source, accepted) :: bucket)) := by
      apply memoOracle_insert oracle nextMemo key context.source accepted bucket
        nextConsistent bucketConsistent
      exact correct.trans nodeOracle.symm

    have insertSound (accepted : Bool)
        (correct : accepted =
          formatAccepts (formatSpanNodeRule node)
            (formatSpanSubstring context start finish)) :
        memoOracle_consistent oracle
          (memo.insert key ((context.source, accepted) :: bucket)) := by
      exact storeSound memo consistent accepted correct
    have childSound (child : FormatSpanNode)
        (member : child ∈ formatSpanNodeChildren node)
        (childContext : FormatSpanContext) (childStart childFinish : Nat)
        (childValid : formatSpanContextValid childContext)
        (childBounds : childStart ≤ childFinish ∧
          childFinish ≤ childContext.chars.size)
        (childMemo : FormatSpanMemo) (childConsistent : memoOracle_consistent oracle childMemo) :
        let result := (evalFormatSpan fuel childContext child childStart childFinish).run childMemo
        result.1 =
            formatAccepts (formatSpanNodeRule child)
              (formatSpanSubstring childContext childStart childFinish) ∧
          memoOracle_consistent oracle result.2 := by
      apply ih childContext child childStart childFinish childMemo childValid childBounds
      · have smaller := formatSpanNodeChild_size_lt node child member
        omega
      · intro candidate candidateMember
        apply oracleMatches candidate
        exact (formatSpanNodeDomain_child_sublist node child member).mem candidateMember
      · exact childConsistent
    simp only [evalFormatSpan]
    cases found :
        (memo.getD key []).find? (fun (source, _) => source == context.source) with
    | some entry =>
      rcases entry with ⟨source, accepted⟩
      have cached := memoOracle_find oracle memo key context.source source accepted
        consistent found
      simpa [key, found, cached, nodeOracle, StateT.run, StateT.pure, Pure.pure,
        StateT.bind, Bind.bind, MonadState.get, getThe, MonadStateOf.get, StateT.get]
    | none =>
      dsimp [key] at found
      cases node with
      | epsilon id =>
        have correct : (start == finish) =
            formatAccepts (formatSpanNodeRule (.epsilon id))
              (formatSpanSubstring context start finish) := by
          rw [formatSpanNodeMeaning_epsilon,
            formatSpanSubstring_eq_empty context start finish contextValid bounds.1 bounds.2]
        simpa [key, found, StateT.run, StateT.pure, Pure.pure, StateT.bind,
          Bind.bind, modify, modifyGet, MonadStateOf.modifyGet, StateT.modifyGet,
          MonadState.get, getThe, MonadStateOf.get, StateT.get] using
            And.intro correct (insertSound (start == finish) correct)
      | literal id value =>
        have correct := formatSpanLiteral_sound context value start finish
          contextValid bounds.1 bounds.2
        rw [← formatSpanNodeMeaning_literal id value
          (formatSpanSubstring context start finish)] at correct
        simpa [key, found, StateT.run, StateT.pure, Pure.pure, StateT.bind,
          Bind.bind, modify, modifyGet, MonadStateOf.modifyGet, StateT.modifyGet,
          MonadState.get, getThe, MonadStateOf.get, StateT.get] using
            And.intro correct (insertSound (formatSpanLiteral context value start finish) correct)
      | text id =>
        have correct : true =
            formatAccepts (formatSpanNodeRule (.text id))
              (formatSpanSubstring context start finish) :=
          (formatSpanNodeMeaning_text id _).symm
        simpa [key, found, StateT.run, StateT.pure, Pure.pure, StateT.bind,
          Bind.bind, modify, modifyGet, MonadStateOf.modifyGet, StateT.modifyGet,
          MonadState.get, getThe, MonadStateOf.get, StateT.get] using
            And.intro correct (insertSound true correct)
      | leaf id rule =>
        have correct : formatAccepts rule (formatSpanSubstring context start finish) =
            formatAccepts (formatSpanNodeRule (.leaf id rule))
              (formatSpanSubstring context start finish) :=
          (formatSpanNodeMeaning_leaf id rule _).symm
        simpa [key, found, StateT.run, StateT.pure, Pure.pure, StateT.bind,
          Bind.bind, modify, modifyGet, MonadStateOf.modifyGet, StateT.modifyGet,
          MonadState.get, getThe, MonadStateOf.get, StateT.get] using
            And.intro correct
              (insertSound (formatAccepts rule (formatSpanSubstring context start finish)) correct)
      | notN id child =>
        have sound := childSound child (by simp [formatSpanNodeChildren]) context start finish
          contextValid bounds memo consistent
        rcases childResult : (evalFormatSpan fuel context child start finish).run memo with
          ⟨accepted, nextMemo⟩
        rw [childResult] at sound
        have childDirect : evalFormatSpan fuel context child start finish memo =
            (accepted, nextMemo) := childResult
        simpa [key, found, childDirect, formatSpanNodeMeaning_not, Functor.map,
          StateT.map, StateT.run, StateT.bind, Bind.bind, MonadState.get, getThe,
          MonadStateOf.get, StateT.get, StateT.pure, Pure.pure] using
          And.intro (congrArg (fun value => !value) sound.1) sound.2
      | choiceN id children =>
        have checks : ∀ child, child ∈ children → ∀ state,
            memoOracle_consistent oracle state →
            let result := (evalFormatSpan fuel context child start finish).run state
            result.1 =
                formatAccepts (formatSpanNodeRule child)
                  (formatSpanSubstring context start finish) ∧
              memoOracle_consistent oracle result.2 := by
          intro child member state stateConsistent
          exact childSound child (by simpa [formatSpanNodeChildren] using member)
            context start finish contextValid bounds state stateConsistent
        have sound := memoOracle_shortCircuit_sound oracle
          (fun child => formatAccepts (formatSpanNodeRule child)
            (formatSpanSubstring context start finish))
          true (fun child => evalFormatSpan fuel context child start finish)
          children checks memo consistent
        rcases result :
            (formatSpanShortCircuit true
              (fun child => evalFormatSpan fuel context child start finish) children).run memo with
          ⟨accepted, nextMemo⟩
        rw [result] at sound
        have resultDirect : formatSpanShortCircuit true
            (fun child => evalFormatSpan fuel context child start finish) children memo =
          (accepted, nextMemo) := result
        have acceptedExpected : accepted =
            children.any (fun child => formatAccepts (formatSpanNodeRule child)
              (formatSpanSubstring context start finish)) := by
          simpa using sound.1
        have correct : accepted =
            formatAccepts (formatSpanNodeRule (.choiceN id children))
              (formatSpanSubstring context start finish) := by
          rw [acceptedExpected, formatSpanNodeMeaning_choice]
        have stored := storeSound nextMemo sound.2 accepted correct
        simpa [key, found, resultDirect, StateT.run, StateT.bind, Bind.bind, modify,
          modifyGet, MonadStateOf.modifyGet, StateT.modifyGet, StateT.pure, Pure.pure,
          MonadState.get, getThe, MonadStateOf.get, StateT.get] using
          And.intro correct stored
      | sequenceN id left right =>
        have splitChecks : ∀ split, split ∈ formatSpanSplitPoints start finish →
            ∀ state, memoOracle_consistent oracle state →
            let result :=
              (formatSpanAnd (evalFormatSpan fuel context left start split)
                (evalFormatSpan fuel context right split finish)).run state
            result.1 =
                (formatAccepts (formatSpanNodeRule left)
                    (formatSpanSubstring context start split) &&
                  formatAccepts (formatSpanNodeRule right)
                    (formatSpanSubstring context split finish)) ∧
              memoOracle_consistent oracle result.2 := by
          intro split member state stateConsistent
          have splitBounds := (formatSpanSplitPoints_mem start finish split bounds.1).mp member
          apply memoOracle_sequenceAnd_sound oracle
            (formatAccepts (formatSpanNodeRule left)
              (formatSpanSubstring context start split))
            (formatAccepts (formatSpanNodeRule right)
              (formatSpanSubstring context split finish))
          · intro childMemo childConsistent
            exact childSound left (by simp [formatSpanNodeChildren]) context start split
              contextValid ⟨splitBounds.1, Nat.le_trans splitBounds.2 bounds.2⟩
              childMemo childConsistent
          · intro childMemo childConsistent
            exact childSound right (by simp [formatSpanNodeChildren]) context split finish
              contextValid ⟨splitBounds.2, bounds.2⟩ childMemo childConsistent
          · exact stateConsistent
        have sound := memoOracle_shortCircuit_sound oracle
          (fun split =>
            formatAccepts (formatSpanNodeRule left)
                (formatSpanSubstring context start split) &&
              formatAccepts (formatSpanNodeRule right)
                (formatSpanSubstring context split finish))
          true
          (fun split => formatSpanAnd
            (evalFormatSpan fuel context left start split)
            (evalFormatSpan fuel context right split finish))
          (formatSpanSplitPoints start finish) splitChecks memo consistent
        rcases result :
            (formatSpanShortCircuit true
              (fun split => formatSpanAnd
                (evalFormatSpan fuel context left start split)
                (evalFormatSpan fuel context right split finish))
              (formatSpanSplitPoints start finish)).run memo with
          ⟨accepted, nextMemo⟩
        rw [result] at sound
        have resultDirect : formatSpanShortCircuit true
            (fun split => formatSpanAnd
              (evalFormatSpan fuel context left start split)
              (evalFormatSpan fuel context right split finish))
            (formatSpanSplitPoints start finish) memo =
          (accepted, nextMemo) := result
        have expectedCorrect :
            (formatSpanSplitPoints start finish).any (fun split =>
              formatAccepts (formatSpanNodeRule left)
                  (formatSpanSubstring context start split) &&
                formatAccepts (formatSpanNodeRule right)
                  (formatSpanSubstring context split finish)) =
              formatAccepts (formatSpanNodeRule (.sequenceN id left right))
                (formatSpanSubstring context start finish) := by
          apply Bool.eq_iff_iff.mpr
          simpa [formatSpanNodeRule, formatAccepts_sequence_singleton] using
            (formatSpanSequenceAny_iff context start finish bounds.1 bounds.2
              (formatSpanNodeRule left) [formatSpanNodeRule right])
        have correct := sound.1.trans expectedCorrect
        have stored := storeSound nextMemo sound.2 accepted correct
        simpa [key, found, resultDirect, StateT.run, StateT.bind, Bind.bind, modify,
          modifyGet, MonadStateOf.modifyGet, StateT.modifyGet, StateT.pure, Pure.pure,
          MonadState.get, getThe, MonadStateOf.get, StateT.get] using
          And.intro correct stored
      | optionalN id child =>
        by_cases empty : start = finish
        · have emptySubstring :
              (formatSpanSubstring context start finish == "") = true := by
            rw [formatSpanSubstring_eq_empty context start finish contextValid bounds.1 bounds.2]
            simp [empty]
          have foundEmpty := found
          rw [empty] at foundEmpty
          have correct : true =
              formatAccepts (formatSpanNodeRule (.optionalN id child))
                (formatSpanSubstring context start finish) := by
            rw [formatSpanNodeMeaning_optional, emptySubstring]
            simp
          simpa [key, bucket, foundEmpty, empty, StateT.run, StateT.bind, Bind.bind, modify,
            modifyGet, MonadStateOf.modifyGet, StateT.modifyGet, StateT.pure, Pure.pure,
            MonadState.get, getThe, MonadStateOf.get, StateT.get] using
            And.intro correct (storeSound memo consistent true correct)
        · have sound := childSound child (by simp [formatSpanNodeChildren]) context
            start finish contextValid bounds memo consistent
          rcases childResult :
              (evalFormatSpan fuel context child start finish).run memo with
            ⟨accepted, nextMemo⟩
          rw [childResult] at sound
          have childDirect : evalFormatSpan fuel context child start finish memo =
              (accepted, nextMemo) := childResult
          have nonempty :
              (formatSpanSubstring context start finish == "") = false := by
            rw [formatSpanSubstring_eq_empty context start finish contextValid bounds.1 bounds.2]
            simpa using empty
          have correct : accepted =
              formatAccepts (formatSpanNodeRule (.optionalN id child))
                (formatSpanSubstring context start finish) := by
            simpa [formatSpanNodeMeaning_optional, nonempty] using sound.1
          have stored := storeSound nextMemo sound.2 accepted correct
          simpa [key, found, empty, childDirect, StateT.run, StateT.bind, Bind.bind,
            modify, modifyGet, MonadStateOf.modifyGet, StateT.modifyGet,
            StateT.pure, Pure.pure, MonadState.get, getThe, MonadStateOf.get,
            StateT.get] using And.intro correct stored
      | labelsN id separator minimum maximum total child =>
        let text := formatSpanSubstring context start finish
        let separatorText := String.ofList separator.toList
        let pieces := labelParts separatorText text
        have textLength : text.length = finish - start :=
          formatSpanSubstring_length context start finish contextValid bounds.1 bounds.2
        have reject (impossible :
            ¬(separatorText ≠ "" ∧ minimum ≤ pieces.length ∧
              (∀ bound, maximum = some bound → pieces.length ≤ bound) ∧
              (∀ bound, total = some bound → text.length ≤ bound) ∧
              ∀ label ∈ pieces,
                formatAccepts (formatSpanNodeRule child) label = true)) :
            false =
              formatAccepts
                (formatSpanNodeRule (.labelsN id separator minimum maximum total child))
                text := by
          apply Eq.symm
          rw [Bool.eq_false_iff]
          intro accepted
          exact impossible ((formatSpanNodeMeaning_labels id separator minimum maximum
            total child text).mp accepted)
        have checks : ∀ piece, piece ∈ pieces → ∀ state,
            memoOracle_consistent oracle state →
            let result :=
              (evalFormatSpan fuel (formatSpanContextOfString piece) child 0 piece.length).run state
            result.1 = formatAccepts (formatSpanNodeRule child) piece ∧
              memoOracle_consistent oracle result.2 := by
          intro piece member state stateConsistent
          simpa [formatSpanContextOfString_full] using
            childSound child (by simp [formatSpanNodeChildren])
              (formatSpanContextOfString piece) 0 piece.length
              (formatSpanContextOfString_valid piece)
              (by simp [formatSpanContextOfString, ← String.length_toList])
              state stateConsistent
        have allSound := memoOracle_shortCircuit_sound oracle
          (fun piece => formatAccepts (formatSpanNodeRule child) piece)
          false
          (fun piece => evalFormatSpan fuel (formatSpanContextOfString piece) child 0 piece.length)
          pieces checks memo consistent
        rcases allResult :
            (formatSpanShortCircuit false
              (fun piece =>
                evalFormatSpan fuel (formatSpanContextOfString piece) child 0 piece.length)
              pieces).run memo with
          ⟨accepted, nextMemo⟩
        rw [allResult] at allSound
        have allDirect : formatSpanShortCircuit false
            (fun piece =>
              evalFormatSpan fuel (formatSpanContextOfString piece) child 0 piece.length)
            pieces memo = (accepted, nextMemo) := allResult
        have acceptedAll : accepted =
            pieces.all (fun piece => formatAccepts (formatSpanNodeRule child) piece) := by
          simpa using allSound.1
        by_cases separatorEmpty : separator = #[]
        · have correct := reject (by simp [separatorText, separatorEmpty])
          have foundSeparator := found
          rw [separatorEmpty] at foundSeparator
          simpa [key, foundSeparator, text, separatorText, pieces, separatorEmpty, StateT.run,
            StateT.pure, Pure.pure, StateT.bind, Bind.bind, MonadState.get, getThe,
            MonadStateOf.get, StateT.get] using And.intro correct consistent
        · have separatorNonempty : separatorText ≠ "" := by
            simp [separatorText, separatorEmpty]
          by_cases tooFew : pieces.length < minimum
          · have correct := reject (by simp [separatorNonempty]; omega)
            simpa [key, found, text, separatorText, pieces, separatorEmpty, tooFew,
              StateT.run, StateT.pure, Pure.pure, StateT.bind, Bind.bind,
              MonadState.get, getThe, MonadStateOf.get, StateT.get] using
              And.intro correct consistent
          · have minimumOk : minimum ≤ pieces.length := by omega
            cases maximum with
            | some maximumBound =>
              by_cases tooMany : maximumBound < pieces.length
              · have correct := reject (by
                  intro conditions
                  have maximumOk := conditions.2.2.1 maximumBound rfl
                  omega)
                simpa [key, found, text, separatorText, pieces, separatorEmpty, tooFew,
                  tooMany, StateT.run, StateT.pure, Pure.pure, StateT.bind, Bind.bind,
                  MonadState.get, getThe, MonadStateOf.get, StateT.get] using
                  And.intro correct consistent
              · have maximumOk : pieces.length ≤ maximumBound := by omega
                cases total with
                | some totalBound =>
                  by_cases tooLong : totalBound < finish - start
                  · have correct := reject (by
                      intro conditions
                      have totalOk := conditions.2.2.2.1 totalBound rfl
                      rw [textLength] at totalOk
                      omega)
                    simpa [key, found, text, separatorText, pieces, separatorEmpty,
                      tooFew, tooMany, tooLong, StateT.run, StateT.pure, Pure.pure,
                      StateT.bind, Bind.bind, MonadState.get, getThe, MonadStateOf.get,
                      StateT.get] using And.intro correct consistent
                  · have totalOk : text.length ≤ totalBound := by rw [textLength]; omega
                    have correct : accepted =
                        formatAccepts
                          (formatSpanNodeRule
                            (.labelsN id separator minimum (some maximumBound)
                              (some totalBound) child)) text := by
                      rw [acceptedAll]
                      apply Bool.eq_iff_iff.mpr
                      rw [formatSpanNodeMeaning_labels]
                      simp [pieces, separatorText, List.all_eq_true, separatorNonempty,
                        minimumOk, maximumOk, totalOk]
                    have stored := storeSound nextMemo allSound.2 accepted correct
                    simpa [key, found, text, separatorText, pieces, separatorEmpty,
                      tooFew, tooMany, tooLong, allDirect, StateT.run, StateT.bind,
                      Bind.bind, modify, modifyGet, MonadStateOf.modifyGet,
                      StateT.modifyGet, StateT.pure, Pure.pure, MonadState.get, getThe,
                      MonadStateOf.get, StateT.get] using And.intro correct stored
                | none =>
                  have correct : accepted =
                      formatAccepts
                        (formatSpanNodeRule
                          (.labelsN id separator minimum (some maximumBound) none child))
                        text := by
                    rw [acceptedAll]
                    apply Bool.eq_iff_iff.mpr
                    rw [formatSpanNodeMeaning_labels]
                    simp [pieces, separatorText, List.all_eq_true, separatorNonempty,
                      minimumOk, maximumOk]
                  have stored := storeSound nextMemo allSound.2 accepted correct
                  simpa [key, found, text, separatorText, pieces, separatorEmpty,
                    tooFew, tooMany, allDirect, StateT.run, StateT.bind, Bind.bind,
                    modify, modifyGet, MonadStateOf.modifyGet, StateT.modifyGet,
                    StateT.pure, Pure.pure, MonadState.get, getThe, MonadStateOf.get,
                    StateT.get] using And.intro correct stored
            | none =>
              cases total with
              | some totalBound =>
                by_cases tooLong : totalBound < finish - start
                · have correct := reject (by
                    intro conditions
                    have totalOk := conditions.2.2.2.1 totalBound rfl
                    rw [textLength] at totalOk
                    omega)
                  simpa [key, found, text, separatorText, pieces, separatorEmpty,
                    tooFew, tooLong, StateT.run, StateT.pure, Pure.pure, StateT.bind,
                    Bind.bind, MonadState.get, getThe, MonadStateOf.get, StateT.get] using
                    And.intro correct consistent
                · have totalOk : text.length ≤ totalBound := by rw [textLength]; omega
                  have correct : accepted =
                      formatAccepts
                        (formatSpanNodeRule
                          (.labelsN id separator minimum none (some totalBound) child))
                        text := by
                    rw [acceptedAll]
                    apply Bool.eq_iff_iff.mpr
                    rw [formatSpanNodeMeaning_labels]
                    simp [pieces, separatorText, List.all_eq_true, separatorNonempty,
                      minimumOk, totalOk]
                  have stored := storeSound nextMemo allSound.2 accepted correct
                  simpa [key, found, text, separatorText, pieces, separatorEmpty,
                    tooFew, tooLong, allDirect, StateT.run, StateT.bind, Bind.bind,
                    modify, modifyGet, MonadStateOf.modifyGet, StateT.modifyGet,
                    StateT.pure, Pure.pure, MonadState.get, getThe, MonadStateOf.get,
                    StateT.get] using And.intro correct stored
              | none =>
                have correct : accepted =
                    formatAccepts
                      (formatSpanNodeRule
                        (.labelsN id separator minimum none none child)) text := by
                  rw [acceptedAll]
                  apply Bool.eq_iff_iff.mpr
                  rw [formatSpanNodeMeaning_labels]
                  simp [pieces, separatorText, List.all_eq_true, separatorNonempty,
                    minimumOk]
                have stored := storeSound nextMemo allSound.2 accepted correct
                simpa [key, found, text, separatorText, pieces, separatorEmpty,
                  tooFew, allDirect, StateT.run, StateT.bind, Bind.bind, modify,
                  modifyGet, MonadStateOf.modifyGet, StateT.modifyGet, StateT.pure,
                  Pure.pure, MonadState.get, getThe, MonadStateOf.get, StateT.get] using
                  And.intro correct stored
      | boundedN id unit maximum child =>
        by_cases over : maximum <
            formatLength unit (formatSpanSubstring context start finish)
        · have correct : false =
              formatAccepts (formatSpanNodeRule (.boundedN id unit maximum child))
                (formatSpanSubstring context start finish) := by
            rw [formatSpanNodeMeaning_bounded]
            simp [show ¬ formatLength unit (formatSpanSubstring context start finish) ≤ maximum
              by omega]
          simpa [key, found, over, StateT.run, StateT.bind, Bind.bind, modify,
            modifyGet, MonadStateOf.modifyGet, StateT.modifyGet, StateT.pure, Pure.pure,
            MonadState.get, getThe, MonadStateOf.get, StateT.get] using
            And.intro correct (storeSound memo consistent false correct)
        · have sound := childSound child (by simp [formatSpanNodeChildren]) context
            start finish contextValid bounds memo consistent
          rcases childResult :
              (evalFormatSpan fuel context child start finish).run memo with
            ⟨accepted, nextMemo⟩
          rw [childResult] at sound
          have childDirect : evalFormatSpan fuel context child start finish memo =
              (accepted, nextMemo) := childResult
          have within :
              formatLength unit (formatSpanSubstring context start finish) ≤ maximum := by omega
          have correct : accepted =
              formatAccepts (formatSpanNodeRule (.boundedN id unit maximum child))
                (formatSpanSubstring context start finish) := by
            rw [formatSpanNodeMeaning_bounded]
            simp [within]
            exact sound.1
          have stored := storeSound nextMemo sound.2 accepted correct
          simpa [key, found, over, childDirect, StateT.run, StateT.bind, Bind.bind,
            modify, modifyGet, MonadStateOf.modifyGet, StateT.modifyGet,
            StateT.pure, Pure.pure, MonadState.get, getThe, MonadStateOf.get,
            StateT.get] using And.intro correct stored

private theorem freshFormatSpanId_allocation (initial : Nat) :
    (freshFormatSpanId).run initial = (initial, initial + 1) := by
  rfl

private theorem binaryFormatSequence_allocation (nodes : List FormatSpanNode)
    (initial : Nat) :
    ((binaryFormatSequence nodes).run initial).2 =
      initial + if nodes.isEmpty then 1 else nodes.length - 1 := by
  change (binaryFormatSequence nodes initial).2 =
    initial + if nodes.isEmpty then 1 else nodes.length - 1
  induction nodes generalizing initial with
  | nil => rfl
  | cons node nodes ih =>
    cases nodes with
    | nil => rfl
    | cons next rest =>
      generalize tailEq : binaryFormatSequence (next :: rest) initial = tailResult
      rcases tailResult with ⟨right, final⟩
      have finalEq := ih initial
      rw [tailEq] at finalEq
      simp at finalEq
      simp [binaryFormatSequence, StateT.bind, StateT.pure, Bind.bind, Pure.pure,
        freshFormatSpanId, MonadState.get, getThe, MonadStateOf.get,
        MonadStateOf.set, StateT.get, StateT.set, tailEq]
      omega

private theorem binaryFormatSequence_size (nodes : List FormatSpanNode)
    (initial : Nat) :
    ((binaryFormatSequence nodes).run initial).1.size =
      (nodes.map FormatSpanNode.size).sum +
        (if nodes.isEmpty then 1 else nodes.length - 1) := by
  change (binaryFormatSequence nodes initial).1.size =
    (nodes.map FormatSpanNode.size).sum +
      (if nodes.isEmpty then 1 else nodes.length - 1)
  induction nodes generalizing initial with
  | nil =>
    simp [binaryFormatSequence, freshFormatSpanId, StateT.bind, StateT.pure,
      Bind.bind, Pure.pure, MonadState.get, getThe, MonadStateOf.get,
      MonadStateOf.set, StateT.get, StateT.set, FormatSpanNode.size]
  | cons node nodes ih =>
    cases nodes with
    | nil =>
      simp [binaryFormatSequence, StateT.pure, Pure.pure]
    | cons next rest =>
      generalize tailEq : binaryFormatSequence (next :: rest) initial = tailResult
      rcases tailResult with ⟨right, final⟩
      have sizeEq := ih initial
      rw [tailEq] at sizeEq
      simp at sizeEq
      simp [binaryFormatSequence, StateT.bind, StateT.pure, Bind.bind, Pure.pure,
        freshFormatSpanId, MonadState.get, getThe, MonadStateOf.get,
        MonadStateOf.set, StateT.get, StateT.set, tailEq, FormatSpanNode.size]
      omega

private theorem mapMFormatSpan_allocation
    (compile : FormatRule → StateM Nat FormatSpanNode)
    (allocation : ∀ rule initial,
      (compile rule initial).2 = initial + (compile rule initial).1.size)
    (rules : List FormatRule) (initial : Nat) :
    (rules.mapM compile initial).2 =
      initial + ((rules.mapM compile initial).1.map FormatSpanNode.size).sum := by
  rw [← List.mapM'_eq_mapM]
  induction rules generalizing initial with
  | nil => rfl
  | cons rule rules ih =>
    generalize firstEq : compile rule initial = firstResult
    rcases firstResult with ⟨first, afterFirst⟩
    generalize restEq : rules.mapM' compile afterFirst = restResult
    rcases restResult with ⟨rest, final⟩
    have firstAllocation := allocation rule initial
    rw [firstEq] at firstAllocation
    have restAllocation := ih afterFirst
    rw [restEq] at restAllocation
    simp at firstAllocation restAllocation
    simp [List.mapM', StateT.bind, StateT.pure, Bind.bind, Pure.pure,
      firstEq, restEq]
    omega

private theorem foldlFormatSpanSize (nodes : List FormatSpanNode) (initial : Nat) :
    nodes.foldl (fun size child => size + child.size) initial =
      initial + (nodes.map FormatSpanNode.size).sum := by
  induction nodes generalizing initial with
  | nil => simp
  | cons node nodes ih =>
    simp only [List.foldl_cons, List.map_cons, List.sum_cons]
    rw [ih]
    omega

private theorem freshThenFormatSpan_allocation {α : Type}
    (child : StateM Nat α)
    (wrap : Nat → α → FormatSpanNode)
    (measure : α → Nat)
    (wrapSize : ∀ id value, (wrap id value).size = measure value + 1)
    (allocation : ∀ initial, (child initial).2 = initial + measure (child initial).1)
    (initial : Nat) :
    ((do
      let id ← freshFormatSpanId
      let node ← child
      pure (wrap id node)) initial).2 =
      initial + ((do
        let id ← freshFormatSpanId
        let node ← child
        pure (wrap id node)) initial).1.size := by
  generalize childEq : child (initial + 1) = childResult
  rcases childResult with ⟨node, final⟩
  have finalEq := allocation (initial + 1)
  rw [childEq] at finalEq
  simp at finalEq
  simp [freshFormatSpanId, StateT.bind, StateT.pure, Bind.bind, Pure.pure,
    MonadState.get, getThe, MonadStateOf.get, MonadStateOf.set,
    StateT.get, StateT.set, childEq, wrapSize]
  omega

private theorem compileFormatSpan_allocation (fuel : Nat) (rule : FormatRule)
    (initial : Nat) :
    ((compileFormatSpan fuel rule).run initial).2 =
      initial + ((compileFormatSpan fuel rule).run initial).1.size := by
  change (compileFormatSpan fuel rule initial).2 =
    initial + (compileFormatSpan fuel rule initial).1.size
  induction fuel generalizing rule initial with
  | zero =>
      simp [compileFormatSpan, freshFormatSpanId, StateT.bind, StateT.pure,
        Bind.bind, Pure.pure, MonadState.get, getThe, MonadStateOf.get,
        MonadStateOf.set, StateT.get, StateT.set, FormatSpanNode.size]
  | succ fuel ih =>
      cases rule with
      | literal value =>
        simp [compileFormatSpan, freshFormatSpanId, StateT.bind, StateT.pure,
          Bind.bind, Pure.pure, MonadState.get, getThe, MonadStateOf.get,
          MonadStateOf.set, StateT.get, StateT.set, FormatSpanNode.size]
      | sequence parts =>
        generalize mappedEq : parts.mapM (compileFormatSpan fuel) initial = mappedResult
        rcases mappedResult with ⟨nodes, afterMap⟩
        generalize binaryEq : binaryFormatSequence nodes afterMap = binaryResult
        rcases binaryResult with ⟨node, final⟩
        have mapAllocation :=
          mapMFormatSpan_allocation (compileFormatSpan fuel) ih parts initial
        rw [mappedEq] at mapAllocation
        have binaryAllocation := binaryFormatSequence_allocation nodes afterMap
        change (binaryFormatSequence nodes afterMap).2 =
          afterMap + (if nodes.isEmpty then 1 else nodes.length - 1) at binaryAllocation
        rw [binaryEq] at binaryAllocation
        have binarySize := binaryFormatSequence_size nodes afterMap
        change (binaryFormatSequence nodes afterMap).1.size =
          (nodes.map FormatSpanNode.size).sum +
            (if nodes.isEmpty then 1 else nodes.length - 1) at binarySize
        rw [binaryEq] at binarySize
        simp at mapAllocation binaryAllocation binarySize
        simp [compileFormatSpan, StateT.bind, Bind.bind, mappedEq, binaryEq]
        omega
      | optional child =>
        exact freshThenFormatSpan_allocation (compileFormatSpan fuel child)
          (fun id node => .optionalN id node) FormatSpanNode.size
          (by intro id node; simp [FormatSpanNode.size]) (ih child) initial
      | labels separator minimum maximum total child =>
        exact freshThenFormatSpan_allocation (compileFormatSpan fuel child)
          (fun id node => .labelsN id separator.toList.toArray minimum maximum total node)
          FormatSpanNode.size (by intro id node; simp [FormatSpanNode.size]) (ih child) initial
      | bounded unit maximum child =>
        exact freshThenFormatSpan_allocation (compileFormatSpan fuel child)
          (fun id node => .boundedN id unit maximum node) FormatSpanNode.size
          (by intro id node; simp [FormatSpanNode.size]) (ih child) initial
      | asciiDfa spec | identifier _ _ _ _ _ _ | timestamp _
      | absoluteUri _ | languageTag _ =>
        simp [compileFormatSpan, freshFormatSpanId, StateT.bind, StateT.pure,
          Bind.bind, Pure.pure, MonadState.get, getThe, MonadStateOf.get,
          MonadStateOf.set, StateT.get, StateT.set, FormatSpanNode.size]
      | choice rules =>
        exact freshThenFormatSpan_allocation (rules.mapM (compileFormatSpan fuel))
          (fun id nodes => .choiceN id nodes)
          (fun nodes => (nodes.map FormatSpanNode.size).sum)
          (by
            intro id nodes
            simp [FormatSpanNode.size, foldlFormatSpanSize]
            omega)
          (mapMFormatSpan_allocation (compileFormatSpan fuel) ih rules) initial
      | text =>
        simp [compileFormatSpan, freshFormatSpanId, StateT.bind, StateT.pure,
          Bind.bind, Pure.pure, MonadState.get, getThe, MonadStateOf.get,
          MonadStateOf.set, StateT.get, StateT.set, FormatSpanNode.size]
      | not child =>
        exact freshThenFormatSpan_allocation (compileFormatSpan fuel child)
          (fun id node => .notN id node) FormatSpanNode.size
          (by intro id node; simp [FormatSpanNode.size]) (ih child) initial

private def formatSpanNodeIds : FormatSpanNode → List Nat
  | .epsilon id | .literal id _ | .text id | .leaf id _ => [id]
  | .notN id child | .optionalN id child | .labelsN id _ _ _ _ child
  | .boundedN id _ _ child => id :: formatSpanNodeIds child
  | .choiceN id children =>
      id :: children.flatMap formatSpanNodeIds
  | .sequenceN id left right =>
      id :: formatSpanNodeIds left ++ formatSpanNodeIds right



private theorem mapMFormatSpanIds
    (build : α → StateM Nat FormatSpanNode)
    (valid : ∀ item initial,
      let result := build item initial
      (formatSpanNodeIds result.1).Nodup ∧
      (∀ id ∈ formatSpanNodeIds result.1, initial ≤ id ∧ id < result.2) ∧
      initial ≤ result.2)
    (items : List α) (initial : Nat) :
    let result := items.mapM build initial
    (result.1.flatMap formatSpanNodeIds).Nodup ∧
    (∀ id ∈ result.1.flatMap formatSpanNodeIds, initial ≤ id ∧ id < result.2) ∧
    initial ≤ result.2 := by
  rw [← List.mapM'_eq_mapM]
  induction items generalizing initial with
  | nil =>
      simp [List.mapM', StateT.pure, Pure.pure, StateT.bind, Bind.bind]
  | cons item items ih =>
      generalize firstEq : build item initial = firstResult
      rcases firstResult with ⟨first, afterFirst⟩
      generalize restEq : items.mapM' build afterFirst = restResult
      rcases restResult with ⟨rest, final⟩
      have firstValid := valid item initial
      rw [firstEq] at firstValid
      have restValid := ih afterFirst
      rw [restEq] at restValid
      simp only [Prod.fst, Prod.snd] at firstValid restValid
      rcases firstValid with ⟨firstNodup, firstRange, firstMonotone⟩
      rcases restValid with ⟨restNodup, restRange, restMonotone⟩
      simp [List.mapM', StateT.bind, StateT.pure, Bind.bind, Pure.pure,
        firstEq, restEq]
      constructor
      · apply List.nodup_append.mpr
        refine ⟨firstNodup, restNodup, ?_⟩
        intro x hx y hy equal
        have hi := firstRange x hx
        have lo := restRange y hy
        omega
      constructor
      · intro id member
        rcases member with idFirst | idRest
        · have hi := firstRange id idFirst
          exact ⟨by omega, by omega⟩
        · have bounds := restRange id (List.mem_flatMap.mpr idRest)
          exact ⟨by omega, bounds.2⟩
      · omega

private theorem freshThenFormatSpan_ids_valid {α : Type}
    (child : StateM Nat α)
    (ids : α → List Nat)
    (wrap : Nat → α → FormatSpanNode)
    (wrapIds : ∀ id value, formatSpanNodeIds (wrap id value) = id :: ids value)
    (valid : ∀ initial,
      let result := child initial
      (ids result.1).Nodup ∧
        (∀ id ∈ ids result.1, initial ≤ id ∧ id < result.2) ∧
        initial ≤ result.2)
    (initial : Nat) :
    let result := (do
      let id ← freshFormatSpanId
      let value ← child
      pure (wrap id value)) initial
    (formatSpanNodeIds result.1).Nodup ∧
      (∀ id ∈ formatSpanNodeIds result.1, initial ≤ id ∧ id < result.2) ∧
      initial ≤ result.2 := by
  generalize childEq : child (initial + 1) = childResult
  rcases childResult with ⟨value, final⟩
  have childValid := valid (initial + 1)
  rw [childEq] at childValid
  rcases childValid with ⟨childNodup, childRange, childMonotone⟩
  simp [freshFormatSpanId, StateT.bind, StateT.pure, Bind.bind, Pure.pure,
    MonadState.get, getThe, MonadStateOf.get, MonadStateOf.set,
    StateT.get, StateT.set, childEq, wrapIds]
  constructor
  · exact ⟨(by
      intro member
      have bounds := childRange initial member
      omega), childNodup⟩
  constructor
  · exact ⟨by omega, by
      intro id member
      have bounds := childRange id member
      omega⟩
  · omega

private theorem binaryFormatSequence_ids_valid_aux (nodes : List FormatSpanNode)
    (lower initial : Nat)
    (oldNodup : (nodes.flatMap formatSpanNodeIds).Nodup)
    (oldRange : ∀ id ∈ nodes.flatMap formatSpanNodeIds,
      lower ≤ id ∧ id < initial)
    (lowerLe : lower ≤ initial) :
    let result := binaryFormatSequence nodes initial
    ((formatSpanNodeIds result.1).Nodup ∧
      (∀ id ∈ formatSpanNodeIds result.1, lower ≤ id ∧ id < result.2) ∧
      initial ≤ result.2) ∧
      (∀ id ∈ formatSpanNodeIds result.1,
        id ∈ nodes.flatMap formatSpanNodeIds ∨ initial ≤ id) := by
  induction nodes generalizing initial with
  | nil =>
      simp [binaryFormatSequence, freshFormatSpanId, formatSpanNodeIds,
        StateT.bind, StateT.pure, Bind.bind, Pure.pure, MonadState.get,
        getThe, MonadStateOf.get, MonadStateOf.set, StateT.get, StateT.set]
      omega
  | cons node nodes ih =>
      cases nodes with
      | nil =>
          simp only [List.flatMap_cons, List.flatMap_nil, List.append_nil] at oldNodup oldRange
          simp only [binaryFormatSequence, StateT.pure, Pure.pure,
            List.flatMap_cons, List.flatMap_nil, List.append_nil]
          constructor
          · exact ⟨oldNodup, oldRange, Nat.le_refl _⟩
          · intro id member
            exact Or.inl member
      | cons next rest =>
          have oldParts := List.nodup_append.mp oldNodup
          rcases oldParts with ⟨nodeNodup, tailOldNodup, oldSeparate⟩
          have nodeRange : ∀ id ∈ formatSpanNodeIds node,
              lower ≤ id ∧ id < initial := by
            intro id member
            exact oldRange id (List.mem_append_left _ member)
          have tailOldRange : ∀ id ∈ (next :: rest).flatMap formatSpanNodeIds,
              lower ≤ id ∧ id < initial := by
            intro id member
            exact oldRange id (List.mem_append_right _ member)
          generalize tailEq :
            binaryFormatSequence (next :: rest) initial = tailResult
          rcases tailResult with ⟨right, final⟩
          have tailValid := ih initial tailOldNodup tailOldRange lowerLe
          rw [tailEq] at tailValid
          rcases tailValid with
            ⟨⟨tailIdsNodup, tailRange, tailMonotone⟩, tailProvenance⟩
          have nodeRightSeparate :
              ∀ x ∈ formatSpanNodeIds node,
                ∀ y ∈ formatSpanNodeIds right, x ≠ y := by
            intro x hx y hy equal
            rcases tailProvenance y hy with old | allocated
            · exact oldSeparate x hx y old equal
            · have bounds := nodeRange x hx
              omega
          have childrenNodup :
              (formatSpanNodeIds node ++ formatSpanNodeIds right).Nodup :=
            List.nodup_append.mpr ⟨nodeNodup, tailIdsNodup, nodeRightSeparate⟩
          have parentFresh :
              final ∉ formatSpanNodeIds node ++ formatSpanNodeIds right := by
            intro member
            rcases List.mem_append.mp member with inNode | inRight
            · have bounds := nodeRange final inNode
              omega
            · have bounds := tailRange final inRight
              omega
          simp only [binaryFormatSequence, StateT.bind, tailEq,
            freshFormatSpanId, MonadState.get, getThe, MonadStateOf.get,
            MonadStateOf.set, StateT.get, StateT.set, StateT.pure,
            Bind.bind, Pure.pure, formatSpanNodeIds]
          constructor
          · constructor
            · exact List.nodup_cons.mpr ⟨parentFresh, childrenNodup⟩
            constructor
            · intro candidate member
              rcases List.mem_cons.mp member with parent | inChildren
              · subst candidate
                omega
              · rcases List.mem_append.mp inChildren with inNode | inRight
                · have bounds := nodeRange candidate inNode
                  exact ⟨bounds.1, by omega⟩
                · have bounds := tailRange candidate inRight
                  exact ⟨bounds.1, by omega⟩
            · omega
          · intro candidate member
            rcases List.mem_cons.mp member with parent | inChildren
            · subst candidate
              exact Or.inr tailMonotone
            · rcases List.mem_append.mp inChildren with inNode | inRight
              · exact Or.inl (List.mem_append_left _ inNode)
              · rcases tailProvenance candidate inRight with old | allocated
                · exact Or.inl (List.mem_append_right _ old)
                · exact Or.inr allocated

private theorem binaryFormatSequence_ids_valid (nodes : List FormatSpanNode)
    (lower initial : Nat)
    (oldNodup : (nodes.flatMap formatSpanNodeIds).Nodup)
    (oldRange : ∀ id ∈ nodes.flatMap formatSpanNodeIds,
      lower ≤ id ∧ id < initial)
    (lowerLe : lower ≤ initial) :
    let result := binaryFormatSequence nodes initial
    (formatSpanNodeIds result.1).Nodup ∧
      (∀ id ∈ formatSpanNodeIds result.1, lower ≤ id ∧ id < result.2) ∧
      initial ≤ result.2 :=
  (binaryFormatSequence_ids_valid_aux nodes lower initial oldNodup oldRange lowerLe).1

private theorem compileFormatSpan_ids_valid (fuel : Nat) (rule : FormatRule)
    (initial : Nat) :
    let result := compileFormatSpan fuel rule initial
    (formatSpanNodeIds result.1).Nodup ∧
      (∀ id ∈ formatSpanNodeIds result.1, initial ≤ id ∧ id < result.2) ∧
      initial ≤ result.2 := by
  induction fuel generalizing rule initial with
  | zero =>
      simp [compileFormatSpan, freshFormatSpanId, formatSpanNodeIds,
        StateT.bind, StateT.pure, Bind.bind, Pure.pure,
        MonadState.get, getThe, MonadStateOf.get, MonadStateOf.set,
        StateT.get, StateT.set]
  | succ fuel ih =>
      cases rule with
      | sequence parts =>
          generalize mappedEq :
            parts.mapM (compileFormatSpan fuel) initial = mappedResult
          rcases mappedResult with ⟨nodes, afterMap⟩
          have mappedValid :=
            mapMFormatSpanIds (compileFormatSpan fuel) ih parts initial
          rw [mappedEq] at mappedValid
          rcases mappedValid with ⟨mappedNodup, mappedRange, mappedMonotone⟩
          have binaryValid := binaryFormatSequence_ids_valid nodes initial afterMap
            mappedNodup mappedRange mappedMonotone
          rcases binaryValid with ⟨binaryNodup, binaryRange, binaryMonotone⟩
          simpa [compileFormatSpan, StateT.bind, Bind.bind, mappedEq] using
            And.intro binaryNodup
              (And.intro binaryRange (by omega))
      | optional child =>
          exact freshThenFormatSpan_ids_valid (compileFormatSpan fuel child)
            formatSpanNodeIds (fun id node => .optionalN id node)
            (by intro id node; simp [formatSpanNodeIds]) (ih child) initial
      | labels separator minimum maximum total child =>
          exact freshThenFormatSpan_ids_valid (compileFormatSpan fuel child)
            formatSpanNodeIds
            (fun id node => .labelsN id separator.toList.toArray minimum maximum total node)
            (by intro id node; simp [formatSpanNodeIds]) (ih child) initial
      | bounded unit maximum child =>
          exact freshThenFormatSpan_ids_valid (compileFormatSpan fuel child)
            formatSpanNodeIds (fun id node => .boundedN id unit maximum node)
            (by intro id node; simp [formatSpanNodeIds]) (ih child) initial
      | choice rules =>
          exact freshThenFormatSpan_ids_valid
            (rules.mapM (compileFormatSpan fuel))
            (fun nodes => nodes.flatMap formatSpanNodeIds)
            (fun id nodes => .choiceN id nodes)
            (by intro id nodes; simp [formatSpanNodeIds])
            (mapMFormatSpanIds (compileFormatSpan fuel) ih rules) initial
      | not child =>
          exact freshThenFormatSpan_ids_valid (compileFormatSpan fuel child)
            formatSpanNodeIds (fun id node => .notN id node)
            (by intro id node; simp [formatSpanNodeIds]) (ih child) initial
      | literal value | asciiDfa _ | identifier _ _ _ _ _ _
      | timestamp _ | absoluteUri _ | languageTag _ | text =>
          simp [compileFormatSpan, freshFormatSpanId, formatSpanNodeIds,
            StateT.bind, StateT.pure, Bind.bind, Pure.pure,
            MonadState.get, getThe, MonadStateOf.get, MonadStateOf.set,
            StateT.get, StateT.set]

theorem compileFormatSpan_ids_unique (fuel : Nat) (rule : FormatRule)
    (initial : Nat) :
    (formatSpanNodeIds ((compileFormatSpan fuel rule).run initial).1).Nodup :=
  (compileFormatSpan_ids_valid fuel rule initial).1

theorem compileFormatSpan_ids_range (fuel : Nat) (rule : FormatRule)
    (initial id : Nat)
    (member :
      id ∈ formatSpanNodeIds ((compileFormatSpan fuel rule).run initial).1) :
    initial ≤ id ∧ id < ((compileFormatSpan fuel rule).run initial).2 :=
  (compileFormatSpan_ids_valid fuel rule initial).2.1 id member
private theorem formatSpanNodeDomain_ids (node : FormatSpanNode) :
    (formatSpanNodeDomain node).map FormatSpanNode.id = formatSpanNodeIds node := by
  cases node with
  | epsilon id | literal id value | text id | leaf id rule =>
    simp [formatSpanNodeDomain, formatSpanNodeIds, FormatSpanNode.id]
  | notN id child | optionalN id child
  | labelsN id separator minimum maximum total child
  | boundedN id unit maximum child =>
    simp [formatSpanNodeDomain, formatSpanNodeIds, FormatSpanNode.id,
      formatSpanNodeDomain_ids child]
  | choiceN id children =>
    have childEq : ∀ child ∈ children,
        (formatSpanNodeDomain child).map FormatSpanNode.id = formatSpanNodeIds child := by
      intro child member
      exact formatSpanNodeDomain_ids child
    have flatMapEq :
        children.flatMap (fun child =>
          (formatSpanNodeDomain child).map FormatSpanNode.id) =
        children.flatMap formatSpanNodeIds := by
      induction children with
      | nil => rfl
      | cons first rest ih =>
        simp only [List.flatMap_cons]
        rw [childEq first List.mem_cons_self]
        apply congrArg (List.append (formatSpanNodeIds first))
        apply ih
        intro child member
        exact childEq child (List.mem_cons_of_mem first member)
    simp [formatSpanNodeDomain, formatSpanNodeIds, FormatSpanNode.id,
      List.map_flatMap, flatMapEq]
  | sequenceN id left right =>
    simp [formatSpanNodeDomain, formatSpanNodeIds, FormatSpanNode.id,
      formatSpanNodeDomain_ids left, formatSpanNodeDomain_ids right]
termination_by node.size
decreasing_by
  all_goals
    apply formatSpanNodeChild_size_lt
    simp_all [formatSpanNodeChildren]

private theorem formatSpanFindId_eq_some (nodes : List FormatSpanNode)
    (candidate : FormatSpanNode)
    (unique : (nodes.map FormatSpanNode.id).Nodup)
    (member : candidate ∈ nodes) :
    nodes.find? (fun node => node.id == candidate.id) = some candidate := by
  induction nodes generalizing candidate with
  | nil => simp at member
  | cons first rest ih =>
    simp only [List.map_cons, List.nodup_cons] at unique
    simp only [List.mem_cons] at member
    rcases member with same | member
    · cases same
      simp
    · have different : first.id ≠ candidate.id := by
        intro equal
        apply unique.1
        exact List.mem_map.mpr ⟨candidate, member, equal.symm⟩
      have differentBool : (first.id == candidate.id) = false := by simp [different]
      simp [List.find?, differentBool, ih candidate unique.2 member]

private theorem formatSpanSubstring_of_valid_source (context : FormatSpanContext)
    (valid : formatSpanContextValid context) (start finish : Nat) :
    formatSpanSubstring (formatSpanContextOfString context.source) start finish =
      formatSpanSubstring context start finish := by
  simp [formatSpanSubstring, formatSpanContextOfString, valid.1]

theorem formatAcceptsFast_eq (rule : FormatRule) (text : String) :
    formatAcceptsFast rule text = formatAccepts rule text := by
  let compiled := (compileFormatSpan (formatRuleDepth rule) rule).run 0
  let root := compiled.1
  let context := formatSpanContextOfString text
  let oracle : (Nat × Nat × Nat × UInt64) → String → Bool :=
    fun (id, start, finish, _) source =>
      match (formatSpanNodeDomain root).find? (fun candidate => candidate.id == id) with
      | some candidate =>
        formatAccepts (formatSpanNodeRule candidate)
          (formatSpanSubstring (formatSpanContextOfString source) start finish)
      | none => false
  have rootUnique : ((formatSpanNodeDomain root).map FormatSpanNode.id).Nodup := by
    rw [formatSpanNodeDomain_ids]
    exact compileFormatSpan_ids_unique (formatRuleDepth rule) rule 0
  have oracleMatches : ∀ candidate ∈ formatSpanNodeDomain root,
      ∀ candidateContext : FormatSpanContext, formatSpanContextValid candidateContext →
      ∀ candidateStart candidateFinish,
        candidateStart ≤ candidateFinish →
        candidateFinish ≤ candidateContext.chars.size →
        oracle (candidate.id, candidateStart, candidateFinish, candidateContext.sourceHash)
            candidateContext.source =
          formatAccepts (formatSpanNodeRule candidate)
            (formatSpanSubstring candidateContext candidateStart candidateFinish) := by
    intro candidate member candidateContext candidateValid candidateStart candidateFinish
      startLe finishLe
    have found := formatSpanFindId_eq_some (formatSpanNodeDomain root) candidate
      rootUnique member
    simp [oracle, found, formatSpanSubstring_of_valid_source candidateContext
      candidateValid candidateStart candidateFinish]
  have evaluated := evalFormatSpan_oracle_sound oracle root.size context root
    0 context.chars.size {} (formatSpanContextOfString_valid text)
    (by simp [context]) (Nat.le_refl _) oracleMatches (memoOracle_empty oracle)
  change ((evalFormatSpan root.size context root 0 context.chars.size).run {}).1 =
    formatAccepts rule text
  rw [evaluated.1]
  simpa [root, compiled, context, formatSpanSubstring, formatSpanContextOfString,
    ← String.length_toList] using
    compileFormatSpan_meaning (formatRuleDepth rule) rule 0 text

def formatUseRule (profile : VersionedSemanticProfile) : FormatUse → Option FormatRule
  | .named name =>
    (profile.formatBindings.find? (fun binding => binding.name == name)).map (·.rule)
  | .inline rule => some rule

def formatUseIncluded (profile : VersionedSemanticProfile)
    (source destination : Option FormatUse) : Bool :=
  match destination with
  | none => true
  | some destination =>
    match source with
    | none => false
    | some source =>
      match formatUseRule profile source, formatUseRule profile destination with
      | some sourceRule, some destinationRule =>
        formatRuleIncluded sourceRule destinationRule
      | _, _ => false

private theorem formatUseRule_accepts (profile : VersionedSemanticProfile)
    (use : FormatUse) (rule : FormatRule) (text : String)
    (resolved : formatUseRule profile use = some rule) :
    formatUseAccepts profile use text = formatAccepts rule text := by
  cases use with
  | inline source =>
    simp [formatUseRule] at resolved
    subst rule
    exact formatAcceptsFast_eq source text
  | named name =>
    cases found : profile.formatBindings.find? (fun binding => binding.name == name) with
    | none => simp [formatUseRule, found] at resolved
    | some binding =>
      simp [formatUseRule, found] at resolved
      subst rule
      simp [formatUseAccepts, namedFormatAccepts, found, formatAcceptsFast_eq]

theorem formatUseIncluded_sound (profile : VersionedSemanticProfile)
    (source destination : Option FormatUse) (text : String)
    (included : formatUseIncluded profile source destination = true)
    (accepted : (source.map (fun use => !formatUseAccepts profile use text)).getD false = false) :
    (destination.map (fun use => !formatUseAccepts profile use text)).getD false = false := by
  cases destination with
  | none => rfl
  | some destination =>
    cases source with
    | none => simp [formatUseIncluded] at included
    | some source =>
      cases hsource : formatUseRule profile source with
      | none => simp [formatUseIncluded, hsource] at included
      | some sourceRule =>
        cases hdestination : formatUseRule profile destination with
        | none => simp [formatUseIncluded, hsource, hdestination] at included
        | some destinationRule =>
          have sourceAccepted : formatAccepts sourceRule text = true := by
            have fast : formatUseAccepts profile source text = true := by
              simpa using accepted
            simpa [formatUseRule_accepts profile source sourceRule text hsource] using fast
          have destinationAccepted :=
            formatRuleIncluded_sound sourceRule destinationRule text
              (by simpa [formatUseIncluded, hsource, hdestination] using included)
              sourceAccepted
          have fast : formatUseAccepts profile destination text = true := by
            simpa [formatUseRule_accepts profile destination destinationRule text hdestination]
              using destinationAccepted
          simp [fast]


def FieldValueAccepted (graph : SemanticGraph) (field : FieldSpec)
    (entries : List (String × JsonValue)) : Prop :=
  match memberValue field.wireName entries with
  | none => field.slot.required = false
  | some .null => field.slot.nullable = true
  | some value => ValueMember graph field.slot.typeRef [] value

def ElementValueAccepted (graph : SemanticGraph) (contract : ElementContract)
    (value : JsonValue) : Prop :=
  match value with
  | .null => contract.nullable = true ∨ ValueMember graph contract.typeRef [] .null
  | value => ValueMember graph contract.typeRef [] value

def ExtraValueAccepted (graph : SemanticGraph) (spec : ProductSpec)
    (key : String) (value : JsonValue) : Prop :=
  match spec.extras with
  | .reject => False
  | .allow keyFormat contract =>
    unicodeValid key = true ∧
    (keyFormat.map (fun use => !formatUseAccepts graph.profile use key)).getD false = false ∧
    ElementValueAccepted graph contract value

def ProductValueAccepted (graph : SemanticGraph) (spec : ProductSpec)
    (entries : List (String × JsonValue)) : Prop :=
  duplicateKey entries = none ∧
  tagMemberFailure graph.profile entries = none ∧
  classOf graph.profile entries = .ordinary ∧
  (∀ field ∈ spec.fields, FieldValueAccepted graph field entries) ∧
  ∀ key value, (key, value) ∈ entries →
    spec.fields.any (fun field => field.wireName == key) = false →
    (graph.profile.tag.map (fun tag => key == tag.key)).getD false = false →
    ExtraValueAccepted graph spec key value

private theorem slotRequirements_of_field_values (graph : SemanticGraph) (parent : TypeRef)
    (path : ValuePath) (entries : List (String × JsonValue)) (fields : List FieldSpec)
    (accepted : ∀ field ∈ fields, FieldValueAccepted graph field entries) :
    ∃ children, slotRequirements graph parent path entries fields = .requirements children ∧
      ∀ child ∈ children, ValueMember graph child.typeRef child.valuePath child.value := by
  induction fields with
  | nil => exact ⟨[], rfl, by simp⟩
  | cons field rest ih =>
    have here := accepted field (by simp)
    have tailAccepted : ∀ candidate ∈ rest, FieldValueAccepted graph candidate entries :=
      fun candidate present => accepted candidate (by simp [present])
    obtain ⟨tail, tailExpansion, tailMembers⟩ := ih tailAccepted
    cases found : memberValue field.wireName entries with
    | none =>
      simp [FieldValueAccepted, found] at here
      exact ⟨tail, by simp [slotRequirements, found, here, tailExpansion], tailMembers⟩
    | some value =>
      cases value with
      | null =>
        simp [FieldValueAccepted, found] at here
        exact ⟨tail, by simp [slotRequirements, found, here, tailExpansion], tailMembers⟩
      | bool value | num value | dec value | str value | arr value | obj value =>
        let actual := (memberValue field.wireName entries).getD .null
        let requirement : ValueRequirement := {
          typeRef := field.slot.typeRef
          valuePath := path ++ [.field field.wireName]
          value := actual }
        refine ⟨requirement :: tail, ?_, ?_⟩
        · simp [slotRequirements, found, tailExpansion, actual, requirement]
        · intro child present
          rcases List.mem_cons.mp present with equal | later
          · subst child
            have rooted : ValueMember graph field.slot.typeRef [] actual := by
              simpa [FieldValueAccepted, found, actual] using here
            exact valueMember_path_irrelevant graph _ [] _ _ rooted
          · exact tailMembers child later

private theorem elementRequirements_of_value (graph : SemanticGraph)
    (contract : ElementContract) (path : ValuePath) (value : JsonValue)
    (accepted : ElementValueAccepted graph contract value) :
    ∀ child ∈ elementRequirements contract path value,
      ValueMember graph child.typeRef child.valuePath child.value := by
  intro child present
  cases value with
  | null =>
    rcases accepted with nullable | member
    · simp [elementRequirements, nullable] at present
    · cases h : contract.nullable
      · have same : child =
            { typeRef := contract.typeRef, valuePath := path, value := .null } := by
          simpa [elementRequirements, h] using present
        subst child
        exact valueMember_path_irrelevant graph _ [] path .null member
      · simp [elementRequirements, h] at present
  | bool value =>
    have same : child = { typeRef := contract.typeRef, valuePath := path, value := .bool value } := by
      simpa [elementRequirements] using present
    subst child
    exact valueMember_path_irrelevant graph _ [] path _ accepted
  | num value =>
    have same : child = { typeRef := contract.typeRef, valuePath := path, value := .num value } := by
      simpa [elementRequirements] using present
    subst child
    exact valueMember_path_irrelevant graph _ [] path _ accepted
  | dec value =>
    have same : child = { typeRef := contract.typeRef, valuePath := path, value := .dec value } := by
      simpa [elementRequirements] using present
    subst child
    exact valueMember_path_irrelevant graph _ [] path _ accepted
  | str value =>
    have same : child = { typeRef := contract.typeRef, valuePath := path, value := .str value } := by
      simpa [elementRequirements] using present
    subst child
    exact valueMember_path_irrelevant graph _ [] path _ accepted
  | arr value =>
    have same : child = { typeRef := contract.typeRef, valuePath := path, value := .arr value } := by
      simpa [elementRequirements] using present
    subst child
    exact valueMember_path_irrelevant graph _ [] path _ accepted
  | obj value =>
    have same : child = { typeRef := contract.typeRef, valuePath := path, value := .obj value } := by
      simpa [elementRequirements] using present
    subst child
    exact valueMember_path_irrelevant graph _ [] path _ accepted

private theorem extraFieldRequirements_of_extra_values (graph : SemanticGraph)
    (path : ValuePath) (spec : ProductSpec) (entries : List (String × JsonValue))
    (accepted : ∀ key value, (key, value) ∈ entries →
      spec.fields.any (fun field => field.wireName == key) = false →
      (graph.profile.tag.map (fun tag => key == tag.key)).getD false = false →
      ExtraValueAccepted graph spec key value) :
    ∀ child ∈ extraFieldRequirements graph path spec entries,
      ValueMember graph child.typeRef child.valuePath child.value := by
  induction entries with
  | nil => simp [extraFieldRequirements]
  | cons entry rest ih =>
    obtain ⟨key, value⟩ := entry
    intro child present
    by_cases declared : spec.fields.any (fun field => field.wireName == key) = true
    · simp [extraFieldRequirements, declared] at present
      exact ih (fun k v member fieldFree tagFree =>
        accepted k v (by simp [member]) fieldFree tagFree) child present
    · have fieldFree : spec.fields.any (fun field => field.wireName == key) = false := by
        cases equal : spec.fields.any (fun field => field.wireName == key) <;> simp_all
      by_cases tagged :
          (graph.profile.tag.map (fun tag => key == tag.key)).getD false = true
      · simp [extraFieldRequirements, fieldFree, tagged] at present
        exact ih (fun k v member undeclared tagFree =>
          accepted k v (by simp [member]) undeclared tagFree) child present
      · have tagFree :
            (graph.profile.tag.map (fun tag => key == tag.key)).getD false = false := by
          cases equal :
              (graph.profile.tag.map (fun tag => key == tag.key)).getD false <;> simp_all
        have here := accepted key value (by simp) fieldFree tagFree
        cases extras : spec.extras with
        | reject => simp [ExtraValueAccepted, extras] at here
        | allow keyFormat contract =>
          simp only [ExtraValueAccepted, extras] at here
          rcases List.mem_append.mp (by
            simpa [extraFieldRequirements, fieldFree, tagFree, extras] using present) with
            element | later
          · exact elementRequirements_of_value graph contract _ value here.2.2 child element
          · exact ih (fun k v member undeclared untagged =>
              accepted k v (by simp [member]) undeclared untagged) child later


theorem extraMembersFailure_of_extra_values (graph : SemanticGraph)
    (spec : ProductSpec) (entries : List (String × JsonValue))
    (accepted : ∀ key value, (key, value) ∈ entries →
      spec.fields.any (fun field => field.wireName == key) = false →
      (graph.profile.tag.map (fun tag => key == tag.key)).getD false = false →
      ExtraValueAccepted graph spec key value) :
    extraMembersFailure graph spec entries = none := by
  simp [extraMembersFailure]
  intro key value present undeclared tagFree
  have fieldFree : spec.fields.any (fun field => field.wireName == key) = false := by
    rw [List.any_eq_false]
    intro field fieldPresent
    have different := undeclared field fieldPresent
    simpa using different
  have here := accepted key value present fieldFree tagFree
  cases extras : spec.extras with
  | reject => simp [ExtraValueAccepted, extras] at here
  | allow keyFormat contract =>
    simp [ExtraValueAccepted, extras] at here
    rcases here with ⟨unicode, keyAccepted, _⟩
    simp [unicode, keyAccepted]




private theorem firstRepeated_none_excludes_seen (seen keys : List String)
    (hnone : Necoherence.ExactJson.firstRepeated seen keys = none) :
    ∀ key ∈ seen, key ∉ keys := by
  induction keys generalizing seen with
  | nil => simp
  | cons head rest ih =>
    have headFree : head ∉ seen := by
      intro present
      simp [Necoherence.ExactJson.firstRepeated, present] at hnone
    have tailNone :
        Necoherence.ExactJson.firstRepeated (head :: seen) rest = none := by
      simpa [Necoherence.ExactJson.firstRepeated, headFree] using hnone
    have tail := ih (head :: seen) tailNone
    intro key keySeen
    simp only [List.mem_cons, not_or]
    exact ⟨fun equal => headFree (equal ▸ keySeen),
      tail key (by simp [keySeen])⟩

private theorem memberValue_of_mem_unique_aux (seen : List String)
    (entries : List (String × JsonValue)) (key : String) (value : JsonValue)
    (unique :
      Necoherence.ExactJson.firstRepeated seen (entries.map (·.1)) = none)
    (keyFree : key ∉ seen) (present : (key, value) ∈ entries) :
    memberValue key entries = some value := by
  induction entries generalizing seen with
  | nil => simp at present
  | cons entry rest ih =>
    obtain ⟨headKey, headValue⟩ := entry
    have headFree : headKey ∉ seen := by
      intro headSeen
      simp [Necoherence.ExactJson.firstRepeated, headSeen] at unique
    have tailUnique :
        Necoherence.ExactJson.firstRepeated (headKey :: seen) (rest.map (·.1)) = none := by
      simpa [Necoherence.ExactJson.firstRepeated, headFree] using unique
    rcases List.mem_cons.mp present with equal | later
    · cases equal
      simp [memberValue]
    · have different : headKey ≠ key := by
        intro equal
        subst headKey
        have excluded := firstRepeated_none_excludes_seen (key :: seen)
          (rest.map (·.1)) tailUnique key (by simp)
        exact excluded (List.mem_map.mpr ⟨(key, value), later, rfl⟩)
      have tailKeyFree : key ∉ headKey :: seen := by simp [different.symm, keyFree]
      have tail := ih (headKey :: seen) tailUnique tailKeyFree later
      unfold memberValue at tail ⊢
      rw [List.find?_cons]
      have differentBool : (headKey == key) = false := by
        simpa using different
      rw [differentBool]
      exact tail

theorem memberValue_of_mem_unique (entries : List (String × JsonValue))
    (key : String) (value : JsonValue) (unique : duplicateKey entries = none)
    (present : (key, value) ∈ entries) :
    memberValue key entries = some value := by
  apply memberValue_of_mem_unique_aux [] entries key value
  · exact unique
  · simp
  · exact present
theorem slotRequirements_contains_field (graph : SemanticGraph) (parent : TypeRef)
    (path : ValuePath) (entries : List (String × JsonValue)) (fields : List FieldSpec)
    (children : List ValueRequirement)
    (expansion : slotRequirements graph parent path entries fields = .requirements children)
    (field : FieldSpec) (declared : field ∈ fields) (value : JsonValue)
    (found : memberValue field.wireName entries = some value) (notNull : value ≠ .null) :
    { typeRef := field.slot.typeRef, valuePath := path ++ [.field field.wireName], value } ∈ children := by
  induction fields generalizing children with
  | nil => simp at declared
  | cons first rest ih =>
    rcases List.mem_cons.mp declared with equal | later
    · subst first
      cases value with
      | null => contradiction
      | bool value | num value | dec value | str value | arr value | obj value =>
        cases tailExpansion : slotRequirements graph parent path entries rest <;>
          simp [slotRequirements, found, tailExpansion] at expansion
        subst children
        exact List.mem_cons_self
    · cases firstValue : memberValue first.wireName entries with
      | none =>
        have optional : first.slot.required = false := by
          cases required : first.slot.required
          · rfl
          · simp [slotRequirements, firstValue, required] at expansion
        have tail : slotRequirements graph parent path entries rest = .requirements children := by
          cases tailExpansion : slotRequirements graph parent path entries rest <;>
            simpa [slotRequirements, firstValue, optional, tailExpansion] using expansion
        exact ih children tail later
      | some firstActual =>
        cases firstActual with
        | null =>
          have nullable : first.slot.nullable = true := by
            cases allowed : first.slot.nullable
            · simp [slotRequirements, firstValue, allowed] at expansion
            · rfl
          have tail : slotRequirements graph parent path entries rest = .requirements children := by
            cases tailExpansion : slotRequirements graph parent path entries rest <;>
              simpa [slotRequirements, firstValue, nullable, tailExpansion] using expansion
          exact ih children tail later
        | bool firstActual | num firstActual | dec firstActual | str firstActual | arr firstActual | obj firstActual =>
          cases tailExpansion : slotRequirements graph parent path entries rest with
          | rejected failure => simp [slotRequirements, firstValue, tailExpansion] at expansion
          | unresolved obligations => simp [slotRequirements, firstValue, tailExpansion] at expansion
          | requirements tail =>
            have identity : children =
                { typeRef := first.slot.typeRef,
                  valuePath := path ++ [.field first.wireName],
                  value := (memberValue first.wireName entries).getD .null } :: tail := by
              simpa [slotRequirements, firstValue, tailExpansion] using expansion.symm
            subst children
            exact List.mem_cons_of_mem _ (ih tail tailExpansion later)
theorem extraFieldRequirements_contains (graph : SemanticGraph)
    (path : ValuePath) (spec : ProductSpec) (entries : List (String × JsonValue))
    (key : String) (value : JsonValue) (present : (key, value) ∈ entries)
    (fieldFree : spec.fields.any (fun field => field.wireName == key) = false)
    (tagFree : (graph.profile.tag.map (fun tag => key == tag.key)).getD false = false)
    (keyFormat : Option FormatUse) (contract : ElementContract)
    (extras : spec.extras = .allow keyFormat contract) (notNull : value ≠ .null) :
    { typeRef := contract.typeRef, valuePath := path ++ [.field key], value } ∈
      extraFieldRequirements graph path spec entries := by
  induction entries with
  | nil => simp at present
  | cons entry rest ih =>
    obtain ⟨headKey, headValue⟩ := entry
    rcases List.mem_cons.mp present with equal | later
    · cases equal
      simp [extraFieldRequirements, fieldFree, tagFree, extras, elementRequirements, notNull]
    · simp only [extraFieldRequirements]
      by_cases declared :
          spec.fields.any (fun field => field.wireName == headKey) = true
      · simp [declared]
        exact ih later
      · have headFieldFree :
            spec.fields.any (fun field => field.wireName == headKey) = false := by
          cases equal :
              spec.fields.any (fun field => field.wireName == headKey) <;> simp_all
        by_cases tagged :
            (graph.profile.tag.map (fun tag => headKey == tag.key)).getD false = true
        · simp [headFieldFree, tagged]
          exact ih later
        · have headTagFree :
              (graph.profile.tag.map (fun tag => headKey == tag.key)).getD false = false := by
            cases equal :
                (graph.profile.tag.map (fun tag => headKey == tag.key)).getD false <;> simp_all
          simp [headFieldFree, headTagFree, extras]
          exact Or.inr (ih later)

theorem extraFieldRequirements_contains_element (graph : SemanticGraph)
    (path : ValuePath) (spec : ProductSpec) (entries : List (String × JsonValue))
    (key : String) (value : JsonValue) (present : (key, value) ∈ entries)
    (fieldFree : spec.fields.any (fun field => field.wireName == key) = false)
    (tagFree : (graph.profile.tag.map (fun tag => key == tag.key)).getD false = false)
    (keyFormat : Option FormatUse) (contract : ElementContract)
    (extras : spec.extras = .allow keyFormat contract) :
    ∀ child ∈ elementRequirements contract (path ++ [.field key]) value,
      child ∈ extraFieldRequirements graph path spec entries := by
  induction entries with
  | nil => simp at present
  | cons entry rest ih =>
    obtain ⟨headKey, headValue⟩ := entry
    rcases List.mem_cons.mp present with equal | later
    · cases equal
      intro child element
      simp [extraFieldRequirements, fieldFree, tagFree, extras, element]
    · intro child element
      simp only [extraFieldRequirements]
      by_cases declared : spec.fields.any (fun field => field.wireName == headKey) = true
      · simp [declared]
        exact ih later child element
      · have headFieldFree :
            spec.fields.any (fun field => field.wireName == headKey) = false := by
          cases equal :
              spec.fields.any (fun field => field.wireName == headKey) <;> simp_all
        by_cases tagged :
            (graph.profile.tag.map (fun tag => headKey == tag.key)).getD false = true
        · simp [headFieldFree, tagged]
          exact ih later child element
        · have headTagFree :
              (graph.profile.tag.map (fun tag => headKey == tag.key)).getD false = false := by
            cases equal :
                (graph.profile.tag.map (fun tag => headKey == tag.key)).getD false <;> simp_all
          simp [headFieldFree, headTagFree, extras]
          exact Or.inr (ih later child element)

theorem product_accepted_of_value (graph : SemanticGraph) (ref : TypeRef)
    (node : TypeNode) (spec : ProductSpec)
    (lookup : graph.findType ref = some node) (shape : node.shape = .product spec)
    (entries : List (String × JsonValue)) (member : ValueMember graph ref [] (.obj entries)) :
    ProductValueAccepted graph spec entries := by
  obtain ⟨children, expansion, members⟩ :=
    member_expansion_has_members graph ref [] (.obj entries) member
  simp only [expandValue, expandNode, objectMemberFailure, lookup, shape] at expansion
  cases duplicate : duplicateKey entries with
  | some key => simp [duplicate] at expansion
  | none =>
    cases tag : tagMemberFailure graph.profile entries with
    | some failure =>
      obtain ⟨key, condition, observed⟩ := failure
      simp [duplicate, tag] at expansion
    | none =>
      cases classified : classOf graph.profile entries with
      | sealed form => simp [duplicate, tag, classified] at expansion
      | wrapper wrapper => simp [duplicate, tag, classified] at expansion
      | ordinary =>
        cases extra : extraMembersFailure graph spec entries with
        | some failed => simp [duplicate, tag, classified, extra] at expansion
        | none =>
          cases fieldExpansion : slotRequirements graph ref [] entries spec.fields with
          | rejected failure =>
            simp [productRequirements, duplicate, tag, classified, extra, fieldExpansion] at expansion
          | unresolved obligations =>
            simp [productRequirements, duplicate, tag, classified, extra, fieldExpansion] at expansion
          | requirements fieldChildren =>
            have identity :
                children = fieldChildren ++ extraFieldRequirements graph [] spec entries := by
              simpa [productRequirements, duplicate, tag, classified, extra, fieldExpansion]
                using expansion.symm
            subst children
            refine ⟨duplicate, tag, classified, ?_, ?_⟩
            · intro field declared
              have slot := slotRequirements_field_sound graph ref [] entries spec.fields
                fieldChildren fieldExpansion
                (fun child present => members child (List.mem_append_left _ present))
                field declared
              cases found : memberValue field.wireName entries with
              | none =>
                have observed : SlotMember graph field.slot .absent := by
                  simpa [valueAtPath, found] using slot
                cases observed with
                | absent optional => simpa [FieldValueAccepted, found] using optional
              | some value =>
                cases value with
                | null =>
                  have observed : SlotMember graph field.slot .null := by
                    simpa [valueAtPath, found] using slot
                  cases observed with
                  | null nullable => simpa [FieldValueAccepted, found] using nullable
                | bool value | num value | dec value | str value | arr value | obj value =>
                  have observed : SlotMember graph field.slot
                      (.present ((memberValue field.wireName entries).getD .null)) := by
                    simpa [valueAtPath, found] using slot
                  cases observed with
                  | present value childMember =>
                    simpa [FieldValueAccepted, found] using childMember
            · intro key value present fieldFree tagFree
              simp [extraMembersFailure] at extra
              have acceptedCondition := extra key value present
              have undeclared : ∀ field ∈ spec.fields, field.wireName ≠ key := by
                rw [List.any_eq_false] at fieldFree
                intro field declared equal
                have := fieldFree field declared
                simp [equal] at this
              have acceptedCondition := acceptedCondition undeclared tagFree
              cases extras : spec.extras with
              | reject => simp [extras] at acceptedCondition
              | allow keyFormat contract =>
                rw [extras] at acceptedCondition
                have unicode : unicodeValid key = true := by
                  cases valid : unicodeValid key
                  · simp [valid] at acceptedCondition
                  · rfl
                have keyAccepted :
                    (keyFormat.map
                      (fun use => !formatUseAccepts graph.profile use key)).getD false = false := by
                  cases valid :
                      (keyFormat.map
                        (fun use => !formatUseAccepts graph.profile use key)).getD false
                  · rfl
                  · simp [unicode, valid] at acceptedCondition
                simp only [ExtraValueAccepted, extras]
                refine ⟨unicode, keyAccepted, ?_⟩
                cases value with
                | null =>
                  cases nullable : contract.nullable
                  · right
                    let child : ValueRequirement :=
                      { typeRef := contract.typeRef, valuePath := [.field key], value := .null }
                    have element : child ∈ elementRequirements contract [.field key] .null := by
                      simp [child, elementRequirements, nullable]
                    have required := extraFieldRequirements_contains_element graph [] spec entries
                      key .null present fieldFree tagFree keyFormat contract extras child element
                    exact valueMember_path_irrelevant graph _ _ [] _
                      (members _ (List.mem_append_right _ required))
                  · exact Or.inl (by simpa using nullable)
                | bool value | num value | dec value | str value | arr value | obj value =>
                  have required := extraFieldRequirements_contains graph [] spec entries key _
                    present fieldFree tagFree keyFormat contract extras (by simp)
                  exact valueMember_path_irrelevant graph _ _ [] _
                    (members _ (List.mem_append_right _ required))
theorem product_expansion_transport (graph : SemanticGraph) (ref : TypeRef)
    (node : TypeNode) (spec : ProductSpec)
    (lookup : graph.findType ref = some node) (shape : node.shape = .product spec)
    (entries : List (String × JsonValue)) (accepted : ProductValueAccepted graph spec entries) :
    ValueMember graph ref [] (.obj entries) := by
  obtain ⟨duplicate, tag, classified, fieldsAccepted, extrasAccepted⟩ := accepted
  obtain ⟨fieldChildren, fieldsExpansion, fieldMembers⟩ :=
    slotRequirements_of_field_values graph ref [] entries spec.fields fieldsAccepted
  have extrasCondition : extraMembersFailure graph spec entries = none :=
    extraMembersFailure_of_extra_values graph spec entries extrasAccepted
  exact .step ref [] (.obj entries)
    (fieldChildren ++ extraFieldRequirements graph [] spec entries)
    (by simp [expandValue, expandNode, objectMemberFailure, lookup, shape, duplicate, tag,
      classified, extrasCondition, productRequirements, fieldsExpansion])
    (by
      intro child present
      rcases List.mem_append.mp present with field | extra
      · exact fieldMembers child field
      · exact extraFieldRequirements_of_extra_values graph [] spec entries extrasAccepted
          child extra)
end Necoherence.SemanticValidation

