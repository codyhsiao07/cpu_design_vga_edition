param(
  [int]$SeedStart = 1,
  [int]$SeedCount = 10,
  [string]$OutDir = "build_independent_system_verification",
  [string]$Iverilog = "iverilog",
  [string]$Vvp = "vvp",
  [string]$PythonExe = "python",
  [string]$ToolchainBin = "",
  [int]$MaxCycles = 350000
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot

$source = "TEST_FILES/prog_test29_independent_system_stress.c"
$mem = "TEST_FILES/mem_test29_independent_system_stress.mem"
$simExe = Join-Path $OutDir "simv"
$detDir = Join-Path $OutDir "deterministic"
$randDir = Join-Path $OutDir "random_stall"
$rv32BuildDir = Join-Path $OutDir "rv32_build"

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

Write-Host "[TEST29] Build independent stress MEM"
& (Join-Path $PSScriptRoot "build_mem_from_c.ps1") `
  -Source $source `
  -OutMem $mem `
  -BuildDir $rv32BuildDir `
  -ToolchainBin $ToolchainBin

if ($LASTEXITCODE -ne 0) {
  throw "test29 MEM build failed"
}

$regScript = Join-Path $PSScriptRoot "run_multiseed_regression.ps1"

Write-Host "[TEST29] Deterministic pipeline run"
& $regScript `
  -Tests 29 `
  -SeedStart 1 `
  -SeedCount 1 `
  -OutDir $detDir `
  -SimExe $simExe `
  -Iverilog $Iverilog `
  -Vvp $Vvp `
  -Compile 1 `
  -RandMem 0 `
  -AssertEn 1 `
  -MaxCycles $MaxCycles

if ($LASTEXITCODE -ne 0) {
  throw "test29 deterministic run failed"
}

Write-Host "[TEST29] Randomized memory-stall regression"
& $regScript `
  -Tests 29 `
  -SeedStart $SeedStart `
  -SeedCount $SeedCount `
  -OutDir $randDir `
  -SimExe $simExe `
  -Iverilog $Iverilog `
  -Vvp $Vvp `
  -Compile 0 `
  -RandMem 1 `
  -RandBpPct 20 `
  -RandIMax 9 `
  -RandDMax 9 `
  -AssertEn 1 `
  -MaxCycles $MaxCycles

if ($LASTEXITCODE -ne 0) {
  throw "test29 random-stall run failed"
}

$reportPath = Join-Path $OutDir "report.txt"
$report = @()
$report += "Independent System Verification"
$report += "source=$source"
$report += "mem=$mem"
$report += "deterministic_summary=$(Join-Path $detDir 'summary.txt')"
$report += "random_summary=$(Join-Path $randDir 'summary.txt')"
$report += "seed_start=$SeedStart"
$report += "seed_count=$SeedCount"
$report += "max_cycles=$MaxCycles"
$report | Set-Content -Path $reportPath

$report | ForEach-Object { Write-Host $_ }
exit 0
