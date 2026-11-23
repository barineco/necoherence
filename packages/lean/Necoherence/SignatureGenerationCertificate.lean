-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SignatureGenerationBasis

namespace Necoherence.SignatureGeneration
open Necoherence.SignatureWire

def ruleRevision : String := "ncoh-checked-generation@5"

def provenance : String := "admit_signature_generation"

structure GenerationLibrary where
  signatureSchema : String
  identity : String
  revision : String
  profile : Necoherence.SemanticTypes.ProfileRef
  deriving Repr, DecidableEq

structure GenerationCoordinate where
  signatureSchema : String
  profile : Necoherence.SemanticTypes.ProfileRef
  graphSha256 : String
  provenanceSha256 : String
  metadataSha256 : String
  problemSha256 : Option String
  observationsSha256 : Option String
  entrypointsSha256 : String
  library : GenerationLibrary
  deriving Repr, DecidableEq

instance : ToString GenerationCoordinate := ⟨fun coordinate => reprStr coordinate⟩

structure GenerationEvidence where
  graph : Lean.Json
  provenance : Lean.Json
  metadata : Lean.Json
  entrypoints : Lean.Json
  composition : Option Lean.Json

def scopedDigest (digest : String) : NecoQuotient.ProjectionDigest :=
  { digest := digest, scope := .crossLanguage "sha256" }

def projectionDigests (entrypoints graph metadata provenance : String) (problem observations : Option String) :
    NecoQuotient.ProjectionDigests :=
  let base := ((((NecoQuotient.NameMap.empty.addNew "entrypoints" (scopedDigest entrypoints)).addNew
    "graph" (scopedDigest graph)).addNew "metadata" (scopedDigest metadata)).addNew
    "provenance" (scopedDigest provenance))
  let withProblem := match problem with
    | some digest => base.addNew "problem" (scopedDigest digest)
    | none => base
  match observations with
  | some digest => withProblem.addNew "observations" (scopedDigest digest)
  | none => withProblem

def certificateCoordinate (input : Input) : GenerationCoordinate :=
  { signatureSchema := input.basis.signatureSchema
    profile := input.basis.profile
    graphSha256 := input.basis.graphSha256
    provenanceSha256 := input.basis.provenanceSha256
    metadataSha256 := input.basis.metadataSha256
    problemSha256 := input.basis.problemSha256
    observationsSha256 := input.basis.observationsSha256
    entrypointsSha256 := input.basis.entrypointsSha256
    library := { signatureSchema := input.signatures.schema
                 identity := input.signatures.identity
                 revision := input.signatures.revision
                 profile := input.signatures.profile.reference } }

def expectedCoordinate (expected : Basis) (declared : Basis) : GenerationCoordinate :=
  { signatureSchema := expected.signatureSchema
    profile := expected.profile
    graphSha256 := expected.graphSha256
    provenanceSha256 := expected.provenanceSha256
    metadataSha256 := expected.metadataSha256
    problemSha256 := expected.problemSha256
    observationsSha256 := expected.observationsSha256
    entrypointsSha256 := expected.entrypointsSha256
    library := { signatureSchema := declared.signatureSchema
                 identity := declared.libraryIdentity
                 revision := declared.libraryRevision
                 profile := declared.profile } }

def generationEvidence (input : Input) : GenerationEvidence :=
  { graph := graphProjection input.signatures
    provenance := provenanceProjection input.signatures
    metadata := metadataProjection input.signatures
    entrypoints := encode (input.entrypoints.mergeSort (fun a b => a.identity ≤ b.identity))
    composition := input.composition }

def generationCertificate (input : Input) (observations : Option GoalObservations) :
    NecoQuotient.Certificate String String GenerationCoordinate (Option GoalObservations) String GenerationEvidence :=
  { ruleRevision := input.schema
    source := { identity := input.basis.libraryIdentity, revision := input.basis.libraryRevision }
    coordinate := certificateCoordinate input
    digests := projectionDigests input.basis.entrypointsSha256 input.basis.graphSha256
      input.basis.metadataSha256 input.basis.provenanceSha256 input.basis.problemSha256
      input.basis.observationsSha256
    residuals := NecoQuotient.ResidualSet.ofList []
    observations := observations
    evidence := generationEvidence input }

