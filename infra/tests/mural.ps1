$ErrorActionPreference = 'Stop'
$runner = Join-Path (Split-Path -Parent $PSScriptRoot) 'mural.ps1'
$names = @('TF_VAR_postgres_password', 'TF_VAR_postgres_username', 'TF_VAR_postgres_database')
$original = @{}
foreach ($name in $names) {
    $original[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$global:MuralTestCommands = [System.Collections.Generic.List[string]]::new()
$global:MuralTestFail = $false

function terraform {
    $global:MuralTestCommands.Add(($args -join ' '))
    $global:LASTEXITCODE = 0
    if ($global:MuralTestFail) {
        $global:LASTEXITCODE = 1
    }
}

try {
    foreach ($name in $names) {
        Remove-Item -LiteralPath "Env:\$name" -ErrorAction SilentlyContinue
    }
    & $runner up -AutoApprove
    if (($global:MuralTestCommands.Count -ne 4) -or $global:MuralTestCommands[-1] -notmatch 'apply -auto-approve') {
        throw 'Up must run init, fmt, validate and apply through Terraform.'
    }
    foreach ($name in $names) {
        if (Test-Path -LiteralPath "Env:\$name") {
            throw 'Runner must restore absent credential variables after success.'
        }
    }
    $env:TF_VAR_postgres_password = 'test-sentinel'
    $global:MuralTestFail = $true
    $rejected = $false
    try { & $runner down -AutoApprove } catch { $rejected = $true }
    if (-not $rejected -or $env:TF_VAR_postgres_password -ne 'test-sentinel') {
        throw 'Runner must propagate Terraform failure and preserve caller credentials.'
    }
    foreach ($name in @('TF_VAR_postgres_username', 'TF_VAR_postgres_database')) {
        if (Test-Path -LiteralPath "Env:\$name") {
            throw 'Runner must restore absent variables even after failure.'
        }
    }
    Write-Output 'PASS: up delegates to Terraform, approval is explicit, failures propagate, and credential environment is restored.'
} finally {
    Remove-Variable MuralTestCommands, MuralTestFail -Scope Global -ErrorAction SilentlyContinue
    foreach ($name in $names) {
        if ($null -eq $original[$name]) {
            Remove-Item -LiteralPath "Env:\$name" -ErrorAction SilentlyContinue
        } else {
            [Environment]::SetEnvironmentVariable($name, $original[$name], 'Process')
        }
    }
}