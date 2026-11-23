-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Lean

open Lean

def libraryRoot : Name := `Necoherence

def moduleName (path : System.FilePath) : Option Name :=
  if path.extension == some "lean" then
    some ((path.withExtension "").components.foldl Name.str Name.anonymous)
  else
    none

def libraryModules : IO (Array Name) := do
  let files ← System.FilePath.walkDir (libraryRoot.toString : System.FilePath)
  let nested := files.filterMap moduleName
  pure (#[libraryRoot] ++ nested.qsort Name.lt)

def usesSorry (info : ConstantInfo) : Bool :=
  info.getUsedConstantsAsSet.contains ``sorryAx

def main : IO UInt32 := do
  initSearchPath (← findSysroot)
  let modules ← libraryModules
  let env ← importModules (modules.map fun module => { module }) {} (loadExts := false)
  let inLibrary (name : Name) : Bool :=
    match env.getModuleIdxFor? name with
    | some index => modules.contains env.header.moduleNames[index.toNat]!
    | none => false
  let checked := env.constants.map₁.fold (fun acc name info =>
    if inLibrary name then acc.push (name, usesSorry info) else acc) #[]
  let unproved := checked.filterMap fun (name, sorried) => if sorried then some name else none
  if checked.isEmpty then
    IO.eprintln s!"no declarations were found in the {modules.size} library modules"
    return 1
  if !unproved.isEmpty then
    IO.eprintln s!"declarations that depend on sorry: {unproved.toList}"
    return 1
  IO.println s!"{checked.size} declarations in {modules.size} library modules are free of sorry"
  return 0
