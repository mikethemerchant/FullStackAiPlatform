<#
.SYNOPSIS
    Fetches Azure DevOps pipeline data and generates embeddings for the AI knowledge base.

.DESCRIPTION
    Connects to Azure DevOps REST API to retrieve pipeline runs, build logs, test results,
    and work item linkages. Parses the data into structured entries, generates vector
    embeddings via Ollama, and saves results to the knowledge base.

    Data collected per pipeline run:
    - Build result (succeeded, failed, canceled, partiallySucceeded)
    - Branch name and source version (commit SHA)
    - Timeline records (build steps with status, duration, error messages)
    - Test run results (if any)
    - Associated work items and commits

    Requires an Azure DevOps PAT stored in the environment variable specified
    in config.json (default: Stacker_DEVOPS_PAT).

.PARAMETER Force
    Forces a full re-fetch and re-index of all pipeline data.

.PARAMETER MaxRuns
    Maximum number of pipeline runs to fetch per pipeline definition. Default: 50.

.PARAMETER FailedOnly
    Only fetch failed or partially succeeded builds (useful for triage focus).

.EXAMPLE
    # Fetch all recent pipeline runs
    .\Fetch-DevOpsData.ps1

    # Force re-fetch everything
    .\Fetch-DevOpsData.ps1 -Force

    # Only fetch failures for triage
    .\Fetch-DevOpsData.ps1 -FailedOnly

    # Limit to last 10 runs
    .\Fetch-DevOpsData.ps1 -MaxRuns 10
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [int]$MaxRuns = 50,
    [switch]$FailedOnly
)

$ErrorActionPreference = "Stop"
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# Import shared utilities
Import-Module (Join-Path $PSScriptRoot "EmbeddingHelpers.psm1") -Force

# Load configuration
$config = Get-KBConfig
$storeName = "devops-pipelines"

$orgUrl = $config.indexing.devops.organization
$project = $config.indexing.devops.project
$repository = $config.indexing.devops.repository
$patEnvVar = $config.indexing.devops.patEnvironmentVariable
$branches = $config.indexing.devops.branches
$apiVersion = "api-version=7.0"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Stacker AI - Azure DevOps Data Fetcher" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Organization  : $orgUrl" -ForegroundColor Gray
Write-Host "  Project       : $project" -ForegroundColor Gray
Write-Host "  Repository    : $repository" -ForegroundColor Gray
Write-Host "  Branches      : $($branches -join ', ')" -ForegroundColor Gray
Write-Host "  Max runs      : $MaxRuns" -ForegroundColor Gray
Write-Host "  Mode          : $(if ($Force) { 'FULL (forced)' } elseif ($FailedOnly) { 'FAILED ONLY' } else { 'ALL RUNS' })" -ForegroundColor Gray
Write-Host ""

# ============================================================================
# STEP 1: Load .env file and validate PAT/connection
# ============================================================================

# Load .env file from repo root (contains Stacker_DEVOPS_PAT)
$envLoaded = Import-EnvFile
if ($envLoaded) {
    Write-Host "Step 1: Loaded .env file, validating connection..." -ForegroundColor Cyan
} else {
    Write-Host "Step 1: No .env file found, checking environment variables..." -ForegroundColor Cyan
}

Write-Host "Step 1: Validating Azure DevOps connection..." -ForegroundColor Cyan

$pat = [System.Environment]::GetEnvironmentVariable($patEnvVar)
if (-not $pat) {
    # Also check process-level env var
    $pat = [System.Environment]::GetEnvironmentVariable($patEnvVar, "Process")
}
if (-not $pat) {
    $pat = [System.Environment]::GetEnvironmentVariable($patEnvVar, "User")
}
if (-not $pat) {
    $pat = [System.Environment]::GetEnvironmentVariable($patEnvVar, "Machine")
}

if (-not $pat) {
    Write-Host "[FAIL] PAT not found in environment variable: $patEnvVar" -ForegroundColor Red
    Write-Host ""
    Write-Host "To set the PAT:" -ForegroundColor Yellow
    Write-Host "  # Current session only:" -ForegroundColor Gray
    Write-Host "  `$env:$patEnvVar = 'your-pat-here'" -ForegroundColor White
    Write-Host ""
    Write-Host "  # Permanent (machine-level):" -ForegroundColor Gray
    Write-Host "  [System.Environment]::SetEnvironmentVariable('$patEnvVar', 'your-pat-here', 'Machine')" -ForegroundColor White
    Write-Host ""
    Write-Host "PAT requires these scopes: Build (Read), Release (Read), Code (Read)" -ForegroundColor Yellow
    exit 1
}