def generationExpectation (input : Input) (expected : ExpectedBasis) :
    NecoQuotient.Expected String String GenerationCoordinate (Option GoalObservations) String :=
  { ruleRevision := ruleRevision
    source := { identity := expected.basis.libraryIdentity, revision := expected.basis.libraryRevision }
    coordinate := expectedCoordinate expected.basis input.basis
    observations := expected.observations
    residuals := NecoQuotient.ResidualSet.ofList [] }

def generationRecompute :
    NecoQuotient.Recompute String String GenerationCoordinate (Option GoalObservations) GenerationEvidence :=
  fun _ _ _ evidence =>
    projectionDigests (hash evidence.entrypoints) (hash evidence.graph) (hash evidence.metadata)
      (hash evidence.provenance) (evidence.composition.map hash)
      (evidence.composition.map fun value => (goalObservations value).digest)

def generationTable :
    NecoQuotient.RuleTable String String GenerationCoordinate (Option GoalObservations) GenerationEvidence :=
  [(ruleRevision, { recompute := generationRecompute })]

def admitCertificate (input : Input) (expected : ExpectedBasis) (observations : Option GoalObservations) :
    Except (NecoQuotient.Mismatch String)
      (NecoQuotient.Checked String String GenerationCoordinate (Option GoalObservations) String GenerationEvidence) :=
  NecoQuotient.admitWithRules generationTable (generationCertificate input observations)
    (generationExpectation input expected) provenance

theorem nameMapEmpty_get? {α : Type} (name : String) :
    (NecoQuotient.NameMap.empty : NecoQuotient.NameMap α).get? name = none := rfl

theorem projectionDigests_entrypoints (e g m p : String) (pr ob : Option String) :
    (projectionDigests e g m p pr ob).get? "entrypoints" = some (scopedDigest e) := by
  cases pr <;> cases ob <;> simp [projectionDigests, NecoQuotient.NameMap.addNew_get?, nameMapEmpty_get?]

theorem projectionDigests_graph (e g m p : String) (pr ob : Option String) :
    (projectionDigests e g m p pr ob).get? "graph" = some (scopedDigest g) := by
  cases pr <;> cases ob <;> simp [projectionDigests, NecoQuotient.NameMap.addNew_get?, nameMapEmpty_get?]

theorem projectionDigests_metadata (e g m p : String) (pr ob : Option String) :
    (projectionDigests e g m p pr ob).get? "metadata" = some (scopedDigest m) := by
  cases pr <;> cases ob <;> simp [projectionDigests, NecoQuotient.NameMap.addNew_get?, nameMapEmpty_get?]

theorem projectionDigests_provenance (e g m p : String) (pr ob : Option String) :
    (projectionDigests e g m p pr ob).get? "provenance" = some (scopedDigest p) := by
  cases pr <;> cases ob <;> simp [projectionDigests, NecoQuotient.NameMap.addNew_get?, nameMapEmpty_get?]

theorem projectionDigests_problem (e g m p : String) (pr ob : Option String) :
    (projectionDigests e g m p pr ob).get? "problem" = pr.map scopedDigest := by
  cases pr <;> cases ob <;> simp [projectionDigests, NecoQuotient.NameMap.addNew_get?, nameMapEmpty_get?]

theorem projectionDigests_observations (e g m p : String) (pr ob : Option String) :
    (projectionDigests e g m p pr ob).get? "observations" = ob.map scopedDigest := by
  cases pr <;> cases ob <;> simp [projectionDigests, NecoQuotient.NameMap.addNew_get?, nameMapEmpty_get?]

theorem scopedDigest_injective {a b : String} (h : scopedDigest a = scopedDigest b) : a = b := by
  simpa [scopedDigest] using congrArg NecoQuotient.ProjectionDigest.digest h

