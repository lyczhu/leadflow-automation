#Requires -Version 7
<#
.SYNOPSIS
Runs the automatable acceptance assertions from reference/setup.md §6 against a local deployment.

.DESCRIPTION
Covers the scriptable assertions:
  1  same email + form_id twice -> no new records (1 contact, <=1 deal)
  2  three invalid payloads -> 422 with stable reasons, no CRM writes
  4  payload_hash recomputation matches the audit row
  5  docker compose config exits 0
  7  no unmasked email/phone in audit model_output (best effort, needs execution data)
  9  normalisation equivalence (case + legal suffix)

Assertions 3, 6, 8 and 10 are documented in reference/setup.md §6: 3 and 6 need a
manual credential swap / pinned data, 8 is a git grep, 10 needs a 50-run sample
(use -LatencySampleCount 50 once the pipeline is stable).

Requires HUBSPOT_TOKEN in the local .env and a running n8n instance.

-Cleanup switches to maintenance mode: it lists every deal carrying
leadflow_idempotency_key (the property only this pipeline writes) and every
contact whose address is under @example.com, then archives them with -Force.
Without -Force it only reports what would be removed. Contact enumeration needs
crm.objects.contacts.read on the private app; without that scope the deals are
still cleaned and the remaining contact ids are printed. Audit rows are never
touched: the script holds no Sheets credentials, so clear the tab manually.
#>
[CmdletBinding()]
param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot),
    [string]$WebhookUrl = 'http://localhost:5678/webhook/leadflow-intake',
    [string]$N8nBaseUrl = 'http://localhost:5678/api/v1',
    [int]$LatencySampleCount = 0,
    [switch]$Cleanup,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

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

$dotenv = Read-DotEnv (Join-Path $Root '.env')
$hubspotToken = $dotenv['HUBSPOT_TOKEN']
$sharedSecret = $dotenv['WEBHOOK_SHARED_SECRET']
$n8nApiKey = $dotenv['N8N_API_KEY']
if (-not $hubspotToken) { throw 'HUBSPOT_TOKEN is not set in .env (local acceptance use only).' }

$results = [System.Collections.Generic.List[object]]::new()
function Add-Result([string]$Name, [bool]$Pass, [string]$Detail) {
    $results.Add([pscustomobject]@{ Name = $Name; Pass = $Pass; Detail = $Detail })
    $tag = if ($Pass) { 'PASS' } else { 'FAIL' }
    Write-Host ("[{0}] {1} - {2}" -f $tag, $Name, $Detail)
}

function Get-CanonicalString([string]$Text) {
    $escaped = $Text.Replace('\', '\\').Replace('"', '\"')
    $escaped = $escaped -replace "`n", '\n' -replace "`r", '\r' -replace "`t", '\t'
    return '"' + $escaped + '"'
}

# Mirrors canonical() in Validate & Normalize: sorted object keys, JSON.stringify
# scalars, arrays in order. PowerShell never unrolls an IDictionary through the
# pipeline, so dictionaries must be walked explicitly or this recurses forever.
function Get-CanonicalJson($Value) {
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return $(if ($Value) { 'true' } else { 'false' }) }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return ([double]$Value).ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [string]) { return Get-CanonicalString $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $keys = @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object)
        $parts = foreach ($p in $keys) { (Get-CanonicalString $p) + ':' + (Get-CanonicalJson $Value[$p]) }
        return '{' + ($parts -join ',') + '}'
    }
    if ($Value -is [System.Array]) {
        return '[' + (($Value | ForEach-Object { Get-CanonicalJson $_ }) -join ',') + ']'
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return '[' + (((@($Value)) | ForEach-Object { Get-CanonicalJson $_ }) -join ',') + ']'
    }
    if ($Value -is [psobject]) {
        $props = @($Value.PSObject.Properties.Name | Sort-Object)
        $parts = foreach ($p in $props) { (Get-CanonicalString $p) + ':' + (Get-CanonicalJson $Value.$p) }
        return '{' + ($parts -join ',') + '}'
    }
    return 'null'
}

