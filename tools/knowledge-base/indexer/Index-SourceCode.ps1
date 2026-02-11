<#
.SYNOPSIS
    Indexes source code files and generates embeddings for the AI knowledge base.

.DESCRIPTION
    Scans the src/ directory for .cs, .csproj, and .json files (excluding bin/obj),
    splits each file into chunks, generates vector embeddings via Ollama, and saves
    the results to the local knowledge base and repository backup.

    Supports incremental mode: if a file's content hash matches the previously
    stored hash, it is skipped (no re-embedding needed).

.PARAMETER Force
    Forces a full re-index of all files, ignoring content hashes.

.PARAMETER Incremental
    Only indexes files that have changed since the last run (default behavior).

.EXAMPLE
    # Full index (first time or force rebuild)
    .\Index-SourceCode.ps1 -Force

    # Incremental update (skip unchanged files)
    .\Index-SourceCode.ps1

    # Explicit incremental flag
    .\Index-SourceCode.ps1 -Incremental
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$Incremental
)

$ErrorActionPreference = "Stop"
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# Import shared utilities
Import-Module (Join-Path $PSScriptRoot "EmbeddingHelpers.psm1") -Force

# Load configuration
$config = Get-KBConfig
$storeName = "source-code"

# Resolve the repo root (two levels up from indexer/)
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$srcRoot = Join-Path $repoRoot $config.indexing.sourceCode.rootPath

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Stacker AI - Source Code Indexer" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Repository root : $repoRoot" -ForegroundColor Gray
Write-Host "  Source root     : $srcRoot" -ForegroundColor Gray
Write-Host "  Mode            : $(if ($Force) { 'FULL (forced)' } else { 'INCREMENTAL' })" -ForegroundColor Gray
Write-Host ""

if (-not (Test-Path $srcRoot)) {
    Write-Host "[FAIL] Source root not found: $srcRoot" -ForegroundColor Red
    exit 1
}

# ============================================================================
# STEP 1: Discover source files
# ============================================================================

Write-Host "Step 1: Discovering source files..." -ForegroundColor Cyan

$includeExtensions = $config.indexing.sourceCode.includePatterns | ForEach-Object { $_ -replace '\*', '' }

$allFiles = Get-ChildItem -Path $srcRoot -Recurse -File | Where-Object {
    $ext = $_.Extension
    $relativePath = $_.FullName.Substring($repoRoot.Length + 1)

    # Include only matching extensions
    $included = $includeExtensions -contains $ext

    # Exclude bin/ and obj/ directories and .user files
    $excluded = $relativePath -match '\\(bin|obj)\\'  -or $relativePath -match '\.user$'

    $included -and (-not $excluded)
}

Write-Host "  Found $($allFiles.Count) source files to process" -ForegroundColor Green
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
            # Store the hash keyed by file path (only need one hash per file, not per chunk)
            if ($entry.filePath -and $entry.contentHash) {
                $existingHashes[$entry.filePath] = $entry.contentHash
            }
        }
        Write-Host "  Loaded $($existingHashes.Count) previously indexed files" -ForegroundColor Green
    }
    else {
        Write-Host "  No existing index found - will index all files" -ForegroundColor Yellow
    }
    Write-Host ""
}

# ============================================================================
# STEP 3: Process each file (chunk, hash, embed)
# ============================================================================

Write-Host "Step 3: Processing source files..." -ForegroundColor Cyan
Write-Host ""

$chunkSize = $config.embedding.chunkSize
$chunkOverlap = $config.embedding.chunkOverlap
$allEntries = @()
$filesProcessed = 0
$filesSkipped = 0
$totalChunks = 0
$errors = @()

foreach ($file in $allFiles) {
    $relativePath = $file.FullName.Substring($repoRoot.Length + 1)
    $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue

    if (-not $content -or $content.Trim().Length -eq 0) {
        Write-Host "  [SKIP] Empty file: $relativePath" -ForegroundColor DarkGray
        continue
    }

    # Check content hash for incremental mode
    $currentHash = Get-ContentHash -Content $content

    if (-not $Force -and $existingHashes.ContainsKey($relativePath)) {
        if ($existingHashes[$relativePath] -eq $currentHash) {
            Write-Host "  [SKIP] Unchanged: $relativePath" -ForegroundColor DarkGray

            # Keep existing entries for this file
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
                        lastModified  = $entry.metadata.lastModified
                        fileSize      = $entry.metadata.fileSize
                        fileExtension = $entry.metadata.fileExtension
                        project       = $entry.metadata.project
                        indexedAt     = $entry.metadata.indexedAt
                    }
                }
            }
            $filesSkipped++
            continue
        }
    }

    # Split file into chunks
    $chunks = Split-TextIntoChunks -Text $content -ChunkSize $chunkSize -Overlap $chunkOverlap

    Write-Host "  [INDEX] $relativePath ($($chunks.Count) chunk(s))..." -ForegroundColor White -NoNewline

    # Determine project name from path (e.g., "Stacker-api", "Stacker-ai-connector")
    $pathParts = $relativePath -split '\\'
    $projectName = if ($pathParts.Count -ge 2) { $pathParts[1] } else { "unknown" }

    $fileErrors = $false
    foreach ($chunk in $chunks) {
        $chunkId = "$relativePath`:chunk-$($chunk.ChunkIndex)"

        # Generate embedding for this chunk
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
                lastModified  = $file.LastWriteTime.ToString("o")
                fileSize      = $file.Length
                fileExtension = $file.Extension
                project       = $projectName
                indexedAt     = (Get-Date).ToString("o")
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
Write-Host "  Files found     : $($allFiles.Count)" -ForegroundColor Gray
Write-Host "  Files indexed   : $filesProcessed" -ForegroundColor Gray
Write-Host "  Files skipped   : $filesSkipped (unchanged)" -ForegroundColor Gray
Write-Host "  Total chunks    : $totalChunks" -ForegroundColor Gray
Write-Host "  Total entries   : $($allEntries.Count)" -ForegroundColor Gray
Write-Host "  Duration        : $($stopwatch.Elapsed.ToString('mm\:ss'))" -ForegroundColor Gray

if ($errors.Count -gt 0) {
    Write-Host ""
    Write-Host "  Errors ($($errors.Count)):" -ForegroundColor Red
    foreach ($err in $errors) {
        Write-Host "    - $err" -ForegroundColor Red
    }
    exit 1
}
else {
    Write-Host "  Status          : [PASS] All files indexed successfully" -ForegroundColor Green
}