theorem option_scopedDigest_injective {a b : Option String}
    (h : a.map scopedDigest = b.map scopedDigest) : a = b := by
  cases a <;> cases b <;> simp_all [scopedDigest]

theorem generationTable_lookup {v : String}
    {r : NecoQuotient.Rule String String GenerationCoordinate (Option GoalObservations) GenerationEvidence}
    (h : generationTable.lookup v = some r) :
    v = ruleRevision ∧ r.recompute = generationRecompute := by
  by_cases hv : v = ruleRevision
  · subst hv
    simp [generationTable, NecoQuotient.RuleTable.lookup] at h
    subst h
    exact ⟨rfl, rfl⟩
  · simp [generationTable, NecoQuotient.RuleTable.lookup, Ne.symm hv] at h

theorem basis_eq_of_fields (b : Basis) (library : Necoherence.TypeSignatures.TypeSignatureLibrary)
    (entrypoints : List Entrypoint) (composition : Option Lean.Json)
    (h1 : b.signatureSchema = library.schema) (h2 : b.libraryIdentity = library.identity)
    (h3 : b.libraryRevision = library.revision) (h4 : b.profile = library.profile.reference)
    (h5 : b.graphSha256 = hash (graphProjection library))
    (h6 : b.provenanceSha256 = hash (provenanceProjection library))
    (h7 : b.metadataSha256 = hash (metadataProjection library))
    (h8 : b.problemSha256 = composition.map hash)
    (h10 : b.observationsSha256 = composition.map fun value => (goalObservations value).digest)
    (h9 : b.entrypointsSha256 = hash (encode (entrypoints.mergeSort (fun a b => a.identity ≤ b.identity)))) :
    b = basis library entrypoints composition := by
  cases b
  simp only [basis, Basis.mk.injEq]
  exact ⟨h1, h2, h3, h4, h5, h6, h7, h8, h10, h9⟩

theorem basis_of_admitted (input : Input) (expected : ExpectedBasis) (observations : Option GoalObservations)
    (checked : NecoQuotient.Checked String String GenerationCoordinate (Option GoalObservations) String GenerationEvidence)
    (h : admitCertificate input expected observations = .ok checked) :
    input.basis = basis input.signatures input.entrypoints input.composition := by
  obtain ⟨r, hlook, -, -, hcoord, -, hdigest, -⟩ :=
    (NecoQuotient.admitWithRules_ok_iff generationTable (generationCertificate input observations)
      (generationExpectation input expected) provenance).1 ⟨checked, h⟩
  obtain ⟨-, hr⟩ := generationTable_lookup hlook
  rw [hr] at hdigest
  have hlib := congrArg GenerationCoordinate.library hcoord
  simp only [generationCertificate, generationExpectation, certificateCoordinate,
    expectedCoordinate, GenerationLibrary.mk.injEq] at hlib
  obtain ⟨hs, hi, hv, hp⟩ := hlib
  have hg := hdigest "graph"
  have hm := hdigest "metadata"
  have hpv := hdigest "provenance"
  have he := hdigest "entrypoints"
  have hpr := hdigest "problem"
  have hob := hdigest "observations"
  simp only [NecoQuotient.NameMap.getElem?_eq, generationCertificate, generationRecompute,
    generationEvidence, projectionDigests_graph, projectionDigests_metadata,
    projectionDigests_provenance, projectionDigests_entrypoints, projectionDigests_problem,
    projectionDigests_observations]
    at hg hm hpv he hpr hob
  exact basis_eq_of_fields input.basis input.signatures input.entrypoints input.composition
    hs.symm hi.symm hv.symm hp.symm
    (scopedDigest_injective (Option.some.inj hg)) (scopedDigest_injective (Option.some.inj hpv))
    (scopedDigest_injective (Option.some.inj hm))
    (option_scopedDigest_injective hpr)
    (option_scopedDigest_injective hob)
    (scopedDigest_injective (Option.some.inj he))

end Necoherence.SignatureGeneration
