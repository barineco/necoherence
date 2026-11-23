-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: AGPL-3.0-only

import Lean
import Necoherence.SemanticValidation
import Necoherence.SignatureProfileWire

namespace NecoherenceTools.SemanticInvariantOutput
open Lean Necoherence.SemanticTypes Necoherence.SignatureWire

def conditionName : ValueCondition → String
  | .missingRequired => "MissingRequired" | .nullNotAllowed => "NullNotAllowed"
  | .wrongValueKind expected => "WrongValueKind:" ++ expected
  | .constMismatch => "ConstMismatch" | .enumMismatch => "EnumMismatch"
  | .belowMinimum => "BelowMinimum" | .aboveMaximum => "AboveMaximum"
  | .integerDomain => "IntegerDomain" | .stringLength => "StringLength"
  | .arrayLength => "ArrayLength" | .bytesLength => "BytesLength"
  | .format name => "Format:" ++ name | .invalidBytes => "InvalidBytes"
  | .invalidWrapper name => "InvalidWrapper:" ++ name | .invalidTag => "InvalidTag"
  | .reservedForm => "ReservedForm" | .noBranchSelected => "NoBranchSelected"
  | .keyFormat name => "KeyFormat:" ++ name | .uninhabited => "Uninhabited"
  | .duplicateField name => "DuplicateField:" ++ name
  | .unexpectedField name => "UnexpectedField:" ++ name
  | .invalidDataModel => "InvalidDataModel" | .referenceCycle => "ReferenceCycle"

def pathJson (path : ValuePath) : Json := .arr (path.map (fun step => match step with
  | .field name => Json.str name | .index index => toJson index | .variant tag => Json.str ("variant:" ++ tag))).toArray

def wireFailureClassification : WireFailure → String
  | .unsupportedSchema _ _ => "UnsupportedSchema"
  | .unknownField _ _ => "UnknownField"
  | .unknownTag _ _ => "UnknownTag"
  | .syntax _ _ => "Syntax"

def wireFailurePath : WireFailure → String
  | .unsupportedSchema path _ | .unknownField path _ | .unknownTag path _ | .syntax path _ => path

def wireFailureJson (failure : WireFailure) : Json := Json.mkObj [("status", .str "Rejected"),
  ("failure_kind", .str "Wire"), ("classification", .str (wireFailureClassification failure)),
  ("path", .str (wireFailurePath failure))]

end NecoherenceTools.SemanticInvariantOutput
