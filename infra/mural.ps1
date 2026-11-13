param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('up', 'down', 'plan', 'load')]
    [string] $Action,
    [switch] $AutoApprove
)

$ErrorActionPreference = 'Stop'
$terraformDir = Join-Path $PSScriptRoot 'terraform'
$names = @('TF_VAR_postgres_password', 'TF_VAR_postgres_username', 'TF_VAR_postgres_database')
$previous = @{}
foreach ($name in $names) {
    $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

function Invoke-Terraform {
    param([string[]] $Arguments)
    & terraform "-chdir=$terraformDir" @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Terraform failed with exit code $LASTEXITCODE."
    }
}

try {
    Get-Command terraform -ErrorAction Stop | Out-Null
    if ($Action -eq 'load') {
        & (Join-Path $PSScriptRoot 'load-test.ps1')
        return
    }
    $dotenv = Join-Path (Split-Path -Parent $PSScriptRoot) '.env'
    if (Test-Path -LiteralPath $dotenv) {
        $config = ConvertFrom-StringData (Get-Content -LiteralPath $dotenv -Raw)
        foreach ($mapping in @{
            TF_VAR_postgres_password = 'POSTGRES_PASSWORD'
            TF_VAR_postgres_username = 'POSTGRES_USER'
            TF_VAR_postgres_database = 'POSTGRES_DB'
        }.GetEnumerator()) {
            if (-not [Environment]::GetEnvironmentVariable($mapping.Key, 'Process')) {
                [Environment]::SetEnvironmentVariable($mapping.Key, $config[$mapping.Value], 'Process')
            }
        }
    }
    if ($Action -eq 'up') {
        Invoke-Terraform @('init', '-input=false')
        Invoke-Terraform @('fmt', '-check')
        Invoke-Terraform @('validate')
        $arguments = @('apply')
    } elseif ($Action -eq 'down') {
        $arguments = @('destroy')
    } else {
        $arguments = @('plan')
    }
    if ($AutoApprove -and $Action -ne 'plan') {
        $arguments += '-auto-approve'
    }
    Invoke-Terraform $arguments
} finally {
    foreach ($name in $names) {
        if ($null -eq $previous[$name]) {
            Remove-Item -LiteralPath "Env:\$name" -ErrorAction SilentlyContinue
        } else {
            [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process')
        }
    }
}