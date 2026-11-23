-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SemanticExecution

namespace Necoherence.SemanticNetwork

open Necoherence.SemanticExecution
open Necoherence.SemanticComposition Necoherence.SemanticTypes

structure NetworkBinding (α β : Type) where
  encode : α → Except ExecutionFailure AttemptInput
  decode : RawHttpResponse → Except ExecutionFailure β

end Necoherence.SemanticNetwork