# Build auth header
$tokenBytes = [System.Text.Encoding]::ASCII.GetBytes(":$pat")
$base64Token = [System.Convert]::ToBase64String($tokenBytes)
$headers = @{
    Authorization = "Basic $base64Token"
}

# Test connection
try {
    $projectUrl = "$orgUrl/_apis/projects/$project`?$apiVersion"
    $projectInfo = Invoke-RestMethod -Uri $projectUrl -Headers $headers -Method Get
    Write-Host "  [PASS] Connected to project: $($projectInfo.name)" -ForegroundColor Green
}
catch {
    Write-Host "  [FAIL] Could not connect to Azure DevOps: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  URL tested: $projectUrl" -ForegroundColor Gray
    exit 1
}

# ============================================================================
# HELPER: Invoke Azure DevOps REST API with error handling
# ============================================================================

function Invoke-DevOpsApi {
    param(
        [string]$Url,
        [hashtable]$Headers
    )

    try {
        $response = Invoke-RestMethod -Uri $Url -Headers $Headers -Method Get
        return $response
    }
    catch {
        Write-Warning "API call failed: $Url - $($_.Exception.Message)"
        return $null
    }
}

# ============================================================================
# STEP 2: Fetch pipeline definitions
# ============================================================================

Write-Host ""
Write-Host "Step 2: Fetching pipeline definitions..." -ForegroundColor Cyan

$pipelinesUrl = "$orgUrl/$project/_apis/build/definitions?$apiVersion"
$pipelinesDef = Invoke-DevOpsApi -Url $pipelinesUrl -Headers $headers

if (-not $pipelinesDef -or -not $pipelinesDef.value) {
    Write-Host "  [WARN] No pipeline definitions found." -ForegroundColor Yellow
    exit 0
}

$pipelineDefinitions = $pipelinesDef.value
Write-Host "  Found $($pipelineDefinitions.Count) pipeline definition(s):" -ForegroundColor Green
foreach ($pd in $pipelineDefinitions) {
    Write-Host "    - [$($pd.id)] $($pd.name)" -ForegroundColor Gray
}
Write-Host ""

# ============================================================================
# STEP 3: Fetch pipeline runs for each definition and branch
# ============================================================================

Write-Host "Step 3: Fetching pipeline runs..." -ForegroundColor Cyan
Write-Host ""

$allRunData = @()
$totalRuns = 0

foreach ($pipeline in $pipelineDefinitions) {
    foreach ($branch in $branches) {
        $branchFilter = "refs/heads/$branch"
        $resultFilter = ""
        if ($FailedOnly) {
            $resultFilter = "&resultFilter=failed,partiallySucceeded"
        }

        $runsUrl = "$orgUrl/$project/_apis/build/builds?definitions=$($pipeline.id)&branchName=$branchFilter&`$top=$MaxRuns$resultFilter&$apiVersion"
        $runsResponse = Invoke-DevOpsApi -Url $runsUrl -Headers $headers

        if (-not $runsResponse -or -not $runsResponse.value) {
            continue
        }

        $runs = $runsResponse.value
        Write-Host "  [$($pipeline.name)] branch: $branch - $($runs.Count) run(s)" -ForegroundColor White

        foreach ($run in $runs) {
            $runSummary = @{
                PipelineId       = $pipeline.id
                PipelineName     = $pipeline.name
                BuildId          = $run.id
                BuildNumber      = $run.buildNumber
                Status           = $run.status
                Result           = $run.result
                Branch           = $branch
                SourceVersion    = $run.sourceVersion
                RequestedBy      = $run.requestedBy.displayName
                StartTime        = $run.startTime
                FinishTime       = $run.finishTime
                Reason           = $run.reason
                Url              = $run._links.web.href
                FailedTasks      = @()
                TestResults      = @()
                AssociatedChanges = @()
            }

            # Fetch timeline (build steps) for failed/partial builds
            if ($run.result -in @("failed", "partiallySucceeded") -or $Force) {
                $timelineUrl = "$orgUrl/$project/_apis/build/builds/$($run.id)/timeline?$apiVersion"
                $timeline = Invoke-DevOpsApi -Url $timelineUrl -Headers $headers

                if ($timeline -and $timeline.records) {
                    $failedRecords = $timeline.records | Where-Object {
                        $_.result -eq "failed" -or $_.result -eq "succeededWithIssues"
                    }

                    foreach ($record in $failedRecords) {
                        $runSummary.FailedTasks += @{
                            Name     = $record.name
                            Type     = $record.type
                            Result   = $record.result
                            Duration = if ($record.startTime -and $record.finishTime) {
                                $start = [DateTime]::Parse($record.startTime)
                                $end = [DateTime]::Parse($record.finishTime)
                                ($end - $start).TotalSeconds
                            } else { 0 }
                            Issues   = if ($record.issues) {
                                ($record.issues | ForEach-Object { $_.message }) -join "; "
                            } else { "" }
                            Log      = if ($record.log) { $record.log.url } else { "" }
                        }
                    }
                }
            }

            # Fetch associated changes (commits)
            $changesUrl = "$orgUrl/$project/_apis/build/builds/$($run.id)/changes?$apiVersion"
            $changes = Invoke-DevOpsApi -Url $changesUrl -Headers $headers

            if ($changes -and $changes.value) {
                foreach ($change in $changes.value) {
                    $runSummary.AssociatedChanges += @{
                        CommitId = if ($change.id) { $change.id.Substring(0, [Math]::Min(8, $change.id.Length)) } else { "" }
                        Message  = $change.message
                        Author   = $change.author.displayName
                        Date     = $change.timestamp
                    }
                }
            }

            $allRunData += $runSummary
            $totalRuns++
        }
    }
}

