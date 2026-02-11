<#
.SYNOPSIS
    Searches the Stacker AI knowledge base using natural language queries.

.DESCRIPTION
    Converts a natural language question into a vector embedding, then searches
    across all knowledge base stores (source code, documentation, application logs,
    and DevOps pipeline data) to find the most relevant results.

    This is the "read" side of the knowledge base. The indexers (Index-SourceCode.ps1,
    Index-Documentation.ps1, etc.) build the data; this script queries it.

    How it works:
    1. Your question is converted to a 768-dimension vector (same as indexing)
    2. That vector is compared against every chunk in each store using cosine similarity
    3. Results above the similarity threshold are returned, ranked by relevance

.PARAMETER Query
    The natural language question to search for. Examples:
    - "What endpoints use Windows Auth?"
    - "Show recent API errors"
    - "How to deploy to Test?"

.PARAMETER Stores
    Which stores to search. Defaults to all stores.
    Valid values: source-code, documentation, application-logs, devops-pipelines

.PARAMETER TopK
    Number of top results to return per store. Default: from config.json (5).

.PARAMETER SimilarityThreshold
    Minimum cosine similarity score (0-1) to include a result. Default: from config.json (0.7).
    Lower values return more results but with less relevance.

.PARAMETER ShowContent
    If set, displays the full text content of each result. Otherwise shows a truncated preview.

.EXAMPLE
    # Search all stores
    .\Search-KnowledgeBase.ps1 -Query "What endpoints use Windows Auth?"

    # Search only source code
    .\Search-KnowledgeBase.ps1 -Query "How is OllamaClient configured?" -Stores source-code

    # Search with lower threshold to get more results
    .\Search-KnowledgeBase.ps1 -Query "deployment errors" -SimilarityThreshold 0.5

    # Show full content of matches
    .\Search-KnowledgeBase.ps1 -Query "correlation ID" -ShowContent
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Query,

    [string[]]$Stores = @("source-code", "documentation", "application-logs", "devops-pipelines"),

    [int]$TopK = 0,

    [double]$SimilarityThreshold = 0,

    [switch]$ShowContent
)

$ErrorActionPreference = "Stop"
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# Import shared utilities
Import-Module (Join-Path $PSScriptRoot "..\indexer\EmbeddingHelpers.psm1") -Force

# Load configuration
$config = Get-KBConfig

if ($TopK -eq 0) { $TopK = $config.query.topK }
if ($SimilarityThreshold -eq 0) { $SimilarityThreshold = $config.query.similarityThreshold }

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Stacker AI - Knowledge Base Search" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Query     : $Query" -ForegroundColor White
Write-Host "  Stores    : $($Stores -join ', ')" -ForegroundColor Gray
Write-Host "  Top K     : $TopK" -ForegroundColor Gray
Write-Host "  Threshold : $SimilarityThreshold" -ForegroundColor Gray
Write-Host ""

# ============================================================================
# STEP 1: Generate query embedding
# ============================================================================

Write-Host "Step 1: Generating query embedding..." -ForegroundColor Cyan

$queryEmbedding = Get-Embedding -Text $Query

if (-not $queryEmbedding) {
    Write-Host "  [FAIL] Could not generate embedding for query." -ForegroundColor Red
    Write-Host "  Check that Ollama is running and nomic-embed-text is available." -ForegroundColor Yellow
    exit 1
}

Write-Host "  [PASS] Query embedding generated ($($queryEmbedding.Count) dimensions)" -ForegroundColor Green
Write-Host ""

# ============================================================================
# STEP 2: Search each store
# ============================================================================

Write-Host "Step 2: Searching knowledge base stores..." -ForegroundColor Cyan
Write-Host ""

$allResults = @()
$storesSearched = 0
$storesEmpty = 0

