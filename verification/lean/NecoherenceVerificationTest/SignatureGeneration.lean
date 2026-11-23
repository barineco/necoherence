-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: AGPL-3.0-only

import NecoherenceGeneratorTest.TypeSignatures
import NecoherenceVerificationTest.SignatureExchange

def main : IO UInt32 := do
  runTypeSignatureInvariants
  runSignatureExchangeProperties
  runIntegerEncodingForms
  pure 0
