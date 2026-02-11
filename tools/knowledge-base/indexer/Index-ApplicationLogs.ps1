<#
.SYNOPSIS
    Indexes application log files and generates embeddings for the AI knowledge base.

.DESCRIPTION
    Scans the configured log directory for Serilog structured log files (Stacker-*.log).
    Parses each log line to extract timestamp, level, message, and structured properties
    (correlation IDs, source context, machine name, etc.). Groups log entries into
    logical chunks (e.g., by application session or time window), generates vector
    embeddings, and saves results to the knowledge base.

    Retention policy: Only indexes logs from the last 90 days (configurable).
    Older log embeddings are automatically purged on each run.

.PARAMETER Force
    Forces a full re-index of all log files within retention period.

.PARAMETER Incremental
    Only indexes log files that have changed since the last run (default behavior).

.PARAMETER RetentionDays
    Override the retention period (default: from config.json, typically 90 days).

.EXAMPLE
    # Full index of all logs within retention
    .\Index-ApplicationLogs.ps1 -Force

    # Incremental update
    .\Index-ApplicationLogs.ps1

    # Custom retention period
    .\Index-ApplicationLogs.ps1 -RetentionDays 30
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$Incremental,
    [int]$RetentionDays = 0
)

$ErrorActionPreference = "Stop"
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# Import shared utilities
Import-Module (Join-Path $PSScriptRoot "EmbeddingHelpers.psm1") -Force

# Load configuration
$config = Get-KBConfig
$storeName = "application-logs"

# Resolve paths
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$logPath = Join-Path $repoRoot $config.indexing.applicationLogs.path
$logPattern = $config.indexing.applicationLogs.pattern

# Retention
if ($RetentionDays -eq 0) {
    $RetentionDays = $config.storage.retentionDays.logs
}
$retentionCutoff = (Get-Date).AddDays(-$RetentionDays)

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Stacker AI - Application Logs Indexer" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Repository root  : $repoRoot" -ForegroundColor Gray
Write-Host "  Log path         : $logPath" -ForegroundColor Gray
Write-Host "  Log pattern      : $logPattern" -ForegroundColor Gray
Write-Host "  Retention        : $RetentionDays days (since $($retentionCutoff.ToString('yyyy-MM-dd')))" -ForegroundColor Gray
Write-Host "  Mode             : $(if ($Force) { 'FULL (forced)' } else { 'INCREMENTAL' })" -ForegroundColor Gray
Write-Host ""

if (-not (Test-Path $logPath)) {
    Write-Host "[WARN] Log directory not found: $logPath" -ForegroundColor Yellow
    Write-Host "  No application logs to index. This is normal if the API hasn't been run yet." -ForegroundColor Gray
    exit 0
}

# ============================================================================
# HELPER: Parse a Serilog log line into structured components
# ============================================================================

function ConvertFrom-SerilogLine {
    <#
    .SYNOPSIS
        Parses a Serilog structured log line into its components.

    .DESCRIPTION
        Expected format: 2026-01-21 10:09:58.041 -05:00 [INF] Message text {"Property":"Value",...}
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Line
    )

    $result = @{
        Timestamp     = $null
        Level         = "UNK"
        Message       = ""
        CorrelationId = $null
        SourceContext = $null
        MachineName   = $null
        Properties    = @{}
        Raw           = $Line
    }

    # Match: timestamp [LEVEL] message {json}
    if ($Line -match '^(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\.\d{3})\s+([+-]\d{2}:\d{2})\s+\[(\w{3})\]\s+(.+)$') {
        $timestampStr = $Matches[1]
        $result.Level = $Matches[3]
        $remainder = $Matches[4]

        try {
            $result.Timestamp = [DateTime]::ParseExact($timestampStr, "yyyy-MM-dd HH:mm:ss.fff", $null)
        }
        catch {
            $result.Timestamp = Get-Date
        }

        # Try to separate message from JSON properties
        $jsonStart = $remainder.LastIndexOf('{')
        if ($jsonStart -ge 0) {
            $result.Message = $remainder.Substring(0, $jsonStart).Trim()
            $jsonPart = $remainder.Substring($jsonStart)

            try {
                $props = $jsonPart | ConvertFrom-Json
                # Extract known fields
                if ($props.CorrelationId) { $result.CorrelationId = $props.CorrelationId }
                if ($props.SourceContext) { $result.SourceContext = $props.SourceContext }
                if ($props.MachineName) { $result.MachineName = $props.MachineName }
                $result.Properties = $props
            }
            catch {
                # JSON parse failed - keep the full remainder as message
                $result.Message = $remainder
            }
        }
        else {
            $result.Message = $remainder
        }
    }
    else {
        # Non-matching line (continuation, stack trace, etc.)
        $result.Message = $Line
    }

    return $result
}

