#Requires -Version 7
<#
.SYNOPSIS
Deploys versioned workflow JSON to a local n8n instance.

.DESCRIPTION
Idempotent upsert through the n8n Public API:
- resolves credentials by name from the n8n credential store and injects their ids
- creates or updates workflows by name (deactivate -> PUT -> activate, because
  the public API treats `active` as read-only and refuses updates while active)
- binds 02-error-handler as the error workflow of 01-lead-intake

Directories are scanned in the order given by -WorkflowDirs; a later directory
overrides a workflow with the same name, which is how local-only variants
(e.g. local/workflows) can replace a workflow without touching the repo copy.

Use -DryRun to inspect the credential mapping and target files without writing.
#>
[CmdletBinding()]
param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot),
    [string]$BaseUrl = 'http://localhost:5678/api/v1',
    [string[]]$WorkflowDirs = @('workflows'),
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$EnvFile = Join-Path $Root '.env'
$MainWorkflowName = '01-lead-intake'
$ErrorWorkflowName = '02-error-handler'

# credential type (node JSON key) -> credential name in the n8n store
$CredentialMap = [ordered]@{
    openAiApi      = 'leadflow-openai'
    httpHeaderAuth = 'leadflow-hubspot'
    slackApi       = 'leadflow-slack'
    googleApi       = 'leadflow-google-sheets'
}

function Read-DotEnv([string]$Path) {
    $map = @{}
    if (-not (Test-Path $Path)) { return $map }
    foreach ($line in Get-Content $Path) {
        if ($line -match '^\s*#' -or $line -match '^\s*$') { continue }
        if ($line -match '^\s*([A-Za-z0-9_]+)\s*=\s*(.*)$') {
            $value = $matches[2].Trim()
            if ($value -match '^"(.*)"$') { $value = $matches[1] }
            $map[$matches[1]] = $value
        }
    }
    return $map
}

$dotenv = Read-DotEnv $EnvFile
$apiKey = $dotenv['N8N_API_KEY']
if (-not $apiKey) {
    throw "N8N_API_KEY is not set in $EnvFile. Create a key in n8n (Settings -> n8n API) with workflows read/write and credentials read, then add it to .env. See reference/setup.md."
}

function Invoke-N8nApi {
    param([string]$Method, [string]$Path, $Body)
    $params = @{
        Method     = $Method
        Uri        = "$BaseUrl$Path"
        Headers    = @{ 'X-N8N-API-KEY' = $apiKey }
        TimeoutSec = 60
    }
    if ($null -ne $Body) {
        $params['ContentType'] = 'application/json; charset=utf-8'
        $params['Body'] = [System.Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 100))
    }
    elseif ($Method -in @('POST', 'PUT', 'PATCH')) {
        # n8n rejects body-less POSTs as form-urlencoded (415); always send JSON
        $params['ContentType'] = 'application/json; charset=utf-8'
        $params['Body'] = [System.Text.Encoding]::UTF8.GetBytes('{}')
    }
    try {
        Invoke-RestMethod @params
    }
    catch {
        $detail = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { '' }
        throw "n8n API $Method $Path failed: $($_.Exception.Message) $detail"
    }
}

# --- load workflow files (later directories override earlier ones by name) ---
$ordered = [ordered]@{}
foreach ($dir in $WorkflowDirs) {
    $path = Join-Path $Root $dir
    if (-not (Test-Path $path)) { Write-Host "Skip missing workflow dir: $dir"; continue }
    foreach ($file in @(Get-ChildItem -Path $path -Filter '*.json' -File | Sort-Object Name)) {
        $workflow = Get-Content -Raw -Path $file.FullName | ConvertFrom-Json
        if (-not $workflow.name) { throw "$($file.Name): missing 'name'" }
        if ($ordered.Contains($workflow.name)) { $ordered.Remove($workflow.name) }
        $ordered[$workflow.name] = [pscustomobject]@{ RelativePath = "$dir/$($file.Name)"; Workflow = $workflow }
        Write-Host ("Loaded {0} as '{1}' ({2} nodes)" -f "$dir/$($file.Name)", $workflow.name, @($workflow.nodes).Count)
    }
}
if ($ordered.Count -eq 0) {
    Write-Host 'No workflow files found - nothing to deploy.'
    return
}

# --- credentials required by exactly these files -----------------------------
$requiredTypes = @()
foreach ($entry in $ordered.Values) {
    foreach ($node in $entry.Workflow.nodes) {
        $credentialProp = $node.PSObject.Properties['credentials']
        if (-not $credentialProp -or -not $node.credentials) { continue }
        foreach ($type in @($node.credentials.PSObject.Properties.Name)) {
            if ($requiredTypes -notcontains $type) { $requiredTypes += $type }
        }
    }
}
$unknownTypes = @($requiredTypes | Where-Object { -not $CredentialMap.Contains($_) })
if ($unknownTypes.Count -gt 0) { throw "Unknown credential type(s) in workflows: $($unknownTypes -join ', ')" }

