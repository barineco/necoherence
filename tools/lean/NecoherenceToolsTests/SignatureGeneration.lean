-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: AGPL-3.0-only

import NecoherenceToolsTests.TypeSignatures
import NecoherenceToolsTests.SignatureExchange

def main : IO UInt32 := do
  runTypeSignatureInvariants
  runSignatureExchangeProperties
  pure 0
