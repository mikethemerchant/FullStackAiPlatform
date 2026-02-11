<#
.SYNOPSIS
    Indexes documentation files and generates embeddings for the AI knowledge base.

.DESCRIPTION
    Scans configured documentation paths (README.md, docs/, ops/runbooks/, infra/ai/,
    and project-level READMEs) for .md and .txt files. Splits documents by section
    headers (## / ###) to preserve logical structure, generates vector embeddings
    via Ollama, and saves results to the local knowledge base and repository backup.

    Supports incremental mode: if a file's content hash matches the previously
    stored hash, it is skipped.

.PARAMETER Force
    Forces a full re-index of all files, ignoring content hashes.

.PARAMETER Incremental
    Only indexes files that have changed since the last run (default behavior).

.EXAMPLE
    # Full index (first time or force rebuild)
    .\Index-Documentation.ps1 -Force

    # Incremental update (skip unchanged files)
    .\Index-Documentation.ps1
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
$storeName = "documentation"

# Resolve the repo root (two levels up from indexer/)
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Stacker AI - Documentation Indexer" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Repository root : $repoRoot" -ForegroundColor Gray
Write-Host "  Mode            : $(if ($Force) { 'FULL (forced)' } else { 'INCREMENTAL' })" -ForegroundColor Gray
Write-Host ""

# ============================================================================
# HELPER: Split markdown by section headers for section-level granularity
# ============================================================================

function Split-MarkdownBySections {
    <#
    .SYNOPSIS
        Splits a markdown document into sections based on ## and ### headers.
        
    .DESCRIPTION
        Instead of splitting by raw character count, this splits on logical 
        section boundaries. Each section keeps its header so the AI knows
        what topic the chunk covers. Sections larger than the chunk size 
        are further split using the standard character chunking.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,

        [string]$FilePath,

        [int]$MaxChunkSize = 1000,

        [int]$ChunkOverlap = 200
    )

    $sections = @()
    $lines = $Content -split "`n"
    $currentSection = ""
    $currentHeader = "(no header)"
    $sectionIndex = 0

    foreach ($line in $lines) {
        # Detect markdown headers (## or ###)
        if ($line -match '^#{1,3}\s+(.+)') {
            # Save the previous section if it has content
            if ($currentSection.Trim().Length -gt 0) {
                $sections += @{
                    Header       = $currentHeader
                    Content      = $currentSection.Trim()
                    SectionIndex = $sectionIndex
                }
                $sectionIndex++
            }
            $currentHeader = $Matches[1].Trim()
            $currentSection = "$line`n"
        }
        else {
            $currentSection += "$line`n"
        }
    }

    # Don't forget the last section
    if ($currentSection.Trim().Length -gt 0) {
        $sections += @{
            Header       = $currentHeader
            Content      = $currentSection.Trim()
            SectionIndex = $sectionIndex
        }
    }

    # Now break any oversized sections into smaller chunks
    $finalChunks = @()
    $chunkIndex = 0

    foreach ($section in $sections) {
        if ($section.Content.Length -le $MaxChunkSize) {
            $finalChunks += @{
                Text         = $section.Content
                Header       = $section.Header
                ChunkIndex   = $chunkIndex
                SectionIndex = $section.SectionIndex
            }
            $chunkIndex++
        }
        else {
            # Section too large - sub-chunk it but prepend the header to each chunk
            $subChunks = Split-TextIntoChunks -Text $section.Content -ChunkSize $MaxChunkSize -Overlap $ChunkOverlap
            foreach ($sub in $subChunks) {
                $finalChunks += @{
                    Text         = $sub.Text
                    Header       = $section.Header
                    ChunkIndex   = $chunkIndex
                    SectionIndex = $section.SectionIndex
                }
                $chunkIndex++
            }
        }
    }

    return $finalChunks
}

# ============================================================================
# STEP 1: Discover documentation files
# ============================================================================

Write-Host "Step 1: Discovering documentation files..." -ForegroundColor Cyan

$includeExtensions = $config.indexing.documentation.includePatterns | ForEach-Object { $_ -replace '\*', '' }

# Gather files from configured paths plus additional documentation locations
$docPaths = @()
foreach ($docPath in $config.indexing.documentation.paths) {
    $fullPath = Join-Path $repoRoot $docPath
    if (Test-Path $fullPath) {
        if ((Get-Item $fullPath).PSIsContainer) {
            $docPaths += Get-ChildItem -Path $fullPath -Recurse -File | Where-Object {
                $includeExtensions -contains $_.Extension
            }
        }
        else {
            # Single file (e.g., README.md)
            $docPaths += Get-Item $fullPath
        }
    }
    else {
        Write-Host "  [WARN] Path not found: $fullPath" -ForegroundColor Yellow
    }
}

# Also include infra/ai/ docs and project-level READMEs
$additionalPaths = @("infra\ai", "src")
foreach ($addPath in $additionalPaths) {
    $fullPath = Join-Path $repoRoot $addPath
    if (Test-Path $fullPath) {
        $found = Get-ChildItem -Path $fullPath -Recurse -File | Where-Object {
            ($includeExtensions -contains $_.Extension) -and
            ($_.FullName -notmatch '\\(bin|obj)\\') -and
            (
                # From infra/ai, include all docs
                ($_.FullName -match '\\infra\\ai\\') -or
                # From src/, only include README files
                ($_.Name -ieq 'README.md')
            )
        }
        $docPaths += $found
    }
}

# Deduplicate by full path
$allFiles = $docPaths | Sort-Object FullName -Unique

Write-Host "  Found $($allFiles.Count) documentation files:" -ForegroundColor Green
foreach ($f in $allFiles) {
    $rel = $f.FullName.Substring($repoRoot.Length + 1)
    Write-Host "    - $rel" -ForegroundColor Gray
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
        Write-Host "  Loaded $($existingHashes.Count) previously indexed files" -ForegroundColor Green
    }
    else {
        Write-Host "  No existing index found - will index all files" -ForegroundColor Yellow
    }
    Write-Host ""
}

# ============================================================================
# STEP 3: Process each file (section-split, hash, embed)
# ============================================================================

Write-Host "Step 3: Processing documentation files..." -ForegroundColor Cyan
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
                        documentType  = $entry.metadata.documentType
                        sectionHeader = $entry.metadata.sectionHeader
                        indexedAt     = $entry.metadata.indexedAt
                    }
                }
            }
            $filesSkipped++
            continue
        }
    }

    # Determine document type from path
    $documentType = switch -Regex ($relativePath) {
        '\\runbooks\\'     { "runbook" }
        '\\docs\\'         { "architecture" }
        '\\infra\\ai\\'    { "ai-setup" }
        'README\.md$'      { "readme" }
        default            { "documentation" }
    }

    # Split by markdown sections (section-level granularity)
    if ($file.Extension -eq ".md") {
        $chunks = Split-MarkdownBySections -Content $content -FilePath $relativePath -MaxChunkSize $chunkSize -ChunkOverlap $chunkOverlap
    }
    else {
        # Plain text - use standard chunking
        $rawChunks = Split-TextIntoChunks -Text $content -ChunkSize $chunkSize -Overlap $chunkOverlap
        $chunks = $rawChunks | ForEach-Object {
            @{
                Text         = $_.Text
                Header       = "(plain text)"
                ChunkIndex   = $_.ChunkIndex
                SectionIndex = 0
            }
        }
    }

    Write-Host "  [INDEX] $relativePath ($($chunks.Count) chunk(s), type: $documentType)..." -ForegroundColor White -NoNewline

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
                documentType  = $documentType
                sectionHeader = $chunk.Header
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
