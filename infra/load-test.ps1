param(
    [ValidateRange(60, 600)]
    [int] $DurationSeconds = 180,
    [ValidateRange(1, 200)]
    [int] $Vus = 40
)

$ErrorActionPreference = 'Stop'
Get-Command terraform, kubectl, k6 -ErrorAction Stop | Out-Null
$terraformDir = Join-Path $PSScriptRoot 'terraform'
$outputs = & terraform "-chdir=$terraformDir" output -json
if ($LASTEXITCODE -ne 0) {
    throw 'Could not read Terraform outputs.'
}
$outputs = $outputs | ConvertFrom-Json
$kubeconfig = $outputs.kubeconfig_path.value
$url = $outputs.url.value
$evidenceDir = Join-Path $PSScriptRoot '.evidence'
New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null
$runId = [guid]::NewGuid().ToString('N')
$summaryFile = Join-Path $evidenceDir "$runId-k6.json"
$stdoutFile = Join-Path $evidenceDir "$runId-k6.log"
$stderrFile = Join-Path $evidenceDir "$runId-k6-errors.log"
$reportFile = Join-Path $evidenceDir "$runId-hpa.json"

function Get-Hpa {
    $value = & kubectl --kubeconfig $kubeconfig -n mural get hpa mural-api -o json
    if ($LASTEXITCODE -ne 0) {
        throw 'API HPA is unavailable. Enable autoscaling and run Terraform apply first.'
    }
    $value | ConvertFrom-Json
}

function Get-Deployment {
    $value = & kubectl --kubeconfig $kubeconfig -n mural get deployment mural-api -o json
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not read API deployment.'
    }
    $value | ConvertFrom-Json
}

$deadline = [DateTime]::UtcNow.AddSeconds(180)
do {
    $hpa = Get-Hpa
    $active = $hpa.status.conditions | Where-Object { $_.type -eq 'ScalingActive' -and $_.status -eq 'True' }
    if ($active -and $hpa.status.currentMetrics.Count -gt 0 -and (Get-Deployment).status.readyReplicas -ge $hpa.spec.minReplicas) {
        break
    }
    Start-Sleep -Seconds 5
} while ([DateTime]::UtcNow -lt $deadline)
if (-not $active) {
    throw 'HPA did not receive CPU metrics within 180 seconds.'
}
$initial = (Get-Deployment).status.readyReplicas
if ($initial -lt $hpa.spec.minReplicas -or $initial -ge $hpa.spec.maxReplicas) {
    throw 'Start with Ready API replicas below maxReplicas; wait for previous load to subside.'
}
$samples = [System.Collections.Generic.List[object]]::new()
$names = @('BASE_URL', 'DURATION', 'VUS')
$previous = @{}
foreach ($name in $names) {
    $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$process = $null
try {
    $env:BASE_URL = $url
    $env:DURATION = "${DurationSeconds}s"
    $env:VUS = "$Vus"
    $k6 = (Get-Command k6).Source
    $script = Join-Path $PSScriptRoot 'load\api.js'
    $process = Start-Process -FilePath $k6 -ArgumentList @(
        'run', '--summary-export', "`"$summaryFile`"", "`"$script`""
    ) -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile -NoNewWindow -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds($DurationSeconds + 60)
    do {
        $hpa = Get-Hpa
        $deployment = Get-Deployment
        $metric = $hpa.status.currentMetrics | Where-Object { $_.resource.name -eq 'cpu' } | Select-Object -First 1
        $sample = [PSCustomObject]@{
            timestamp = [DateTime]::UtcNow.ToString('o')
            current = $hpa.status.currentReplicas
            desired = $hpa.status.desiredReplicas
            ready = [int] $deployment.status.readyReplicas
            cpuUtilization = $metric.resource.current.averageUtilization
        }
        $samples.Add($sample)
        Write-Output "HPA current=$($sample.current) desired=$($sample.desired) ready=$($sample.ready) CPU=$($sample.cpuUtilization)%"
        Start-Sleep -Seconds 5
        $process.Refresh()
    } while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline)
    if (-not $process.HasExited) {
        throw 'k6 exceeded the bounded load-test deadline.'
    }
    $process.WaitForExit()
    $exitCode = $process.ExitCode
    $maxReady = ($samples | Measure-Object -Property ready -Maximum).Maximum
    @{
        url = $url
        durationSeconds = $DurationSeconds
        vus = $Vus
        initialReadyReplicas = $initial
        maxReadyReplicas = $maxReady
        k6ExitCode = $exitCode
        samples = $samples.ToArray()
        summaryFile = (Split-Path -Leaf $summaryFile)
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportFile -Encoding utf8
    if ($exitCode -ne 0) {
        throw "k6 failed its checks/thresholds. See $stdoutFile and $stderrFile."
    }
    if ($maxReady -le $initial) {
        throw "No increase in Ready API replicas observed. Evidence: $reportFile"
    }
    Write-Output "API scaled from $initial to $maxReady Ready replicas. Evidence: $reportFile"
} finally {
    if ($process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -ErrorAction SilentlyContinue
    }
    foreach ($name in $names) {
        if ($null -eq $previous[$name]) {
            Remove-Item -LiteralPath "Env:\$name" -ErrorAction SilentlyContinue
        } else {
            [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process')
        }
    }
}