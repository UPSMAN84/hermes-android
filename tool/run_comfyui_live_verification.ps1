<#
.SYNOPSIS
    Verifies the ComfyUI generation feature against a real ComfyUI server and
    a real Android device, and writes a redacted JSON evidence report.

.DESCRIPTION
    This is read/observe-only against ComfyUI: it validates connectivity and
    workflow node coverage, submits exactly one image prompt and one video
    prompt, polls history for their outputs, and records what actually
    happened. It never installs custom nodes or models, never edits ComfyUI
    configuration, and never reports a gate as passed without at least one
    output actually present in `/history/<prompt_id>`.

    The JSON report intentionally excludes prompts, workflow bodies, output
    filenames, credentials, and endpoint query strings -- only counts,
    hashes, and terminal status are recorded.

.PARAMETER BaseUrl
    The ComfyUI server's base URL, e.g. https://comfy.example.ts.net or
    http://192.168.1.20:8188. Must be an explicit http(s) URI.

.PARAMETER ImageWorkflow
    Absolute path to an API-format (not UI-format) ComfyUI workflow JSON
    file that renders an image.

.PARAMETER VideoWorkflow
    Absolute path to an API-format ComfyUI workflow JSON file that renders a
    video.

.PARAMETER DeviceId
    An explicit adb device serial (`adb devices` lists them). Every adb call
    this script makes passes this id explicitly -- it never falls back to
    "whichever device is attached".

.PARAMETER ReportPath
    Where to write the JSON evidence report. Defaults to
    build/comfyui-live-verification.json.

.EXAMPLE
    .\tool\run_comfyui_live_verification.ps1 `
        -BaseUrl https://comfy.example.ts.net `
        -ImageWorkflow C:\workflows\image_api.json `
        -VideoWorkflow C:\workflows\video_api.json `
        -DeviceId emulator-5554
#>
param(
    [Parameter(Mandatory)] [uri]$BaseUrl,
    [Parameter(Mandatory)] [string]$ImageWorkflow,
    [Parameter(Mandatory)] [string]$VideoWorkflow,
    [Parameter(Mandatory)] [string]$DeviceId,
    [string]$ReportPath = "build/comfyui-live-verification.json"
)

$ErrorActionPreference = "Stop"

function Invoke-Adb {
    param([Parameter(Mandatory)][string[]]$Arguments)
    & adb -s $DeviceId @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "adb -s $DeviceId $($Arguments -join ' ') exited $LASTEXITCODE"
    }
}

function Get-AdbProperty {
    param([Parameter(Mandatory)][string]$Property)
    (Invoke-Adb -Arguments @('shell', 'getprop', $Property)) | Select-Object -First 1
}

function Get-Sha256Hex {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        ($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
    } finally {
        $sha.Dispose()
    }
}

function New-GateResult {
    param(
        [Parameter(Mandatory)][string]$WorkflowPath,
        [Parameter(Mandatory)][hashtable]$ObjectInfo
    )

    if (-not (Test-Path -LiteralPath $WorkflowPath -PathType Leaf)) {
        throw "Workflow file not found: $WorkflowPath"
    }
    $resolved = (Resolve-Path -LiteralPath $WorkflowPath).ProviderPath
    if (-not [System.IO.Path]::IsPathRooted($resolved)) {
        throw "Workflow path must be absolute: $WorkflowPath"
    }

    $bytes = [System.IO.File]::ReadAllBytes($resolved)
    $workflowSha256 = Get-Sha256Hex -Bytes $bytes
    $workflow = Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json -AsHashtable

    $requiredClasses = New-Object System.Collections.Generic.HashSet[string]
    foreach ($node in $workflow.Values) {
        if ($node -is [hashtable] -and $node.ContainsKey('class_type')) {
            [void]$requiredClasses.Add([string]$node['class_type'])
        }
    }
    $missingClasses = @($requiredClasses | Where-Object { -not $ObjectInfo.ContainsKey($_) })

    $result = [ordered]@{
        workflowSha256    = $workflowSha256
        requiredNodeClasses = @($requiredClasses)
        missingNodeClasses  = $missingClasses
        schemaModelChoices  = @{}
        localJobId          = $null
        promptId             = $null
        terminalState         = 'not_run'
        outputTypeCounts     = @{}
        gateStatus           = 'not_run'
        gateError            = $null
    }

    if ($missingClasses.Count -gt 0) {
        $result.gateStatus = 'failed'
        $result.gateError = "Missing node classes on server: $($missingClasses -join ', ')"
        return $result
    }

    $clientId = [guid]::NewGuid().ToString('N')
    $submitBody = @{ prompt = $workflow; client_id = $clientId } | ConvertTo-Json -Depth 100
    try {
        $submitUri = [uri]::new($BaseUrl, 'prompt')
        $submitResponse = Invoke-RestMethod -Method Post -Uri $submitUri -Body $submitBody -ContentType 'application/json'
    } catch {
        $result.gateStatus = 'failed'
        $result.gateError = "Prompt submission failed: $($_.Exception.Message)"
        return $result
    }

    $promptId = $submitResponse.prompt_id
    if (-not $promptId) {
        $result.gateStatus = 'failed'
        $result.gateError = 'Prompt submission response had no prompt_id -- treated as not run, never as success.'
        return $result
    }
    $result.promptId = $promptId
    $result.localJobId = $clientId

    $historyUri = [uri]::new($BaseUrl, "history/$promptId")
    $deadline = (Get-Date).AddMinutes(10)
    $record = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        try {
            $history = Invoke-RestMethod -Method Get -Uri $historyUri
        } catch {
            continue
        }
        $entry = $history.$promptId
        if ($entry -and $entry.status -and $entry.status.completed) {
            $record = $entry
            break
        }
    }

    if ($null -eq $record) {
        $result.gateStatus = 'failed'
        $result.gateError = 'Timed out waiting for a completed history record.'
        $result.terminalState = 'timeout'
        return $result
    }

    $result.terminalState = $record.status.status_str
    $outputCounts = @{}
    $totalOutputs = 0
    foreach ($nodeOutput in $record.outputs.PSObject.Properties.Value) {
        foreach ($kind in $nodeOutput.PSObject.Properties) {
            if ($kind.Value -is [System.Collections.IEnumerable] -and $kind.Value -isnot [string]) {
                $count = @($kind.Value).Count
                if ($count -gt 0) {
                    $totalOutputs += $count
                    $outputCounts[$kind.Name] = ($outputCounts[$kind.Name] ?? 0) + $count
                }
            }
        }
    }
    $result.outputTypeCounts = $outputCounts

    if ($totalOutputs -lt 1) {
        $result.gateStatus = 'failed'
        $result.gateError = 'History reported completion with zero outputs -- never reported as success without a returned output.'
        return $result
    }

    $result.gateStatus = 'passed'
    return $result
}

