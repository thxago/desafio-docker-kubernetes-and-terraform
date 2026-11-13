param(
    [Parameter(Mandatory)]
    [ValidateSet('Build', 'Load', 'Remove', 'Wait')]
    [string] $Action
)

$ErrorActionPreference = 'Stop'
$config = $env:MURAL_CONFIG | ConvertFrom-Json

function Invoke-Native {
    param([string] $Program, [string[]] $Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Program failed with exit code $LASTEXITCODE."
    }
}

if ($Action -eq 'Build') {
    Get-Command docker, kind, pwsh -ErrorAction Stop | Out-Null
    $drive = Get-PSDrive -Name ([IO.Path]::GetPathRoot($config.root).TrimEnd('\').TrimEnd(':'))
    if ($drive.Free -lt 5GB) {
        throw 'At least 5 GiB of free disk space is required before provisioning.'
    }
    Invoke-Native docker @('info', '--format', '{{.ServerVersion}}')
    $runtime = Split-Path -Parent $config.kubeconfig
    New-Item -ItemType Directory -Path $runtime -Force | Out-Null
    foreach ($item in @(@('api', $config.api), @('web', $config.web))) {
        $image = $item[1]
        $existing = & docker image inspect $image 2>$null
        if ($LASTEXITCODE -eq 0) {
            $owner = ($existing | ConvertFrom-Json)[0].Config.Labels.'mural.terraform.owner'
            if ($owner -ne $config.cluster) {
                throw "Image tag $image already exists and is not owned by this cluster."
            }
        }
        Invoke-Native docker @(
            'build', '--quiet', '--platform', $config.platform,
            '--label', "mural.terraform.owner=$($config.cluster)",
            '--file', (Join-Path $config.root "app\docker\$($item[0]).Dockerfile"),
            '--tag', $image, $config.root
        )
    }
    foreach ($image in @($config.postgres, $config.traefik, $config.node)) {
        Invoke-Native docker @('pull', '--quiet', '--platform', $config.platform, $image)
    }
}

if ($Action -eq 'Load') {
    $archive = Join-Path ([IO.Path]::GetTempPath()) "mural-$($config.cluster)-$([guid]::NewGuid()).tar"
    try {
        Invoke-Native docker @(
            'image', 'save', '--platform', $config.platform, '--output', $archive,
            $config.api, $config.web, $config.postgres, $config.traefik
        )
        Invoke-Native kind @('load', 'image-archive', $archive, '--name', $config.cluster)
    } finally {
        if (Test-Path -LiteralPath $archive) {
            Remove-Item -LiteralPath $archive
        }
    }
}

if ($Action -eq 'Remove') {
    foreach ($image in @($config.api, $config.web)) {
        $existing = & docker image inspect $image 2>$null
        if ($LASTEXITCODE -eq 0) {
            $owner = ($existing | ConvertFrom-Json)[0].Config.Labels.'mural.terraform.owner'
            if ($owner -ne $config.cluster) {
                throw "Refusing to remove image $image owned by another project."
            }
            Invoke-Native docker @('image', 'rm', $image)
        }
    }
    $nodes = & docker ps --all --filter "label=io.x-k8s.kind.cluster=$($config.cluster)" --format '{{.Names}}'
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not verify cluster deletion; kubeconfig has been preserved.'
    }
    if (@($nodes).Count -eq 0) {
        if (Test-Path -LiteralPath $config.kubeconfig) {
            Remove-Item -LiteralPath $config.kubeconfig
        }
        $runtime = Split-Path -Parent $config.kubeconfig
        if ((Test-Path -LiteralPath $runtime) -and @(Get-ChildItem -LiteralPath $runtime -Force).Count -eq 0) {
            Remove-Item -LiteralPath $runtime
        }
    }
}

if ($Action -eq 'Wait') {
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.UseProxy = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(5)
    $client.DefaultRequestHeaders.Host = $config.host
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(120)
        do {
            try {
                $front = $client.GetAsync("http://127.0.0.1:$($config.port)/").GetAwaiter().GetResult()
                $api = $client.GetAsync("http://127.0.0.1:$($config.port)/api/messages").GetAwaiter().GetResult()
                if ($front.IsSuccessStatusCode -and $api.IsSuccessStatusCode) {
                    $html = $front.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                    $messages = $api.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                    $messages | ConvertFrom-Json | Out-Null
                    if ($html -match 'id="root"') {
                        Write-Output 'Ingress is serving the Mural frontend and API.'
                        return
                    }
                }
            } catch {
                Write-Verbose $_
            }
            Start-Sleep -Seconds 2
        } while ([DateTime]::UtcNow -lt $deadline)
        throw 'Ingress did not serve the frontend and API within 120 seconds.'
    } finally {
        $client.Dispose()
        $handler.Dispose()
    }
}