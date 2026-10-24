-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 K. S. Ernest (iFire) Lee
--
-- RFD66606-0043's automatable enforcement of RFD66606-0042's "ongoing discipline"
-- requirement: disassemble a RISC-V guest ELF's .text section via this
-- org's own fire/lean-capstone (a Lean4 Capstone binding, reused rather
-- than shelling out to riscv-none-elf-objdump) and fail if any fused
-- multiply-add instruction is present. Source review cannot catch this
-- -- the compiler inserts FMA fusion silently, with no change to the C
-- source -- and neither does trusting that -ffp-contract=off was passed
-- correctly once; a future toolchain upgrade or an edited build script
-- can reintroduce it. See docs/decisions/0043-*.md for why this matters
-- (a real, confirmed cross-platform divergence, not a theoretical risk)
-- and scripts/check_no_fma.py for the objdump-based equivalent this
-- supersedes for anyone who'd rather not depend on this org's own Lean
-- tooling.
--
-- Usage: lake exe check_no_fma <elf-file> [<elf-file> ...]
import Capstone

open Capstone

-- RV64GC's fused multiply-add family (RVF/RVD extension), single- and
-- double-precision. https://github.com/riscv/riscv-isa-manual
def fmaMnemonics : List String :=
  ["fmadd.s", "fmsub.s", "fnmadd.s", "fnmsub.s",
   "fmadd.d", "fmsub.d", "fnmadd.d", "fnmsub.d"]

-- Minimal ELF64 reader: just enough to locate the `.text` section's
-- file offset/size by name, via the section header table and its
-- string table (SHT_STRTAB at e_shstrndx). No relocation, no symbol
-- resolution, no endianness other than little-endian (riscv-none-elf-gcc
-- output is always LE for RV64GC).
def readU16LE (b : ByteArray) (off : Nat) : UInt16 :=
  (b.get! off).toUInt16 ||| ((b.get! (off + 1)).toUInt16 <<< 8)

def readU32LE (b : ByteArray) (off : Nat) : UInt32 :=
  (b.get! off).toUInt32 ||| ((b.get! (off+1)).toUInt32 <<< 8) |||
  ((b.get! (off+2)).toUInt32 <<< 16) ||| ((b.get! (off+3)).toUInt32 <<< 24)

def readU64LE (b : ByteArray) (off : Nat) : UInt64 :=
  (readU32LE b off).toUInt64 ||| ((readU32LE b (off+4)).toUInt64 <<< 32)

structure Section where
  nameOff : UInt32
  offset  : UInt64
  size    : UInt64
  addr    : UInt64
  deriving Repr

def cstrAt (b : ByteArray) (off : Nat) : String := Id.run do
  let mut out := ""
  let mut i := off
  while i < b.size && b.get! i != 0 do
    out := out.push (Char.ofNat (b.get! i).toNat)
    i := i + 1
  pure out

-- Returns (fileOffset, size, loadAddr) of the `.text` section, or none.
def findTextSection (b : ByteArray) : Option (Nat × Nat × Nat) := Id.run do
  if b.size < 64 then return none
  if !(b.get! 0 == 0x7f && b.get! 1 == 'E'.toNat.toUInt8 &&
       b.get! 2 == 'L'.toNat.toUInt8 && b.get! 3 == 'F'.toNat.toUInt8) then
    return none
  let e_shoff := (readU64LE b 0x28).toNat
  let e_shentsize := (readU16LE b 0x3a).toNat
  let e_shnum := (readU16LE b 0x3c).toNat
  let e_shstrndx := (readU16LE b 0x3e).toNat
  if e_shnum == 0 then return none
  let strTabHdrOff := e_shoff + e_shstrndx * e_shentsize
  let strTabOff := (readU64LE b (strTabHdrOff + 0x18)).toNat
  let mut i := 0
  while i < e_shnum do
    let hdrOff := e_shoff + i * e_shentsize
    let nameOff := (readU32LE b hdrOff).toNat
    let name := cstrAt b (strTabOff + nameOff)
    if name == ".text" then
      let offset := (readU64LE b (hdrOff + 0x18)).toNat
      let size := (readU64LE b (hdrOff + 0x20)).toNat
      let addr := (readU64LE b (hdrOff + 0x10)).toNat
      return some (offset, size, addr)
    i := i + 1
  pure none

def checkFile (path : System.FilePath) : IO Bool := do
  let bytes ← IO.FS.readBinFile path
  match findTextSection bytes with
  | none =>
    IO.eprintln s!"{path}: could not locate .text section (not an ELF64, or malformed)"
    pure true -- treat "couldn't check" as a failure, not a silent pass
  | some (off, size, addr) =>
    let code := bytes.extract off (off + size)
    -- riscv64 alone isn't enough: riscv-none-elf-gcc's -march=rv64gc output
    -- uses both the compressed-instruction and float/double extensions,
    -- each needing its own cs_mode bit, or Capstone's RISC-V decoder can't
    -- decode F/D-extension instructions (fmadd.d and everything else this
    -- tool exists to find) and cs_disasm stops at the first instruction it
    -- can't decode, silently returning 0 instructions rather than an error
    -- -- found the hard way (see docs/decisions/0043-*.md), reported and
    -- fixed upstream as fire/lean-capstone#2, which is what
    -- Mode.riscvC/Mode.riscvFD below actually are.
    let mode := Mode.riscv64 ||| Mode.riscvC ||| Mode.riscvFD
    let insns := Capstone.disasm .riscv mode code addr
    let findings := insns.filter (fun i => fmaMnemonics.contains i.mnemonic)
    if findings.isEmpty then
      IO.println s!"{path}: OK (no FMA instructions found, {insns.size} instructions scanned)"
      pure false
    else
      IO.eprintln s!"{path}: found {findings.size} FMA instruction(s) (-ffp-contract=off is not being honored):"
      for f in findings do
        IO.eprintln s!"  0x{String.ofList (Nat.toDigits 16 f.addr)}: {f.mnemonic} {f.ops}"
      pure true

def main (args : List String) : IO UInt32 := do
  if args.isEmpty then
    IO.eprintln "usage: lake exe check_no_fma <elf-file> [<elf-file> ...]"
    return 2
  let mut hadFindings := false
  for arg in args do
    let failed ← checkFile arg
    hadFindings := hadFindings || failed
  return if hadFindings then 1 else 0