# -- Validate inputs -----------------------------------------------------

if ($BaseUrl.Scheme -notin @('http', 'https')) {
    throw "BaseUrl must be http or https, got: $($BaseUrl.Scheme)"
}
foreach ($path in @($ImageWorkflow, $VideoWorkflow)) {
    if (-not [System.IO.Path]::IsPathRooted($path)) {
        throw "Workflow paths must be absolute: $path"
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Workflow file not found: $path"
    }
}
if (-not [System.IO.Path]::IsPathRooted($ReportPath)) {
    $ReportPath = Join-Path -Path (Get-Location) -ChildPath $ReportPath
}
$reportDir = Split-Path -Parent $ReportPath
if ($reportDir -and -not (Test-Path -LiteralPath $reportDir)) {
    New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
}

# -- Device evidence (read-only) -----------------------------------------

$deviceSerial = (Invoke-Adb -Arguments @('get-serialno')) | Select-Object -First 1
$deviceModel = Get-AdbProperty -Property 'ro.product.model'
$deviceSdk = Get-AdbProperty -Property 'ro.build.version.sdk'

# -- Connection + node-info evidence --------------------------------------

$statsUri = [uri]::new($BaseUrl, 'system_stats')
$systemStats = Invoke-RestMethod -Method Get -Uri $statsUri
$comfyVersion = $systemStats.system.comfyui_version
if (-not $comfyVersion) { $comfyVersion = $systemStats.system.version }

$objectInfoUri = [uri]::new($BaseUrl, 'object_info')
$objectInfoRaw = Invoke-WebRequest -Method Get -Uri $objectInfoUri
$objectInfoSha256 = Get-Sha256Hex -Bytes $objectInfoRaw.Content
$objectInfo = $objectInfoRaw.Content | ForEach-Object { [System.Text.Encoding]::UTF8.GetString($_) } | ConvertFrom-Json -AsHashtable

# Never leak the query string or credentials embedded in BaseUrl.
$endpointOrigin = "$($BaseUrl.Scheme)://$($BaseUrl.Authority)"

$report = [ordered]@{
    startedAtUtc     = (Get-Date).ToUniversalTime().ToString('o')
    endpointOrigin   = $endpointOrigin
    comfyVersion     = $comfyVersion
    objectInfoSha256 = $objectInfoSha256
    device           = [ordered]@{
        serial = $deviceSerial
        model  = $deviceModel
        sdk    = $deviceSdk
    }
    image = $null
    video = $null
}

Write-Host "Verifying image workflow..."
$report.image = New-GateResult -WorkflowPath $ImageWorkflow -ObjectInfo $objectInfo

Write-Host "Verifying video workflow..."
$report.video = New-GateResult -WorkflowPath $VideoWorkflow -ObjectInfo $objectInfo

$report | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $ReportPath -Encoding utf8

Write-Host "Report written to $ReportPath"
Write-Host "Image gate: $($report.image.gateStatus)"
Write-Host "Video gate: $($report.video.gateStatus)"

if ($report.image.gateStatus -ne 'passed' -or $report.video.gateStatus -ne 'passed') {
    exit 1
}
