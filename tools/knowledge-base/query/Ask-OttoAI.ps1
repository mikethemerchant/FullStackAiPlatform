<#
.SYNOPSIS
    Ask Stacker AI a question using Retrieval-Augmented Generation (RAG).

.DESCRIPTION
    This is the main entry point for querying the Stacker knowledge base with natural
    language. It ties together the full RAG pipeline:

    1. Takes your question in plain English
    2. Searches the knowledge base for relevant context (source code, docs, logs, DevOps)
    3. Builds a prompt that includes the retrieved context + your question
    4. Sends the prompt to Ollama (llama3) for a grounded answer
    5. Returns the answer and logs the query for audit purposes

    RAG (Retrieval-Augmented Generation) means the AI doesn't just guess -- it
    answers based on actual data from your codebase. This dramatically reduces
    hallucination and gives you answers with real file paths, code snippets,
    and timestamps.

.PARAMETER Question
    The natural language question to ask. Examples:
    - "What endpoints use Windows Auth?"
    - "How do I check if Ollama is healthy?"
    - "Show recent build failures"

.PARAMETER Stores
    Which knowledge base stores to search. Defaults to all stores.
    Valid values: source-code, documentation, application-logs, devops-pipelines

.PARAMETER TopK
    Number of context chunks to retrieve. Default: from config.json (5).
    Higher values give more context but may slow response.

.PARAMETER SimilarityThreshold
    Minimum relevance score (0-1) for context retrieval. Default: from config.json (0.7).

.PARAMETER NoStream
    If set, waits for the full response before displaying. Default streams token-by-token.

.PARAMETER ShowContext
    If set, displays the retrieved context before the AI answer.

.EXAMPLE
    # Ask a question
    .\Ask-StackerAI.ps1 "What endpoints use Windows Auth?"

    # Ask with context shown
    .\Ask-StackerAI.ps1 "How to deploy to Test?" -ShowContext

    # Search only source code
    .\Ask-StackerAI.ps1 "How is OllamaClient configured?" -Stores source-code

    # Lower threshold for broader context
    .\Ask-StackerAI.ps1 "Show recent API errors" -SimilarityThreshold 0.5
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Question,

    [string[]]$Stores = @("source-code", "documentation", "application-logs", "devops-pipelines"),

    [int]$TopK = 0,

    [double]$SimilarityThreshold = 0,

    [switch]$NoStream,

    [switch]$ShowContext
)

$ErrorActionPreference = "Stop"
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# Import shared utilities
Import-Module (Join-Path $PSScriptRoot "..\indexer\EmbeddingHelpers.psm1") -Force

# Load configuration
$config = Get-KBConfig

if ($TopK -eq 0) { $TopK = $config.query.topK }
if ($SimilarityThreshold -eq 0) { $SimilarityThreshold = $config.query.similarityThreshold }

$ragModel = $config.query.ragModel
$ollamaEndpoint = $config.embedding.ollamaEndpoint
$maxContextTokens = $config.query.maxContextTokens

# Generate a correlation ID for this query
$correlationId = [guid]::NewGuid().ToString("N").Substring(0, 12)

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Stacker AI - Ask a Question (RAG)" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Question      : $Question" -ForegroundColor White
Write-Host "  Model         : $ragModel" -ForegroundColor Gray
Write-Host "  Correlation   : $correlationId" -ForegroundColor Gray
Write-Host ""

# ============================================================================
# STEP 1: Search the knowledge base for relevant context
# ============================================================================

Write-Host "Step 1: Searching knowledge base for relevant context..." -ForegroundColor Cyan
Write-Host ""

$queryEmbedding = Get-Embedding -Text $Question
if (-not $queryEmbedding) {
    Write-Host "  [FAIL] Could not generate embedding for question." -ForegroundColor Red
    exit 1
}

$allResults = @()
foreach ($storeName in $Stores) {
    $store = Get-EmbeddingStore -StoreName $storeName
    if (-not $store -or -not $store.entries -or $store.entries.Count -eq 0) {
        continue
    }

    foreach ($entry in $store.entries) {
        $entryEmbedding = @($entry.embedding)
        if ($entryEmbedding.Count -eq 0) { continue }

        $similarity = Get-CosineSimilarity -VectorA $queryEmbedding -VectorB $entryEmbedding
        if ($similarity -ge $SimilarityThreshold) {
            $allResults += @{
                Score    = [Math]::Round($similarity, 4)
                Store    = $storeName
                FilePath = $entry.filePath
                Content  = $entry.content
                Metadata = $entry.metadata
            }
        }
    }
}

# Sort by score and take top K
$allResults = $allResults | Sort-Object { $_.Score } -Descending | Select-Object -First $TopK

if ($allResults.Count -eq 0) {
    Write-Host "  No relevant context found in the knowledge base." -ForegroundColor Yellow
    Write-Host "  The AI will answer without knowledge base context (may be less accurate)." -ForegroundColor Gray
    Write-Host ""
}
else {
    Write-Host "  Found $($allResults.Count) relevant chunk(s):" -ForegroundColor Green
    foreach ($r in $allResults) {
        $scorePercent = [Math]::Round($r.Score * 100, 1)
        Write-Host "    [$scorePercent%] [$($r.Store)] $($r.FilePath)" -ForegroundColor Gray
    }
    Write-Host ""
}

# ============================================================================
# STEP 2: Build the RAG prompt
# ============================================================================

Write-Host "Step 2: Building RAG prompt..." -ForegroundColor Cyan

# Load the prompt template
$templatePath = Join-Path $PSScriptRoot "rag-prompt-template.txt"
if (-not (Test-Path $templatePath)) {
    Write-Host "  [FAIL] RAG prompt template not found: $templatePath" -ForegroundColor Red
    exit 1
}
$template = Get-Content $templatePath -Raw