Write-Host ""
Write-Host "  Total pipeline runs collected: $totalRuns" -ForegroundColor Green
Write-Host ""

if ($totalRuns -eq 0) {
    Write-Host "  [WARN] No pipeline runs found for configured branches." -ForegroundColor Yellow
    exit 0
}

# ============================================================================
# STEP 4: Build text summaries and generate embeddings
# ============================================================================

Write-Host "Step 4: Generating embeddings for pipeline data..." -ForegroundColor Cyan
Write-Host ""

$allEntries = @()
$totalChunks = 0
$errors = @()

# Load existing store for incremental skip (unless -Force)
$existingHashes = @{}
$existingEntries = @()
if (-not $Force) {
    $existingStore = Get-EmbeddingStore -StoreName "devops-pipelines"
    if ($existingStore -and $existingStore.entries) {
        $existingEntries = @($existingStore.entries)
        foreach ($entry in $existingEntries) {
            if ($entry.contentHash) {
                $existingHashes[$entry.contentHash] = $true
            }
        }
        Write-Host "  Loaded $($existingEntries.Count) existing entries for incremental check" -ForegroundColor DarkGray
    }
}

# Summary counts
$resultCounts = @{ succeeded = 0; failed = 0; partiallySucceeded = 0; canceled = 0; none = 0 }

