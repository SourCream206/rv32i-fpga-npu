param(
    [string]$ToolPrefix = "riscv32-unknown-elf"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$build = Join-Path $root "build"
$gcc = "$ToolPrefix-gcc"
$objcopy = "$ToolPrefix-objcopy"

if (-not (Get-Command $gcc -ErrorAction SilentlyContinue)) {
    throw "Missing RISC-V compiler: $gcc"
}
if (-not (Get-Command $objcopy -ErrorAction SilentlyContinue)) {
    throw "Missing RISC-V objcopy: $objcopy"
}

New-Item -ItemType Directory -Force -Path $build | Out-Null
$gccArgs = @(
    "-march=rv32i", "-mabi=ilp32", "-Os", "-ffreestanding", "-fno-builtin",
    "-nostdlib", "-nostartfiles", "-Wl,--gc-sections", "-Wl,-T,$PSScriptRoot\link.ld",
    "-o", "$build\npu_transformer.elf", "$PSScriptRoot\start.S", "$PSScriptRoot\npu_transformer.c"
)
& $gcc @gccArgs
& $objcopy "-O" "verilog" "$build\npu_transformer.elf" "$PSScriptRoot\imem.hex"
