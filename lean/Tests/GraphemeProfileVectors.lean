-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SignatureGeneration

open Lean Necoherence.SemanticTypes Necoherence.TypeSignatures

private def require (condition : Bool) (message : String) : IO Unit :=
  if condition then pure () else throw (IO.userError message)

private def hexadecimal (text : String) : Except String Nat :=
  text.toList.foldlM (init := 0) fun value character => do
    let digit ← if '0' ≤ character && character ≤ '9' then pure (character.toNat - '0'.toNat)
      else if 'A' ≤ character && character ≤ 'F' then pure (character.toNat - 'A'.toNat + 10)
      else if 'a' ≤ character && character ≤ 'f' then pure (character.toNat - 'a'.toNat + 10)
      else throw "invalid vector codepoint"
    pure (value * 16 + digit)

def main : IO UInt32 := do
  let source ← IO.FS.readFile "../typescript/tests/synthetic-profile.json"
  let .ok json := Necoherence.SignatureJson.parse source |
    throw (IO.userError "grapheme source JSON")
  let graphemeJson ← match json.getObjVal? "grapheme_rules" with
    | .ok value => pure value
    | .error _ => throw (IO.userError "grapheme rules field")
  let .ok rules := Necoherence.SignatureWire.decode (α := GraphemeRules) graphemeJson |
    throw (IO.userError "grapheme rules decode")
  let profile : ValueProfile := {
    reference := rules.reference
    graphemeRules := some rules
    integerDomains := [{ name := "integer", reference := rules.reference, range := .unbounded, forms := [.number] }]
    defaultIntegerDomain := "integer" }
  require (rules.component.unicodeVersion == "16.0.0" && rules.component.uax29Revision == "45" &&
    rules.component.clusterProfile == "C1-1-default-extended-grapheme-cluster-no-tailoring" &&
    rules.tableSha256 == "846859ef6ca813a7fe439aac05463456b18fc739c41e1089ab1da9265f5ebd6c") "official grapheme component"
  let expectedSources := [
    ("grapheme_break_property", "16.0.0", "GraphemeBreakProperty.txt", "c29360bd6f7132811d701d29069541e827eb44bfc4c8fbde8c370d6982689dc1"),
    ("emoji_data", "16.0.0", "emoji-data.txt", "f1365a5173eee18e1f98b240cdc492e84a25f1ce7e0c9d1094eb29c41a22696a"),
    ("derived_core_properties", "16.0.0", "DerivedCoreProperties.txt", "39d35161f2954497f69e08bdb9e701493f476a3d30222de20028feda36c1dabd"),
    ("grapheme_break_test", "16.0.0", "GraphemeBreakTest.txt", "ee2b9354d270ac061b29f09662cafea06341d77e704b8cc6bd72aaeeda363cb5"),
    ("license", "16.0.0", "LICENSE.txt", "e7a93b009565cfce55919a381437ac4db883e9da2126fa28b91d12732bc53d96"),
    ("uax29", "UAX29-45", "reports/tr29/tr29-45.html", "4579c185bd45feac761de590d874aca71788e339b35179318a4c43412fd4f9e4")]
  require (rules.sources.length == expectedSources.length) "official grapheme source count"
  for (role, revision, path, digest) in expectedSources do
    let some resolved := rules.sources.find? (·.role == role) | throw (IO.userError role)
    require (resolved.origin.source.repository == "unicode.org" && resolved.origin.source.revision == revision &&
      resolved.origin.source.path == path && resolved.origin.source.contentDigest == digest &&
      resolved.origin.locator.isEmpty) ("official source " ++ role)
  require (Necoherence.Sha256.digest "" == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" &&
    Necoherence.Sha256.digest "abc" == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad") "SHA-256 vectors"
  let library : TypeSignatureLibrary := {
    identity := "official-vector-profile", revision := "2", profile,
    sources := [], nodes := [], definitions := [] }
  require (checkLibrary library).isOk "official profile admission"
  let vectors ← IO.FS.readFile "../comparison/declaration/semantic_profile_data/GraphemeBreakTest.txt"
  let mut count := 0
  for line in vectors.splitOn "\n" do
    let body := (line.splitOn "#").head!.trimAscii.toString
    if body.isEmpty then continue
    let mut chars : List Char := []
    let mut expected : List Nat := []
    for token in (body.splitOn " ").filter (· != "") do
      if token == "÷" then expected := expected ++ [chars.length]
      else if token == "×" then pure ()
      else
        let .ok scalar := hexadecimal token | throw (IO.userError "vector hexadecimal")
        chars := chars ++ [Char.ofNat scalar]
    require (Necoherence.SemanticValidation.graphemeBoundaries rules (String.ofList chars) == expected) ("official grapheme vector " ++ toString count)
    count := count + 1
  IO.println s!"official_grapheme_vectors={count} profile_sources=6 digest_tamper=1 sha256_vectors=2"
  pure 0
