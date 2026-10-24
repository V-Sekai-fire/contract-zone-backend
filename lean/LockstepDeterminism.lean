-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 K. S. Ernest (iFire) Lee
--
-- Lean4 spec for RFD66606-0043's Lean4 -> CBMC -> RISC-V -> libriscv
-- verification pipeline (RFD66606-0041/0042's chosen approach). Lean4's
-- `Float` is IEEE 754 binary64 (Lean4's own core library backs it with
-- the platform's native `double`), so this spec's evaluation order IS
-- the semantics an equivalence-checked C implementation must match
-- exactly -- floating point addition is commutative but NOT
-- associative, so the summation order below is part of the spec, not
-- an arbitrary stylistic choice. See c_src/lockstep/vector3.c for the
-- corresponding C implementation, and c_src/lockstep/cbmc_*.c for the
-- CBMC harnesses proving they match.
--
-- Run with: lean --run lean/LockstepDeterminism.lean
structure Vector3 where
  x : Float
  y : Float
  z : Float
deriving Repr

-- Fixed left-to-right evaluation order: (x*x' + y*y') + z*z'.
-- A C implementation that reassociates this (e.g. "z*z' + (x*x' + y*y')"
-- or lets the compiler reorder via -ffast-math/FMA contraction) is NOT
-- equivalent under IEEE 754 semantics in general, even though it is
-- mathematically equal over the reals -- see `nonAssociativityWitness`
-- below for a concrete case where this actually bites.
def Vector3.dot (a b : Vector3) : Float :=
  (a.x * b.x + a.y * b.y) + a.z * b.z

def testVectors : List (Vector3 × Vector3) := [
  (⟨1.0, 2.0, 3.0⟩, ⟨4.0, 5.0, 6.0⟩),
  (⟨0.1, 0.2, 0.3⟩, ⟨0.4, 0.5, 0.6⟩),
  (⟨-1.5, 2.25, -3.75⟩, ⟨7.125, -8.0625, 9.5⟩)
]

-- Concrete demonstration that (p+q)+r and p+(q+r) are NOT always
-- bit-identical for IEEE 754 doubles, even though they are equal over
-- the reals. This exact case is what verify_float_determinism.cpp
-- feeds to dot_ref/dot_good/dot_bad to compare native x86-64 execution
-- against RISC-V-via-libriscv execution.
def nonAssociativityWitness : IO Unit := do
  let p : Float := 1.0
  let q : Float := 1.0e16
  let r : Float := -1.0e16
  let left : Float := (p + q) + r
  let right : Float := p + (q + r)
  IO.println s!"(p+q)+r = {left}, p+(q+r) = {right}, equal = {left == right}"

def main : IO Unit := do
  for (a, b) in testVectors do
    let result := Vector3.dot a b
    IO.println s!"{a.x} {a.y} {a.z} · {b.x} {b.y} {b.z} = {result}"
  nonAssociativityWitness