foreach ($storeName in $Stores) {
    $store = Get-EmbeddingStore -StoreName $storeName

    if (-not $store -or -not $store.entries -or $store.entries.Count -eq 0) {
        Write-Host "  [$storeName] No data found - skipping" -ForegroundColor DarkGray
        $storesEmpty++
        continue
    }

    Write-Host "  [$storeName] Searching $($store.entries.Count) entries..." -ForegroundColor White -NoNewline

    $results = @()
    foreach ($entry in $store.entries) {
        $entryEmbedding = @($entry.embedding)
        if ($entryEmbedding.Count -eq 0) { continue }

        $similarity = Get-CosineSimilarity -VectorA $queryEmbedding -VectorB $entryEmbedding

        if ($similarity -ge $SimilarityThreshold) {
            $results += @{
                Score      = [Math]::Round($similarity, 4)
                Store      = $storeName
                FilePath   = $entry.filePath
                ChunkIndex = $entry.chunkIndex
                Content    = $entry.content
                Metadata   = $entry.metadata
            }
        }
    }

    # Sort by score descending, take top K
    $results = $results | Sort-Object { $_.Score } -Descending | Select-Object -First $TopK

    if ($results.Count -gt 0) {
        Write-Host " $($results.Count) match(es)" -ForegroundColor Green
        $allResults += $results
    }
    else {
        Write-Host " no matches above threshold" -ForegroundColor Yellow
    }

    $storesSearched++
}

# ============================================================================
# STEP 3: Rank and display results
# ============================================================================

Write-Host ""

if ($allResults.Count -eq 0) {
    Write-Host "No results found." -ForegroundColor Yellow
    Write-Host "  Try lowering the similarity threshold with -SimilarityThreshold 0.5" -ForegroundColor Gray
    Write-Host "  Or check that the knowledge base has been indexed recently." -ForegroundColor Gray
    exit 0
}

# Sort all results across stores by score
$allResults = $allResults | Sort-Object { $_.Score } -Descending

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Search Results ($($allResults.Count) matches)" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

$rank = 1
foreach ($result in $allResults) {
    $scorePercent = [Math]::Round($result.Score * 100, 1)
    $scoreColor = if ($result.Score -ge 0.85) { "Green" } elseif ($result.Score -ge 0.7) { "Yellow" } else { "White" }

    Write-Host "  #$rank " -ForegroundColor White -NoNewline
    Write-Host "[$scorePercent%] " -ForegroundColor $scoreColor -NoNewline
    Write-Host "[$($result.Store)] " -ForegroundColor Cyan -NoNewline
    Write-Host "$($result.FilePath)" -ForegroundColor White

    # Show metadata highlights
    $meta = $result.Metadata
    $metaParts = @()
    if ($meta.documentType) { $metaParts += "type: $($meta.documentType)" }
    if ($meta.sectionHeader) { $metaParts += "section: $($meta.sectionHeader)" }
    if ($meta.logLevels) { $metaParts += "levels: $($meta.logLevels)" }
    if ($meta.result) { $metaParts += "result: $($meta.result)" }
    if ($meta.branch) { $metaParts += "branch: $($meta.branch)" }
    if ($meta.lastModified) {
        try {
            $modDate = ([DateTime]$meta.lastModified).ToString("yyyy-MM-dd")
            $metaParts += "modified: $modDate"
        }
        catch { }
    }

    if ($metaParts.Count -gt 0) {
        Write-Host "       $($metaParts -join ' | ')" -ForegroundColor DarkGray
    }

    # Show content preview or full content
    if ($ShowContent) {
        Write-Host "       ---" -ForegroundColor DarkGray
        $contentLines = ($result.Content -split "`n") | Select-Object -First 20
        foreach ($line in $contentLines) {
            Write-Host "       $line" -ForegroundColor Gray
        }
        if (($result.Content -split "`n").Count -gt 20) {
            Write-Host "       ... (truncated, $((($result.Content -split "`n").Count)) total lines)" -ForegroundColor DarkGray
        }
    }
    else {
        # Show first 2 lines as preview
        $preview = ($result.Content -split "`n" | Where-Object { $_.Trim().Length -gt 0 } | Select-Object -First 2) -join " "
        if ($preview.Length -gt 120) { $preview = $preview.Substring(0, 117) + "..." }
        Write-Host "       $preview" -ForegroundColor DarkGray
    }

    Write-Host ""
    $rank++
}

# ============================================================================
# SUMMARY
# ============================================================================

$stopwatch.Stop()

Write-Host "--------------------------------------------" -ForegroundColor Gray
Write-Host "  Stores searched : $storesSearched ($storesEmpty empty/missing)" -ForegroundColor Gray
Write-Host "  Total matches   : $($allResults.Count)" -ForegroundColor Gray
Write-Host "  Best score      : $([Math]::Round($allResults[0].Score * 100, 1))% ($($allResults[0].Store))" -ForegroundColor Gray
Write-Host "  Duration        : $($stopwatch.Elapsed.ToString('mm\:ss'))" -ForegroundColor Gray
Write-Host ""