# Build context string from search results
$contextParts = @()
$totalContextLength = 0

foreach ($result in $allResults) {
    $contextEntry = @()
    $contextEntry += "--- Source: [$($result.Store)] $($result.FilePath) (relevance: $([Math]::Round($result.Score * 100, 1))%) ---"
    $contextEntry += $result.Content
    $contextEntry += ""

    $entryText = $contextEntry -join "`n"

    # Rough token estimate (1 token ~ 4 chars) to stay within context window
    $estimatedTokens = [Math]::Ceiling($entryText.Length / 4)
    if (($totalContextLength + $estimatedTokens) -gt $maxContextTokens) {
        Write-Host "  Context window limit reached ($maxContextTokens tokens), using $($contextParts.Count) chunks" -ForegroundColor DarkGray
        break
    }

    $contextParts += $entryText
    $totalContextLength += $estimatedTokens
}

$contextText = if ($contextParts.Count -gt 0) {
    $contextParts -join "`n"
}
else {
    "No relevant context was found in the knowledge base for this question."
}

# Replace template placeholders
$prompt = $template -replace '\{\{CONTEXT\}\}', $contextText
$prompt = $prompt -replace '\{\{QUESTION\}\}', $Question

# Sanitize for JSON (remove non-ASCII characters that break ConvertTo-Json in PS 5.1)
$prompt = $prompt -replace '[^\x20-\x7E\r\n\t]', ' '

if ($ShowContext) {
    Write-Host ""
    Write-Host "  --- Retrieved Context ---" -ForegroundColor DarkGray
    foreach ($part in $contextParts) {
        $lines = ($part -split "`n") | Select-Object -First 5
        foreach ($line in $lines) {
            Write-Host "  $line" -ForegroundColor DarkGray
        }
        if (($part -split "`n").Count -gt 5) {
            Write-Host "  ... (truncated)" -ForegroundColor DarkGray
        }
    }
    Write-Host "  --- End Context ---" -ForegroundColor DarkGray
    Write-Host ""
}

Write-Host "  [PASS] Prompt built ($totalContextLength est. tokens from $($contextParts.Count) chunks)" -ForegroundColor Green
Write-Host ""

# ============================================================================
# STEP 3: Send prompt to Ollama and get response
# ============================================================================

Write-Host "Step 3: Sending to $ragModel..." -ForegroundColor Cyan
Write-Host ""

$generateUrl = "$ollamaEndpoint/api/generate"

$body = @{
    model  = $ragModel
    prompt = $prompt
    stream = (-not $NoStream.IsPresent)
} | ConvertTo-Json -Depth 5

if ($NoStream) {
    # Non-streaming: wait for full response
    try {
        $response = Invoke-RestMethod -Uri $generateUrl -Method Post -Body $body -ContentType "application/json" -TimeoutSec 120
        $answer = $response.response
        Write-Host $answer
    }
    catch {
        Write-Host "  [FAIL] Ollama request failed: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}
else {
    # Streaming: read token by token for real-time output
    $answer = ""
    try {
        $request = [System.Net.HttpWebRequest]::Create($generateUrl)
        $request.Method = "POST"
        $request.ContentType = "application/json"
        $request.Timeout = 120000

        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $request.ContentLength = $bodyBytes.Length
        $requestStream = $request.GetRequestStream()
        $requestStream.Write($bodyBytes, 0, $bodyBytes.Length)
        $requestStream.Close()

        $response = $request.GetResponse()
        $responseStream = $response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($responseStream)

        Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
        Write-Host ""

        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if ($line) {
                try {
                    $json = $line | ConvertFrom-Json
                    if ($json.response) {
                        Write-Host $json.response -NoNewline
                        $answer += $json.response
                    }
                }
                catch {
                    # Skip malformed lines
                }
            }
        }

        Write-Host ""
        Write-Host ""
        Write-Host "  ----------------------------------------" -ForegroundColor DarkGray

        $reader.Close()
        $responseStream.Close()
        $response.Close()
    }
    catch {
        Write-Host "  [FAIL] Ollama streaming request failed: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

# ============================================================================
# STEP 4: Audit log
# ============================================================================

$stopwatch.Stop()

$logEntry = @{
    timestamp     = (Get-Date).ToString("o")
    correlationId = $correlationId
    question      = $Question
    user          = $env:USERNAME
    machine       = $env:COMPUTERNAME
    stores        = $Stores -join ","
    resultsCount  = $allResults.Count
    topScore      = if ($allResults.Count -gt 0) { $allResults[0].Score } else { 0 }
    model         = $ragModel
    durationMs    = $stopwatch.ElapsedMilliseconds
    answerLength  = $answer.Length
}

$logPath = $config.logging.queryLogPath
$logDir = Split-Path $logPath -Parent
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

$logLine = ($logEntry | ConvertTo-Json -Compress)
Add-Content -Path $logPath -Value $logLine -Encoding UTF8

Write-Host ""
Write-Host "--------------------------------------------" -ForegroundColor Gray
Write-Host "  Correlation ID : $correlationId" -ForegroundColor Gray
Write-Host "  Context chunks : $($allResults.Count)" -ForegroundColor Gray
Write-Host "  Best match     : $(if ($allResults.Count -gt 0) { "$([Math]::Round($allResults[0].Score * 100, 1))% ($($allResults[0].Store))" } else { 'N/A' })" -ForegroundColor Gray
Write-Host "  Duration       : $($stopwatch.Elapsed.ToString('mm\:ss'))" -ForegroundColor Gray
Write-Host "  Audit log      : $logPath" -ForegroundColor Gray
Write-Host ""