# ============================================================================
# STEP 1: Discover log files within retention period
# ============================================================================

Write-Host "Step 1: Discovering log files..." -ForegroundColor Cyan

$allLogFiles = Get-ChildItem -Path $logPath -Filter $logPattern -File | Where-Object {
    # Extract date from filename (Stacker-YYYYMMDD.log)
    if ($_.BaseName -match 'Stacker-(\d{8})') {
        $logDate = [DateTime]::ParseExact($Matches[1], "yyyyMMdd", $null)
        $logDate -ge $retentionCutoff
    }
    else {
        # Include files without date pattern (let last-write filter them)
        $_.LastWriteTime -ge $retentionCutoff
    }
} | Sort-Object Name

if ($allLogFiles.Count -eq 0) {
    Write-Host "  No log files found within retention period." -ForegroundColor Yellow
    Write-Host "  Checked: $logPath\$logPattern" -ForegroundColor Gray
    exit 0
}

Write-Host "  Found $($allLogFiles.Count) log file(s) within retention:" -ForegroundColor Green
foreach ($f in $allLogFiles) {
    Write-Host "    - $($f.Name) ($([Math]::Round($f.Length / 1KB, 1)) KB, modified $($f.LastWriteTime.ToString('yyyy-MM-dd')))" -ForegroundColor Gray
}
Write-Host ""

# ============================================================================
# STEP 2: Load existing embeddings (for incremental mode)
# ============================================================================

$existingStore = $null
$existingHashes = @{}

if (-not $Force) {
    Write-Host "Step 2: Loading existing embeddings for change detection..." -ForegroundColor Cyan
    $existingStore = Get-EmbeddingStore -StoreName $storeName

    if ($existingStore -and $existingStore.entries) {
        foreach ($entry in $existingStore.entries) {
            if ($entry.filePath -and $entry.contentHash) {
                $existingHashes[$entry.filePath] = $entry.contentHash
            }
        }
        Write-Host "  Loaded $($existingHashes.Count) previously indexed log files" -ForegroundColor Green
    }
    else {
        Write-Host "  No existing index found - will index all log files" -ForegroundColor Yellow
    }
    Write-Host ""
}

# ============================================================================
# STEP 3: Process each log file
# ============================================================================

Write-Host "Step 3: Processing log files..." -ForegroundColor Cyan
Write-Host ""

$chunkSize = $config.embedding.chunkSize
$chunkOverlap = $config.embedding.chunkOverlap
$allEntries = @()
$filesProcessed = 0
$filesSkipped = 0
$totalChunks = 0
$totalLogLines = 0
$logLevelCounts = @{ INF = 0; WRN = 0; ERR = 0; FTL = 0; DBG = 0; VRB = 0; UNK = 0 }
$correlationIds = @{}
$errors = @()

