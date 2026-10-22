param(
    [string]$ToolPrefix = "riscv32-unknown-elf",
    [string]$Python = "python",
    [switch]$Trace
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
if (-not (Get-Command $Python -ErrorAction SilentlyContinue)) {
    throw "Missing Python: $Python"
}

New-Item -ItemType Directory -Force -Path $build | Out-Null
$gccArgs = @(
    "-march=rv32i", "-mabi=ilp32", "-Os", "-ffreestanding", "-fno-builtin",
    "-nostdlib", "-nostartfiles", "-Wl,--gc-sections", "-Wl,-T,$PSScriptRoot\link.ld",
    "-o", "$build\npu_transformer.elf", "$PSScriptRoot\start.S", "$PSScriptRoot\npu_transformer.c", "-lgcc"
)
if ($Trace) { $gccArgs += "-DNPU_TRACE" }
& $gcc @gccArgs
if ($LASTEXITCODE -ne 0) { throw "Firmware compile/link failed" }
& $objcopy "-O" "binary" "$build\npu_transformer.elf" "$build\npu_transformer.bin"
if ($LASTEXITCODE -ne 0) { throw "Firmware binary export failed" }
& $Python "$root\scripts\bin_to_imem.py" "$build\npu_transformer.bin" "$PSScriptRoot\imem.hex"
if ($LASTEXITCODE -ne 0) { throw "Instruction ROM conversion failed" }
