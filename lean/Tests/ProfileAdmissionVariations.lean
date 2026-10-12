-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SemanticProfile
import Necoherence.SignatureProfileWire
import Necoherence.SemanticValidation

namespace Necoherence.ProfileAdmissionVariations

open Lean Necoherence.SemanticTypes Necoherence.SemanticProfile Necoherence.SemanticValidation Necoherence.SignatureWire

private def expected (identity revision : String) : ProfileRef :=
  { identity, revision, contentDigest := "digest" }

private def source : SourceIdentity :=
  { repository := "synthetic-repository", revision := "source-r2",
    path := "profiles/source.json", contentDigest := "source-digest" }

private def firstProfile : VersionedSemanticProfile :=
  { reference := expected "synthetic-one" "r1"
    integerDomains := [{
      name := "integer", reference := expected "synthetic-one" "r1",
      range := .unbounded, forms := [.number] }]
    defaultIntegerDomain := "integer" }

private def secondProfile : VersionedSemanticProfile :=
  let reference := expected "synthetic-two" "r2"
  { reference
    sourceRefs := [source]
    integerDomains := [{
      name := "integer", reference, range := .inclusive (-3) 7,
      forms := [.number, .integralDecimal] }]
    defaultIntegerDomain := "integer"
    numbers := { decimals := true }
    formatBindings := [
      { name := "text", reference, rule := .text },
      { name := "tag", reference, rule := .not (.sequence [.text, .literal "#Root"]) }]
    bytesPolicy := some {
      reference, paddingOptional := false, alphabet := .urlSafe,
      strictPadBits := true, wrapper := some "bytes" }
    wrappers := [
      { name := "bytes", key := "payload", payload := .bytes },
      { name := "text", key := "target", payload := .text (some "text") }]
    tag := some {
      key := "kind", format := some "tag", sealed := [{
        tag := "sealed", fields := [{
          key := "value", required := true,
          leaf := .string { format := some (.named "text") } }], extras := .reject }] } }

private def decodeEncoded (profile : VersionedSemanticProfile) :
    Except ProfileAdmissionFailure CheckedProfile :=
  let bytes := (encode profile).compress
  decodeProfileJson profile.reference profile.sourceRefs bytes bytes

def arbitraryProfilesAccepted : Bool :=
  match decodeEncoded firstProfile, decodeEncoded secondProfile with
  | .ok first, .ok second =>
    first.profile == firstProfile && second.profile == secondProfile
  | _, _ => false

def profileEvaluationUsesDecodedProfile : Bool :=
  match decodeEncoded secondProfile with
  | .error _ => false
  | .ok checked =>
    tagValueAccepts checked.profile [("kind", .str "doc#main")] &&
      !tagValueAccepts checked.profile [("kind", .str "doc#Root")]

def bindingRejections : Bool :=
  let bytes := (encode secondProfile).compress
  let wrongSource := { source with contentDigest := "other" }
  let emptyDigest := decodeProfileJson
    { identity := "synthetic-two", revision := "r2", contentDigest := "" } [source] bytes bytes
  let identityMismatch := decodeProfileJson (expected "other" "r2") [source] bytes bytes
  let revisionMismatch := decodeProfileJson (expected "synthetic-two" "other") [source] bytes bytes
  let sourceMismatch := decodeProfileJson secondProfile.reference [wrongSource] bytes bytes
  let trustedMismatch := decodeProfileJson secondProfile.reference [source] bytes "{}"
  (match emptyDigest with | .error (.syntax .digestMismatch) => true | _ => false) &&
    (match identityMismatch with | .error (.syntax .basisMismatch) => true | _ => false) &&
    (match revisionMismatch with | .error (.syntax .basisMismatch) => true | _ => false) &&
    (match sourceMismatch with | .error (.syntax .basisMismatch) => true | _ => false) &&
    (match trustedMismatch with | .error (.syntax .digestMismatch) => true | _ => false)

end Necoherence.ProfileAdmissionVariations