foreach ($runData in $allRunData) {
    # Track result counts
    $resultKey = if ($runData.Result) { $runData.Result } else { "none" }
    if ($resultCounts.ContainsKey($resultKey)) {
        $resultCounts[$resultKey]++
    }

    # Build a human-readable summary of this pipeline run
    $summaryParts = @()
    $summaryParts += "Pipeline: $($runData.PipelineName) (Build #$($runData.BuildNumber))"
    $summaryParts += "Branch: $($runData.Branch) | Result: $($runData.Result) | Status: $($runData.Status)"
    $summaryParts += "Requested by: $($runData.RequestedBy) | Reason: $($runData.Reason)"

    if ($runData.StartTime) {
        $summaryParts += "Started: $($runData.StartTime)"
    }
    if ($runData.FinishTime) {
        $summaryParts += "Finished: $($runData.FinishTime)"
    }
    if ($runData.SourceVersion) {
        $summaryParts += "Commit: $($runData.SourceVersion)"
    }

    # Add failed tasks
    if ($runData.FailedTasks.Count -gt 0) {
        $summaryParts += ""
        $summaryParts += "Failed Tasks:"
        foreach ($task in $runData.FailedTasks) {
            $summaryParts += "  - $($task.Name) ($($task.Result)): $($task.Issues)"
        }
    }

    # Add associated changes
    if ($runData.AssociatedChanges.Count -gt 0) {
        $summaryParts += ""
        $summaryParts += "Associated Changes:"
        foreach ($change in $runData.AssociatedChanges) {
            $msg = if ($change.Message) { $change.Message -replace "`n", " " } else { "(no message)" }
            $summaryParts += "  - [$($change.CommitId)] $($change.Author): $msg"
        }
    }

    $summaryText = $summaryParts -join "`n"
    $chunkId = "devops:pipeline-$($runData.PipelineId):build-$($runData.BuildId)"
    $contentHash = Get-ContentHash -Content $summaryText

    # Skip if already indexed (incremental mode)
    if (-not $Force -and $existingHashes.ContainsKey($contentHash)) {
        Write-Host "  [SKIP] Build #$($runData.BuildNumber) ($($runData.Branch), $($runData.Result)) - already indexed" -ForegroundColor DarkGray
        # Keep existing entries for this hash
        foreach ($existing in $existingEntries) {
            if ($existing.contentHash -eq $contentHash) {
                $allEntries += $existing
                $totalChunks++
            }
        }
        continue
    }

    Write-Host "  [INDEX] Build #$($runData.BuildNumber) ($($runData.Branch), $($runData.Result))..." -ForegroundColor White -NoNewline

    # Chunk if summary is large (usually it fits in one chunk)
    $chunks = Split-TextIntoChunks -Text $summaryText -ChunkSize $config.embedding.chunkSize -Overlap $config.embedding.chunkOverlap

    $fileErrors = $false
    foreach ($chunk in $chunks) {
        $entryId = "$chunkId`:chunk-$($chunk.ChunkIndex)"

        $embedding = Get-Embedding -Text $chunk.Text

        if (-not $embedding) {
            Write-Host " [FAIL]" -ForegroundColor Red
            $errors += "Failed to generate embedding for $entryId"
            $fileErrors = $true
            continue
        }

        $allEntries += @{
            id          = $entryId
            filePath    = "azure-devops/$($runData.PipelineName)/build-$($runData.BuildId)"
            chunkIndex  = $chunk.ChunkIndex
            content     = $chunk.Text
            contentHash = $contentHash
            embedding   = $embedding
            metadata    = @{
                pipelineId   = $runData.PipelineId
                pipelineName = $runData.PipelineName
                buildId      = $runData.BuildId
                buildNumber  = $runData.BuildNumber
                branch       = $runData.Branch
                result       = $runData.Result
                status       = $runData.Status
                requestedBy  = $runData.RequestedBy
                startTime    = $runData.StartTime
                finishTime   = $runData.FinishTime
                sourceVersion = $runData.SourceVersion
                reason       = $runData.Reason
                url          = $runData.Url
                failedTaskCount = $runData.FailedTasks.Count
                changeCount  = $runData.AssociatedChanges.Count
                indexedAt    = (Get-Date).ToString("o")
            }
        }
        $totalChunks++
    }

    if (-not $fileErrors) {
        Write-Host " [DONE]" -ForegroundColor Green
    }
}

# ============================================================================
# STEP 5: Save embedding store
# ============================================================================

Write-Host ""
Write-Host "Step 5: Saving embedding store..." -ForegroundColor Cyan

if ($allEntries.Count -gt 0) {
    Save-EmbeddingStore -StoreName $storeName -Entries $allEntries
    Write-Host "  [PASS] Saved $($allEntries.Count) entries" -ForegroundColor Green
}
else {
    Write-Host "  [WARN] No entries to save" -ForegroundColor Yellow
}

# ============================================================================
# SUMMARY
# ============================================================================

$stopwatch.Stop()

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Fetch Complete" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Pipeline defs    : $($pipelineDefinitions.Count)" -ForegroundColor Gray
Write-Host "  Total runs       : $totalRuns" -ForegroundColor Gray
Write-Host "  Total chunks     : $totalChunks" -ForegroundColor Gray
Write-Host "  Total entries    : $($allEntries.Count)" -ForegroundColor Gray
Write-Host "  Duration         : $($stopwatch.Elapsed.ToString('mm\:ss'))" -ForegroundColor Gray
Write-Host ""
Write-Host "  Build results:" -ForegroundColor Gray
foreach ($key in @("succeeded", "failed", "partiallySucceeded", "canceled")) {
    if ($resultCounts[$key] -gt 0) {
        $color = switch ($key) {
            "succeeded"          { "Green" }
            "failed"             { "Red" }
            "partiallySucceeded" { "Yellow" }
            "canceled"           { "DarkGray" }
            default              { "White" }
        }
        Write-Host "    $key : $($resultCounts[$key])" -ForegroundColor $color
    }
}

if ($errors.Count -gt 0) {
    Write-Host ""
    Write-Host "  Errors ($($errors.Count)):" -ForegroundColor Red
    foreach ($err in $errors) {
        Write-Host "    - $err" -ForegroundColor Red
    }
    exit 1
}
else {
    Write-Host ""
    Write-Host "  Status           : [PASS] All pipeline data indexed successfully" -ForegroundColor Green
}