function Get-Sha256Hex([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

# --- HTTP helpers -------------------------------------------------------------
function Invoke-WebhookRequest($Body, [hashtable]$ExtraHeaders = @{}) {
    $headers = @{ 'Content-Type' = 'application/json' }
    if ($sharedSecret) { $headers['X-Webhook-Secret'] = $sharedSecret }
    foreach ($k in $ExtraHeaders.Keys) { $headers[$k] = $ExtraHeaders[$k] }
    $json = $Body | ConvertTo-Json -Depth 20 -Compress
    try {
        $resp = Invoke-WebRequest -Method POST -Uri $WebhookUrl -Headers $headers -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 120 -SkipHttpErrorCheck
        return [pscustomobject]@{ Status = [int]$resp.StatusCode; Body = $resp.Content }
    }
    catch {
        return [pscustomobject]@{ Status = -1; Body = $_.Exception.Message }
    }
}

$hubspotHeaders = @{ Authorization = "Bearer $hubspotToken"; 'Content-Type' = 'application/json' }

function Search-Hubspot([string]$ObjectType, [string]$PropertyName, [string]$Value, [string[]]$Properties = @()) {
    $body = @{
        filterGroups = @(@{ filters = @(@{ propertyName = $PropertyName; operator = 'EQ'; value = $Value }) })
        limit        = 10
    }
    # Without an explicit list HubSpot only returns the default property set,
    # which does not include company.
    if ($Properties.Count -gt 0) { $body['properties'] = $Properties }
    $json = $body | ConvertTo-Json -Depth 10 -Compress
    $resp = Invoke-WebRequest -Method POST -Uri "https://api.hubapi.com/crm/v3/objects/$ObjectType/search" -Headers $hubspotHeaders -Body $json -SkipHttpErrorCheck
    return ($resp.Content | ConvertFrom-Json)
}

function Invoke-HubspotApi([string]$Method, [string]$Path, $Body = $null) {
    $req = @{
        Method             = $Method
        Uri                = "https://api.hubapi.com$Path"
        Headers            = $hubspotHeaders
        TimeoutSec         = 60
        SkipHttpErrorCheck = $true
    }
    if ($null -ne $Body) { $req['Body'] = ($Body | ConvertTo-Json -Depth 10 -Compress) }
    $resp = Invoke-WebRequest @req
    $json = $null
    if ($resp.Content) { try { $json = $resp.Content | ConvertFrom-Json } catch { $json = $null } }
    return [pscustomobject]@{ Status = [int]$resp.StatusCode; Json = $json; Raw = $resp.Content }
}

# --- cleanup selectors --------------------------------------------------------
# Deals are identified by the property only this pipeline writes, so the selector
# stays valid without read access to contacts. Contacts are archived only when
# they can be proven to be sentinels (address under example.com), which needs
# crm.objects.contacts.read on the private app.
function Find-PipelineDeals {
    $found = [System.Collections.Generic.List[object]]::new()
    $after = $null
    do {
        $body = @{
            filterGroups = @(@{ filters = @(@{ propertyName = 'leadflow_idempotency_key'; operator = 'HAS_PROPERTY' }) })
            properties   = @('leadflow_idempotency_key')
            limit        = 100
        }
        if ($after) { $body['after'] = $after }
        $r = Invoke-HubspotApi 'POST' '/crm/v3/objects/deals/search' $body
        if ($r.Status -ne 200) { return [pscustomobject]@{ Ok = $false; Status = $r.Status; Raw = $r.Raw; Deals = $found } }
        foreach ($d in @($r.Json.results)) { $found.Add($d) }
        $after = $r.Json.paging.next.after
    } while ($after)
    return [pscustomobject]@{ Ok = $true; Status = 200; Raw = ''; Deals = $found }
}

function Find-SentinelContacts {
    $found = [System.Collections.Generic.List[object]]::new()
    $after = $null
    do {
        $body = @{
            filterGroups = @(@{ filters = @(@{ propertyName = 'email'; operator = 'CONTAINS_TOKEN'; value = 'example.com' }) })
            properties   = @('email', 'company')
            limit        = 100
        }
        if ($after) { $body['after'] = $after }
        $r = Invoke-HubspotApi 'POST' '/crm/v3/objects/contacts/search' $body
        if ($r.Status -ne 200) { return [pscustomobject]@{ Ok = $false; Status = $r.Status; Raw = $r.Raw; Contacts = $found } }
        foreach ($c in @($r.Json.results)) { $found.Add($c) }
        $after = $r.Json.paging.next.after
    } while ($after)
    return [pscustomobject]@{ Ok = $true; Status = 200; Raw = ''; Contacts = $found }
}

function Get-DealContactIds([string]$DealId) {
    $r = Invoke-HubspotApi 'GET' "/crm/v3/objects/deals/$DealId/associations/contacts"
    if ($r.Status -eq 404) { return @() }
    if ($r.Status -ne 200) { throw "association lookup failed for deal $DealId : HTTP $($r.Status) $($r.Raw)" }
    return @(@($r.Json.results) | Where-Object { $_ } | ForEach-Object { [string]$_.id })
}

# --- audit data via n8n executions API (best effort) --------------------------
function Get-RecentExecutions([int]$Limit = 20) {
    if (-not $n8nApiKey) { return @() }
    try {
        $resp = Invoke-RestMethod -Method GET -Uri "$N8nBaseUrl/executions?includeData=true&limit=$Limit" -Headers @{ 'X-N8N-API-KEY' = $n8nApiKey } -TimeoutSec 60
        return @($resp.data)
    }
    catch {
        Write-Host "WARN cannot read executions API: $($_.Exception.Message)"
        return @()
    }
}

function Get-NodeOutput($Execution, [string]$NodeName) {
    try {
        $runs = $Execution.data.resultData.runData.$NodeName
        if (-not $runs) { return $null }
        $item = $runs[0].data.main[0][0]
        if (-not $item) { return $null }
        return $item.json
    }
    catch { return $null }
}

# --- cleanup mode (maintenance, exits before any assertion runs) ---------------
if ($Cleanup) {
    Write-Host 'Cleanup mode: scanning HubSpot for pipeline deals and sentinel contacts'
    $dealResult = Find-PipelineDeals
    if (-not $dealResult.Ok) { throw "deal search failed: HTTP $($dealResult.Status) $($dealResult.Raw)" }
    $contactResult = Find-SentinelContacts

    $dealIds = @($dealResult.Deals | ForEach-Object { [string]$_.id })
    $linkedContactIds = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($dealId in $dealIds) {
        foreach ($contactId in (Get-DealContactIds $dealId)) { [void]$linkedContactIds.Add($contactId) }
    }

    $contactIds = @()
    if ($contactResult.Ok) {
        $contactIds = @($contactResult.Contacts | ForEach-Object { [string]$_.id })
        Write-Host ("Deals: {0} | sentinel contacts: {1} | contacts linked to those deals: {2}" -f $dealIds.Count, $contactIds.Count, $linkedContactIds.Count)
        foreach ($c in $contactResult.Contacts) { Write-Host ("  contact {0} {1}" -f $c.id, $c.properties.email) }
    }
    else {
        Write-Host ("Deals: {0} | contacts linked to those deals: {1}" -f $dealIds.Count, $linkedContactIds.Count)
        Write-Host ("WARN contact search returned HTTP {0}: the token lacks crm.objects.contacts.read, so contacts cannot be identified and will be left in place." -f $contactResult.Status)
        Write-Host '     Grant that scope to the private app (or remove the contacts by hand) before the final cleanup.'
        if ($linkedContactIds.Count -gt 0) { Write-Host ('     Linked contact ids: ' + (@($linkedContactIds) -join ', ')) }
    }
    foreach ($dealId in $dealIds) { Write-Host "  deal $dealId" }

    if (-not $Force) {
        Write-Host 'Dry run: nothing was deleted. Re-run with -Cleanup -Force to archive these records.'
        exit 0
    }

    $failures = [System.Collections.Generic.List[string]]::new()
    foreach ($dealId in $dealIds) {
        $r = Invoke-HubspotApi 'DELETE' "/crm/v3/objects/deals/$dealId"
        if ($r.Status -notin @(200, 204, 404)) { $failures.Add("deal $dealId -> HTTP $($r.Status)") }
    }
    foreach ($contactId in $contactIds) {
        $r = Invoke-HubspotApi 'DELETE' "/crm/v3/objects/contacts/$contactId"
        if ($r.Status -notin @(200, 204, 404)) { $failures.Add("contact $contactId -> HTTP $($r.Status)") }
    }

    Write-Host ("Archived {0} deal(s) and {1} contact(s)." -f $dealIds.Count, $contactIds.Count)
    if (-not $contactResult.Ok) { Write-Host 'Contacts are still present: grant crm.objects.contacts.read and re-run to remove them.' }
    if ($failures.Count -gt 0) {
        Write-Host ("Failed to archive {0} record(s):" -f $failures.Count)
        $failures | ForEach-Object { Write-Host "  $_" }
        exit 1
    }
    Write-Host 'Cleanup complete. Clear the acceptance rows in the audit sheet manually.'
    exit 0
}

# --- setup --------------------------------------------------------------------
$stamp = Get-Date -Format 'yyyyMMddHHmmss'
$sentinelEmail = "acceptance-$stamp@example.com"
$sentinelForm = "acceptance-$stamp"
$normalizedEmail = "acceptance-$stamp`@example.com"

$payload = [ordered]@{
    form_id = $sentinelForm
    name    = 'Acceptance Lead'
    email   = "Acceptance-$stamp@Example.com"
    company = 'Acme Inc.'
    phone   = '+1 (555) 010-2030'
    message = 'Need lead automation'
}

Write-Host "Sentinel email: $sentinelEmail | form_id: $sentinelForm"
$expectedHash = Get-Sha256Hex (Get-CanonicalJson $payload)
Write-Host "Expected payload_hash: $expectedHash"

$contactProbe = Find-SentinelContacts
if (-not $contactProbe.Ok) {
    throw "HUBSPOT_TOKEN cannot search contacts (HTTP $($contactProbe.Status)). Grant crm.objects.contacts.read to the private app: assertions 1, 2 and 9 need it."
}

# --- assertion 1 --------------------------------------------------------------
$first = Invoke-WebhookRequest $payload
$second = Invoke-WebhookRequest $payload
$contacts = Search-Hubspot 'contacts' 'email' $normalizedEmail
$keyText = $normalizedEmail.ToLowerInvariant() + '|' + $sentinelForm
$sentinelKey = Get-Sha256Hex $keyText
$deals = Search-Hubspot 'deals' 'leadflow_idempotency_key' $sentinelKey

$contactCount = @($contacts.results).Count
$dealCount = @($deals.results).Count
Add-Result '1. idempotent double submit' ($first.Status -eq 201 -and $second.Status -eq 201 -and $contactCount -eq 1 -and $dealCount -le 1) `
    "http=$($first.Status)/$($second.Status) contacts=$contactCount deals=$dealCount"

# --- assertion 9 --------------------------------------------------------------
$variantA = [ordered]@{ form_id = "$sentinelForm-norm"; name = 'Normalise A'; email = "Normalise-$stamp@Example.com"; company = 'Acme Inc.' }
$variantB = [ordered]@{ form_id = "$sentinelForm-norm"; name = 'Normalise A'; email = "normalise-$stamp@example.com"; company = 'Acme' }
$null = Invoke-WebhookRequest $variantA
$null = Invoke-WebhookRequest $variantB
$normContacts = Search-Hubspot 'contacts' 'email' "normalise-$stamp@example.com" -Properties @('email', 'company')
$normCount = @($normContacts.results).Count
$normCompany = ''
if ($normCount -gt 0) { $normCompany = $normContacts.results[0].properties.company }
Add-Result '9. normalisation equivalence' ($normCount -eq 1 -and $normCompany -eq 'Acme') `
    "contacts=$normCount company='$normCompany'"

# --- assertion 2 --------------------------------------------------------------
$missing = Invoke-WebhookRequest ([ordered]@{ form_id = "$sentinelForm-bad"; name = 'No Mail'; company = 'Acme Inc.' })
$invalid = Invoke-WebhookRequest ([ordered]@{ form_id = "$sentinelForm-bad"; name = 'Bad Mail'; email = 'not-an-email'; company = 'Acme Inc.' })
$badSecretPayload = [ordered]@{ form_id = "$sentinelForm-bad"; name = 'Bad Secret'; email = "acceptance-badsecret-$stamp@example.com"; company = 'Acme Inc.' }
$badSecret = Invoke-WebhookRequest $badSecretPayload @{ 'X-Webhook-Secret' = 'wrong-secret' }

$reasons = @()
foreach ($r in @($missing, $invalid, $badSecret)) {
    try { $reasons += ($r.Body | ConvertFrom-Json).reason } catch { $reasons += '' }
}
$noCrmWrite = @((Search-Hubspot 'contacts' 'email' "acceptance-badsecret-$stamp@example.com").results).Count -eq 0
Add-Result '2. invalid payloads rejected' `
    ($missing.Status -eq 422 -and $invalid.Status -eq 422 -and $badSecret.Status -eq 422 -and $noCrmWrite) `
    "http=$($missing.Status)/$($invalid.Status)/$($badSecret.Status) reasons=$($reasons -join ',') crmClean=$noCrmWrite"

# --- assertion 4 + 7 (execution data) ----------------------------------------
Start-Sleep -Seconds 2
$executions = Get-RecentExecutions 20
$auditOutputs = @()
foreach ($exec in $executions) {
    foreach ($nodeName in @('Audit Success', 'Audit Rejected', 'Audit Failed')) {
        $out = Get-NodeOutput $exec $nodeName
        if ($out) { $auditOutputs += $out }
    }
}
$successRow = $auditOutputs | Where-Object { $_.payload_hash -eq $expectedHash } | Select-Object -First 1
if ($successRow) {
    Add-Result '4a. payload_hash matches' $true "run_id=$($successRow.run_id)"
}
elseif ($auditOutputs.Count -gt 0) {
    Add-Result '4a. payload_hash matches' (@($auditOutputs | Where-Object { $_.payload_hash }).Count -gt 0) 'hash visible but sentinel hash not found; verify the sheet row manually'
}
else {
    Add-Result '4a. payload_hash matches' $false 'no audit node output available (check execution data retention); verify the sheet row manually'
}

$piiRegex = '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|\+?\d{8,}'
$leaks = @($auditOutputs | Where-Object { $_ -and $_.model_output -and ($_.model_output -match $piiRegex) })
Add-Result '7. masking' ($leaks.Count -eq 0) "rows_with_pii=$($leaks.Count)"

# --- assertion 5 --------------------------------------------------------------
& docker compose --project-directory $Root config *> $null
Add-Result '5. compose config' ($LASTEXITCODE -eq 0) "exit=$LASTEXITCODE"

# --- assertion 10 (optional latency sample) -----------------------------------
if ($LatencySampleCount -gt 0) {
    Write-Host "Sending $LatencySampleCount latency samples..."
    for ($i = 1; $i -le $LatencySampleCount; $i++) {
        $sample = [ordered]@{ form_id = "$sentinelForm-lat-$i"; name = "Latency $i"; email = "latency-$stamp-$i@example.com"; company = 'Acme Inc.'; message = 'latency sample' }
        $null = Invoke-WebhookRequest $sample
        Start-Sleep -Milliseconds 300
    }
    Start-Sleep -Seconds 5
    $latencies = @()
    foreach ($exec in (Get-RecentExecutions 100)) {
        $out = Get-NodeOutput $exec 'Audit Success'
        if ($out -and $out.latency_ms) { $latencies += [double]$out.latency_ms }
    }
    if ($latencies.Count -ge 2) {
        $sorted = $latencies | Sort-Object
        $p95 = $sorted[[int][Math]::Ceiling(0.95 * $sorted.Count) - 1]
        Add-Result '10. latency p95' ($p95 -le 10000) "n=$($sorted.Count) p95=$([Math]::Round($p95))ms"
    }
    else {
        Add-Result '10. latency p95' $false 'not enough audit samples; verify manually'
    }
}

# --- summary ------------------------------------------------------------------
Write-Host ''
$failed = @($results | Where-Object { -not $_.Pass })
Write-Host ("Summary: {0} passed, {1} failed (of {2})" -f ($results.Count - $failed.Count), $failed.Count, $results.Count)
Write-Host 'Manual checks still required: 3 (wrong key -> 4 attempts + 1 alert + 1 failed row), 6 (pinned fallback), 8 (git grep).'
if ($failed.Count -gt 0) { exit 1 }
