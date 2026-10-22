param(
    [string]$ToolPrefix = "riscv32-unknown-elf",
    [string]$QuestaBin = "",
    [string]$Python = "python",
    [switch]$Trace
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$build = Join-Path $root "build"
New-Item -ItemType Directory -Force -Path $build | Out-Null

function Invoke-Checked([string]$Name, [scriptblock]$Action) {
    & $Action
    if ($LASTEXITCODE -ne 0) { throw "$Name failed ($LASTEXITCODE)" }
}

$vlib = if ($QuestaBin) { Join-Path $QuestaBin "vlib.exe" } else { "vlib" }
$vlog = if ($QuestaBin) { Join-Path $QuestaBin "vlog.exe" } else { "vlog" }
$vsim = if ($QuestaBin) { Join-Path $QuestaBin "vsim.exe" } else { "vsim" }

Invoke-Checked "fixed-point reference" { & $Python python/quantized_transformer.py --output build/reference.json | Out-Null }
Invoke-Checked "firmware build" { & ./software/build.ps1 -ToolPrefix $ToolPrefix -Python $Python }
if (-not (Test-Path build/questa_work/_info)) {
    Invoke-Checked "Questa library" { & $vlib build/questa_work }
}
Invoke-Checked "RTL compilation" {
    & $vlog -sv -work build/questa_work rtl/mac_array_4x4.sv rtl/npu_peripheral.sv `
        rtl/soc/riscv_core.v rtl/soc/imem.v rtl/soc/dmem.v rtl/soc/riscv_soc.v `
        tb/tb_mac_array_4x4.sv tb/tb_npu_peripheral.sv tb/tb_soc_npu.sv | Out-Null
}

function Run-Test([string]$Top, [string]$Pass) {
    $log = "build/$Top.log"
    & $vsim -c -lib build/questa_work $Top -l $log -do 'run -all; quit -f' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "$Top simulator process failed" }
    $report = Get-Content $log -Raw
    if (-not $report.Contains($Pass) -or $report.Contains('** Fatal:') -or $report -match 'Errors: [1-9]') {
        throw "$Top did not pass; inspect $log"
    }
    Write-Host "PASS: $Top"
}

Run-Test tb_mac_array_4x4 'PASS: mac_array_4x4'
Run-Test tb_npu_peripheral 'PASS: 16x16 tiled NPU projection and softmax'
Run-Test tb_soc_npu 'PASS: RV32I firmware completed NPU orchestration, token=37'

if ($Trace) {
    try {
        Invoke-Checked "trace firmware build" { & ./software/build.ps1 -ToolPrefix $ToolPrefix -Python $Python -Trace }
        Run-Test tb_soc_npu 'PASS: RV32I firmware completed NPU orchestration, token=37'
        Invoke-Checked "layer comparison" { & $Python scripts/check_trace.py build/tb_soc_npu.log }
    } finally {
        Invoke-Checked "restore normal firmware" { & ./software/build.ps1 -ToolPrefix $ToolPrefix -Python $Python }
    }
}