foreach ($logFile in $allLogFiles) {
    $relativePath = $logFile.FullName.Substring($repoRoot.Length + 1)
    $content = Get-Content $logFile.FullName -Raw -ErrorAction SilentlyContinue

    if (-not $content -or $content.Trim().Length -eq 0) {
        Write-Host "  [SKIP] Empty log file: $relativePath" -ForegroundColor DarkGray
        continue
    }

    # Check content hash for incremental mode
    $currentHash = Get-ContentHash -Content $content

    if (-not $Force -and $existingHashes.ContainsKey($relativePath)) {
        if ($existingHashes[$relativePath] -eq $currentHash) {
            Write-Host "  [SKIP] Unchanged: $relativePath" -ForegroundColor DarkGray

            $existingEntries = $existingStore.entries | Where-Object { $_.filePath -eq $relativePath }
            foreach ($entry in $existingEntries) {
                $allEntries += @{
                    id          = $entry.id
                    filePath    = $entry.filePath
                    chunkIndex  = $entry.chunkIndex
                    content     = $entry.content
                    contentHash = $entry.contentHash
                    embedding   = @($entry.embedding)
                    metadata    = @{
                        lastModified   = $entry.metadata.lastModified
                        fileSize       = $entry.metadata.fileSize
                        logDate        = $entry.metadata.logDate
                        logLevels      = $entry.metadata.logLevels
                        correlationIds = $entry.metadata.correlationIds
                        lineCount      = $entry.metadata.lineCount
                        indexedAt      = $entry.metadata.indexedAt
                    }
                }
            }
            $filesSkipped++
            continue
        }
    }

    # Parse all log lines
    $lines = $content -split "`n" | Where-Object { $_.Trim().Length -gt 0 }
    $totalLogLines += $lines.Count

    Write-Host "  [INDEX] $relativePath ($($lines.Count) lines)..." -ForegroundColor White -NoNewline

    # Parse each line and collect metadata
    $parsedLines = @()
    foreach ($line in $lines) {
        $parsed = ConvertFrom-SerilogLine -Line $line.Trim()
        $parsedLines += $parsed

        # Track log level counts
        if ($logLevelCounts.ContainsKey($parsed.Level)) {
            $logLevelCounts[$parsed.Level]++
        }

        # Track correlation IDs
        if ($parsed.CorrelationId) {
            $correlationIds[$parsed.CorrelationId] = $true
        }
    }

    # Extract log date from filename
    $logDate = ""
    if ($logFile.BaseName -match 'Stacker-(\d{8})') {
        $logDate = $Matches[1]
    }

    # Group log lines into chunks for embedding
    # Strategy: group consecutive lines up to chunkSize characters
    $chunks = Split-TextIntoChunks -Text $content -ChunkSize $chunkSize -Overlap $chunkOverlap

    $fileErrors = $false
    foreach ($chunk in $chunks) {
        $chunkId = "$relativePath`:chunk-$($chunk.ChunkIndex)"

        # Extract metadata from lines in this chunk
        $chunkLines = $chunk.Text -split "`n" | Where-Object { $_.Trim().Length -gt 0 }
        $chunkLevels = @()
        $chunkCorrelationIds = @()

        foreach ($cl in $chunkLines) {
            $parsed = ConvertFrom-SerilogLine -Line $cl.Trim()
            if ($parsed.Level -and $parsed.Level -ne "UNK") {
                $chunkLevels += $parsed.Level
            }
            if ($parsed.CorrelationId) {
                $chunkCorrelationIds += $parsed.CorrelationId
            }
        }

        $chunkLevels = $chunkLevels | Select-Object -Unique
        $chunkCorrelationIds = $chunkCorrelationIds | Select-Object -Unique

        # Generate embedding
        $embedding = Get-Embedding -Text $chunk.Text

        if (-not $embedding) {
            Write-Host " [FAIL]" -ForegroundColor Red
            $errors += "Failed to generate embedding for $chunkId"
            $fileErrors = $true
            continue
        }

        $allEntries += @{
            id          = $chunkId
            filePath    = $relativePath
            chunkIndex  = $chunk.ChunkIndex
            content     = $chunk.Text
            contentHash = $currentHash
            embedding   = $embedding
            metadata    = @{
                lastModified   = $logFile.LastWriteTime.ToString("o")
                fileSize       = $logFile.Length
                logDate        = $logDate
                logLevels      = ($chunkLevels -join ",")
                correlationIds = ($chunkCorrelationIds -join ",")
                lineCount      = $chunkLines.Count
                indexedAt      = (Get-Date).ToString("o")
            }
        }
        $totalChunks++
    }

    if (-not $fileErrors) {
        Write-Host " [DONE]" -ForegroundColor Green
    }
    $filesProcessed++
}

# ============================================================================
# STEP 4: Save embedding store
# ============================================================================

Write-Host ""
Write-Host "Step 4: Saving embedding store..." -ForegroundColor Cyan

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
Write-Host "  Indexing Complete" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Log files found  : $($allLogFiles.Count)" -ForegroundColor Gray
Write-Host "  Files indexed    : $filesProcessed" -ForegroundColor Gray
Write-Host "  Files skipped    : $filesSkipped (unchanged)" -ForegroundColor Gray
Write-Host "  Total log lines  : $totalLogLines" -ForegroundColor Gray
Write-Host "  Total chunks     : $totalChunks" -ForegroundColor Gray
Write-Host "  Total entries    : $($allEntries.Count)" -ForegroundColor Gray
Write-Host "  Correlation IDs  : $($correlationIds.Count) unique" -ForegroundColor Gray
Write-Host "  Duration         : $($stopwatch.Elapsed.ToString('mm\:ss'))" -ForegroundColor Gray
Write-Host ""
Write-Host "  Log level breakdown:" -ForegroundColor Gray
foreach ($level in @("INF", "WRN", "ERR", "FTL", "DBG")) {
    if ($logLevelCounts[$level] -gt 0) {
        $color = switch ($level) {
            "INF" { "Green" }
            "WRN" { "Yellow" }
            "ERR" { "Red" }
            "FTL" { "Red" }
            "DBG" { "Gray" }
            default { "White" }
        }
        Write-Host "    $level : $($logLevelCounts[$level])" -ForegroundColor $color
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
    Write-Host "  Status           : [PASS] All log files indexed successfully" -ForegroundColor Green
}