$requiredNames = @($requiredTypes | ForEach-Object { $CredentialMap[$_] } | Select-Object -Unique)
$credentialResponse = Invoke-N8nApi -Method GET -Path '/credentials?limit=250'
$credentialIdByName = @{}
foreach ($cred in $credentialResponse.data) { $credentialIdByName[$cred.name] = $cred.id }

$missing = @($requiredNames | Where-Object { -not $credentialIdByName.ContainsKey($_) })
if ($missing.Count -gt 0) {
    throw "Missing n8n credentials: $($missing -join ', '). Create them with these exact names first - see reference/setup.md."
}

Write-Host 'Credential mapping:'
foreach ($type in $requiredTypes) {
    Write-Host ("  {0,-15} -> {1} (id {2})" -f $type, $CredentialMap[$type], $credentialIdByName[$CredentialMap[$type]])
}

# --- payloads with injected credential ids -----------------------------------
$payloads = [ordered]@{}
foreach ($entry in $ordered.Values) {
    $workflow = $entry.Workflow
    foreach ($node in $workflow.nodes) {
        $credentialProp = $node.PSObject.Properties['credentials']
        if (-not $credentialProp -or -not $node.credentials) { continue }
        foreach ($type in @($node.credentials.PSObject.Properties.Name)) {
            $name = $CredentialMap[$type]
            $node.credentials.$type = [pscustomobject]@{ id = $credentialIdByName[$name]; name = $name }
        }
    }
    $settings = [pscustomobject]@{}
    if ($workflow.settings) { $settings = $workflow.settings }
    $payloads[$workflow.name] = [pscustomobject]@{
        name        = [string]$workflow.name
        nodes       = $workflow.nodes
        connections = $workflow.connections
        settings    = $settings
    }
}

if ($DryRun) {
    Write-Host ''
    Write-Host "Dry run - no changes written. Would upsert: $(@($payloads.Keys) -join ', ')"
    if ($payloads.Contains($MainWorkflowName) -and $payloads.Contains($ErrorWorkflowName)) {
        Write-Host "Would bind settings.errorWorkflow of '$MainWorkflowName' to '$ErrorWorkflowName' and activate both."
    }
    return
}

# --- upsert -------------------------------------------------------------------
$existing = Invoke-N8nApi -Method GET -Path '/workflows?limit=250'
$idByName = @{}
foreach ($wf in $existing.data) {
    if (-not $idByName.ContainsKey($wf.name)) { $idByName[$wf.name] = $wf.id }
}

function Upsert-Workflow($Payload) {
    if (-not $idByName.ContainsKey($Payload.name)) {
        $created = Invoke-N8nApi -Method POST -Path '/workflows' -Body $Payload
        $idByName[$Payload.name] = $created.id
        Write-Host "Created $($Payload.name) (id $($created.id))"
        return $created.id
    }
    $id = $idByName[$Payload.name]
    $current = Invoke-N8nApi -Method GET -Path "/workflows/$id"
    if ($current.active) {
        Invoke-N8nApi -Method POST -Path "/workflows/$id/deactivate" | Out-Null
    }
    Invoke-N8nApi -Method PUT -Path "/workflows/$id" -Body $Payload | Out-Null
    Write-Host "Updated $($Payload.name) (id $id)"
    return $id
}

foreach ($name in $payloads.Keys) {
    Upsert-Workflow $payloads[$name] | Out-Null
}

# --- activate error workflow before binding ----------------------------------
# n8n 2.x refuses to reference a workflow that has no published version, so the
# error handler must be activated first.
if ($idByName.ContainsKey($ErrorWorkflowName)) {
    Invoke-N8nApi -Method POST -Path "/workflows/$($idByName[$ErrorWorkflowName])/activate" | Out-Null
    Write-Host "Activated $ErrorWorkflowName"
}

# --- bind error workflow ------------------------------------------------------
if ($payloads.Contains($MainWorkflowName) -and $payloads.Contains($ErrorWorkflowName)) {
    $payload = $payloads[$MainWorkflowName]
    $settings = @{}
    if ($payload.settings) {
        foreach ($prop in $payload.settings.PSObject.Properties) { $settings[$prop.Name] = $prop.Value }
    }
    $settings['errorWorkflow'] = $idByName[$ErrorWorkflowName]
    $payload.settings = [pscustomobject]$settings
    Upsert-Workflow $payload | Out-Null
    Write-Host "Bound errorWorkflow -> $ErrorWorkflowName (id $($idByName[$ErrorWorkflowName]))"
}

# --- activate main workflow ---------------------------------------------------
if ($idByName.ContainsKey($MainWorkflowName)) {
    Invoke-N8nApi -Method POST -Path "/workflows/$($idByName[$MainWorkflowName])/activate" | Out-Null
    Write-Host "Activated $MainWorkflowName"
}

# --- verify -------------------------------------------------------------------
$final = (Invoke-N8nApi -Method GET -Path '/workflows?limit=250').data |
    Where-Object { $_.name -in @($MainWorkflowName, $ErrorWorkflowName) }
foreach ($wf in $final) {
    Write-Host ("State: {0} active={1}" -f $wf.name, $wf.active)
}
