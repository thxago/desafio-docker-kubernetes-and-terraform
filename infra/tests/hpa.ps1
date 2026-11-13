$ErrorActionPreference = 'Stop'
Get-Command helm -ErrorAction Stop | Out-Null
$chart = Join-Path (Split-Path -Parent $PSScriptRoot) 'helm\mural'
$base = @('template', 'mural', $chart, '--set', 'postgres.existingSecret=test-secret')

$fixed = (& helm @base) -join "`n"
if ($LASTEXITCODE -ne 0 -or $fixed -match 'kind: HorizontalPodAutoscaler' -or
    $fixed -notmatch '(?s)kind: Deployment.*?name: mural-api.*?spec:\s+replicas: 2') {
    throw 'Disabled autoscaling must preserve the fixed-replica deployment and omit HPA.'
}

$scaled = (& helm @base --set api.autoscaling.enabled=true --set api.autoscaling.minReplicas=1 --set api.autoscaling.maxReplicas=4 --set api.autoscaling.targetCPUUtilizationPercentage=40) -join "`n"
if ($LASTEXITCODE -ne 0 -or $scaled -notmatch 'kind: HorizontalPodAutoscaler' -or
    $scaled -notmatch 'minReplicas: 1' -or $scaled -notmatch 'maxReplicas: 4' -or
    $scaled -notmatch 'averageUtilization: 40') {
    throw 'Enabled autoscaling must render the requested scaling policy.'
}
$api = (& helm @base --set api.autoscaling.enabled=true --show-only templates/api.yaml) -join "`n"
if ($LASTEXITCODE -ne 0 -or $api -match '(?m)^  replicas:') {
    throw 'The API Deployment must leave replica ownership to HPA.'
}

foreach ($invalid in @('api.autoscaling.maxReplicas=1', 'api.autoscaling.targetCPUUtilizationPercentage=0')) {
    & helm @base --set api.autoscaling.enabled=true --set $invalid 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        throw "Invalid autoscaling policy was accepted: $invalid"
    }
}
Write-Output 'PASS: fixed replicas preserved, HPA policy parametrized, replica ownership delegated, and invalid policies rejected.'