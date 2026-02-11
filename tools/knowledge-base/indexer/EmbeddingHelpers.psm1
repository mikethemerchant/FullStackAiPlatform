<#
.SYNOPSIS
    Shared utility functions for Stacker AI Knowledge Base indexing and querying.

.DESCRIPTION
    This module provides reusable functions for:
    - Generating vector embeddings via Ollama (nomic-embed-text model)
    - Chunking text into manageable pieces for embedding
    - Computing content hashes for change detection (skip unchanged files)
    - Saving and loading embedding stores (JSON files)
    - Calculating cosine similarity for search/query matching

    All indexer scripts (Index-SourceCode, Index-Documentation, etc.) import
    this module so they share the same logic and don't duplicate code.

.NOTES
    Import this module in scripts with:
        Import-Module (Join-Path $PSScriptRoot "EmbeddingHelpers.psm1") -Force
#>

# ============================================================================
# ENVIRONMENT FILE LOADING
# ============================================================================

function Import-EnvFile {
    <#
    .SYNOPSIS
        Loads environment variables from a .env file at the repository root.

    .DESCRIPTION
        Reads key=value pairs from the .env file and sets them as process-level
        environment variables. Lines starting with # are treated as comments.
        This allows scripts to access secrets (like Azure DevOps PAT) without
        requiring them to be set system-wide.

    .PARAMETER EnvFilePath
        Path to the .env file. Default: .env at the repository root.

    .OUTPUTS
        Returns $true if the file was loaded, $false if not found.
    #>
    [CmdletBinding()]
    param(
        [string]$EnvFilePath
    )

    if (-not $EnvFilePath) {
        $EnvFilePath = Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path ".env"
    }

    if (-not (Test-Path $EnvFilePath)) {
        Write-Verbose ".env file not found at: $EnvFilePath"
        return $false
    }

    $lines = Get-Content $EnvFilePath
    foreach ($line in $lines) {
        $trimmed = $line.Trim()

        # Skip empty lines and comments
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#')) {
            continue
        }

        # Parse KEY=VALUE
        $eqIndex = $trimmed.IndexOf('=')
        if ($eqIndex -gt 0) {
            $key = $trimmed.Substring(0, $eqIndex).Trim()
            $value = $trimmed.Substring($eqIndex + 1).Trim()

            # Remove surrounding quotes if present
            if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
                ($value.StartsWith("'") -and $value.EndsWith("'"))) {
                $value = $value.Substring(1, $value.Length - 2)
            }

            [System.Environment]::SetEnvironmentVariable($key, $value, "Process")
            Write-Verbose "Loaded env var: $key"
        }
    }

    return $true
}

# ============================================================================
# CONFIGURATION
# ============================================================================

function Get-KBConfig {
    <#
    .SYNOPSIS
        Loads and returns the knowledge base configuration from config.json.
    #>
    [CmdletBinding()]
    param(
        [string]$ConfigPath
    )

    if (-not $ConfigPath) {
        $ConfigPath = Join-Path $PSScriptRoot "..\config.json"
    }

    if (-not (Test-Path $ConfigPath)) {
        throw "Configuration file not found at: $ConfigPath"
    }

    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    return $config
}

# ============================================================================
# TEXT CHUNKING
# ============================================================================

function Split-TextIntoChunks {
    <#
    .SYNOPSIS
        Splits a large block of text into smaller overlapping chunks.

    .DESCRIPTION
        Embedding models have a limited context window. This function breaks
        large files into smaller pieces (default 1000 characters) with overlap
        (default 200 characters) so that context at chunk boundaries isn't lost.

        Example: A 2500-character file with chunkSize=1000, overlap=200 becomes:
          Chunk 1: characters 0-999
          Chunk 2: characters 800-1799   (overlaps 200 chars with chunk 1)
          Chunk 3: characters 1600-2499  (overlaps 200 chars with chunk 2)

    .PARAMETER Text
        The full text content to split.

    .PARAMETER ChunkSize
        Maximum number of characters per chunk. Default: 1000.

    .PARAMETER Overlap
        Number of characters to overlap between consecutive chunks. Default: 200.

    .OUTPUTS
        Array of hashtables, each with:
          - Text: the chunk text
          - StartIndex: character offset in the original text
          - ChunkIndex: sequential chunk number (0-based)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [int]$ChunkSize = 1000,

        [int]$Overlap = 200
    )

    $chunks = @()
    $startIndex = 0
    $chunkIndex = 0
    $textLength = $Text.Length

    if ($textLength -eq 0) {
        return $chunks
    }

    # If the entire text fits in one chunk, return it as-is
    if ($textLength -le $ChunkSize) {
        $chunks += @{
            Text       = $Text
            StartIndex = 0
            ChunkIndex = 0
        }
        return $chunks
    }

    while ($startIndex -lt $textLength) {
        $endIndex = [Math]::Min($startIndex + $ChunkSize, $textLength)
        $chunkText = $Text.Substring($startIndex, $endIndex - $startIndex)

        $chunks += @{
            Text       = $chunkText
            StartIndex = $startIndex
            ChunkIndex = $chunkIndex
        }

        # Move forward by (chunkSize - overlap) so chunks overlap
        $startIndex += ($ChunkSize - $Overlap)
        $chunkIndex++

        # Safety: if overlap >= chunkSize, we'd loop forever
        if (($ChunkSize - $Overlap) -le 0) {
            Write-Warning "Overlap ($Overlap) must be less than ChunkSize ($ChunkSize). Stopping."
            break
        }
    }

    return $chunks
}

# ============================================================================
# CONTENT HASHING (CHANGE DETECTION)
# ============================================================================

function Get-ContentHash {
    <#
    .SYNOPSIS
        Computes a SHA256 hash of the given text content.

    .DESCRIPTION
        Used to detect whether a file has changed since last indexing.
        If the hash matches the previously stored hash, we skip re-embedding
        that file (saves time on incremental updates).

    .PARAMETER Content
        The text content to hash.

    .OUTPUTS
        A lowercase hex string representing the SHA256 hash.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Content)
    $hashBytes = $sha256.ComputeHash($bytes)
    $hashString = [BitConverter]::ToString($hashBytes) -replace '-', ''
    return $hashString.ToLower()
}

# ============================================================================
# EMBEDDING GENERATION (OLLAMA API)
# ============================================================================

function Get-Embedding {
    <#
    .SYNOPSIS
        Generates a vector embedding for the given text using Ollama.

    .DESCRIPTION
        Sends text to the Ollama /api/embeddings endpoint and returns a
        768-dimension float array (vector). This vector represents the
        "meaning" of the text numerically, so similar text produces
        similar vectors.

    .PARAMETER Text
        The text to generate an embedding for.

    .PARAMETER OllamaEndpoint
        The Ollama server URL. Default: loaded from config.json.

    .PARAMETER Model
        The embedding model name. Default: loaded from config.json.

    .OUTPUTS
        An array of 768 floating-point numbers (the embedding vector).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [string]$OllamaEndpoint,

        [string]$Model
    )

    # Load defaults from config if not provided
    if (-not $OllamaEndpoint -or -not $Model) {
        $config = Get-KBConfig
        if (-not $OllamaEndpoint) { $OllamaEndpoint = $config.embedding.ollamaEndpoint }
        if (-not $Model) { $Model = $config.embedding.model }
    }

    # Sanitize text: replace problematic Unicode chars and control chars
    # PowerShell 5.1's ConvertTo-Json doesn't handle these well
    $cleanText = $Text -replace '[^\x20-\x7E\r\n\t]', ' '
    $cleanText = $cleanText.Trim()

    if ($cleanText.Length -eq 0) {
        Write-Warning "Text is empty after sanitization, skipping."
        return $null
    }

    $payload = @{
        model  = $Model
        prompt = $cleanText
    } | ConvertTo-Json

    try {
        $response = Invoke-RestMethod `
            -Uri "$OllamaEndpoint/api/embeddings" `
            -Method Post `
            -Body $payload `
            -ContentType "application/json"

        if ($response.embedding -and $response.embedding.Count -gt 0) {
            return $response.embedding
        }
        else {
            Write-Warning "Ollama returned empty embedding for text: $($Text.Substring(0, [Math]::Min(50, $Text.Length)))..."
            return $null
        }
    }
    catch {
        Write-Error "Failed to generate embedding: $($_.Exception.Message)"
        return $null
    }
}

# ============================================================================
# COSINE SIMILARITY (SEARCH / QUERY MATCHING)
# ============================================================================

function Get-CosineSimilarity {
    <#
    .SYNOPSIS
        Calculates cosine similarity between two embedding vectors.

    .DESCRIPTION
        Cosine similarity measures how similar two vectors are on a scale
        of -1 to 1, where:
          1.0  = identical meaning
          0.0  = completely unrelated
         -1.0  = opposite meaning

        Used during search to rank which stored embeddings are most
        relevant to a user's query.

    .PARAMETER VectorA
        First embedding vector (array of floats).

    .PARAMETER VectorB
        Second embedding vector (array of floats).

    .OUTPUTS
        A float between -1 and 1 representing similarity.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [double[]]$VectorA,

        [Parameter(Mandatory = $true)]
        [double[]]$VectorB
    )

    if ($VectorA.Count -ne $VectorB.Count) {
        throw "Vectors must be the same length. Got $($VectorA.Count) and $($VectorB.Count)."
    }

    $dotProduct = 0.0
    $magnitudeA = 0.0
    $magnitudeB = 0.0

    for ($i = 0; $i -lt $VectorA.Count; $i++) {
        $dotProduct += $VectorA[$i] * $VectorB[$i]
        $magnitudeA += $VectorA[$i] * $VectorA[$i]
        $magnitudeB += $VectorB[$i] * $VectorB[$i]
    }

    $magnitudeA = [Math]::Sqrt($magnitudeA)
    $magnitudeB = [Math]::Sqrt($magnitudeB)

    if ($magnitudeA -eq 0 -or $magnitudeB -eq 0) {
        return 0.0
    }

    return $dotProduct / ($magnitudeA * $magnitudeB)
}

# ============================================================================
# EMBEDDING STORE (SAVE / LOAD)
# ============================================================================

function Save-EmbeddingStore {
    <#
    .SYNOPSIS
        Saves an embedding store (collection of embeddings + metadata) to JSON files.

    .DESCRIPTION
        Writes the embedding data to both:
        1. Local storage (C:\Stacker\knowledge-base) for fast query access
        2. Repository backup (tools/knowledge-base/embeddings/) for version control

    .PARAMETER StoreName
        Name of the store (e.g., "source-code", "documentation", "app-logs").
        Used as the JSON filename.

    .PARAMETER Entries
        Array of hashtables, each containing:
          - Id: unique identifier (typically file path + chunk index)
          - FilePath: source file path
          - ChunkIndex: which chunk of the file (0-based)
          - Content: the original text content
          - ContentHash: SHA256 hash of the full file content
          - Embedding: the 768-dimension float array
          - Metadata: hashtable of additional info (last modified, doc type, etc.)

    .PARAMETER LocalStoragePath
        Path to local storage directory. Default: from config.json.

    .PARAMETER RepoBackupPath
        Path to repository backup directory. Default: from config.json.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StoreName,

        [Parameter(Mandatory = $true)]
        [array]$Entries,

        [string]$LocalStoragePath,

        [string]$RepoBackupPath
    )

    $config = Get-KBConfig

    if (-not $LocalStoragePath) {
        $LocalStoragePath = $config.storage.localPath
    }
    if (-not $RepoBackupPath) {
        $RepoBackupPath = Join-Path $PSScriptRoot "..\embeddings"
    }

    # Build the store object
    $store = @{
        storeName   = $StoreName
        createdAt   = (Get-Date).ToString("o")
        entryCount  = $Entries.Count
        modelName   = $config.embedding.model
        dimensions  = $config.embedding.dimensions
        entries     = $Entries
    }

    $json = $store | ConvertTo-Json -Depth 10

    # Save to local storage
    if (-not (Test-Path $LocalStoragePath)) {
        New-Item -ItemType Directory -Path $LocalStoragePath -Force | Out-Null
    }
    $localFile = Join-Path $LocalStoragePath "$StoreName.json"
    $json | Out-File -FilePath $localFile -Encoding utf8 -Force
    Write-Host "  Saved to local storage: $localFile" -ForegroundColor Gray

    # Save to repository backup
    if (-not (Test-Path $RepoBackupPath)) {
        New-Item -ItemType Directory -Path $RepoBackupPath -Force | Out-Null
    }
    $repoFile = Join-Path $RepoBackupPath "$StoreName.json"
    $json | Out-File -FilePath $repoFile -Encoding utf8 -Force
    Write-Host "  Saved to repo backup: $repoFile" -ForegroundColor Gray
}

function Get-EmbeddingStore {
    <#
    .SYNOPSIS
        Loads an embedding store from local storage.

    .DESCRIPTION
        Reads a previously saved embedding store JSON file. Used by:
        - Indexers: to check content hashes and skip unchanged files
        - Query scripts: to search across stored embeddings

    .PARAMETER StoreName
        Name of the store to load (e.g., "source-code", "documentation").

    .PARAMETER LocalStoragePath
        Path to local storage directory. Default: from config.json.

    .OUTPUTS
        The deserialized store object, or $null if the store doesn't exist.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StoreName,

        [string]$LocalStoragePath
    )

    if (-not $LocalStoragePath) {
        $config = Get-KBConfig
        $LocalStoragePath = $config.storage.localPath
    }

    $storeFile = Join-Path $LocalStoragePath "$StoreName.json"

    if (-not (Test-Path $storeFile)) {
        Write-Verbose "Embedding store '$StoreName' not found at $storeFile"
        return $null
    }

    $store = Get-Content $storeFile -Raw | ConvertFrom-Json
    return $store
}

# ============================================================================
# SEARCH HELPER
# ============================================================================

function Search-EmbeddingStore {
    <#
    .SYNOPSIS
        Searches an embedding store for entries most similar to a query.

    .DESCRIPTION
        Takes a query string, generates its embedding, then compares it
        against all entries in the store using cosine similarity. Returns
        the top K most similar results above the similarity threshold.

    .PARAMETER Query
        The natural language query to search for.

    .PARAMETER StoreName
        Name of the embedding store to search.

    .PARAMETER TopK
        Number of top results to return. Default: from config.json (5).

    .PARAMETER SimilarityThreshold
        Minimum similarity score to include. Default: from config.json (0.7).

    .OUTPUTS
        Array of results sorted by similarity (highest first), each with:
          - Score: cosine similarity (0-1)
          - FilePath: source file
          - Content: the matching text chunk
          - Metadata: additional info
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Query,

        [Parameter(Mandatory = $true)]
        [string]$StoreName,

        [int]$TopK,

        [double]$SimilarityThreshold
    )

    $config = Get-KBConfig
    if (-not $TopK) { $TopK = $config.query.topK }
    if (-not $SimilarityThreshold) { $SimilarityThreshold = $config.query.similarityThreshold }

    # Generate embedding for the query
    $queryEmbedding = Get-Embedding -Text $Query
    if (-not $queryEmbedding) {
        Write-Error "Failed to generate embedding for query."
        return @()
    }

    # Load the store
    $store = Get-EmbeddingStore -StoreName $StoreName
    if (-not $store) {
        Write-Warning "Embedding store '$StoreName' not found."
        return @()
    }

    # Compare query embedding against every entry in the store
    $results = @()
    foreach ($entry in $store.entries) {
        $entryEmbedding = @($entry.embedding)
        if ($entryEmbedding.Count -eq 0) { continue }

        $similarity = Get-CosineSimilarity -VectorA $queryEmbedding -VectorB $entryEmbedding

        if ($similarity -ge $SimilarityThreshold) {
            $results += @{
                Score      = [Math]::Round($similarity, 4)
                FilePath   = $entry.filePath
                ChunkIndex = $entry.chunkIndex
                Content    = $entry.content
                Metadata   = $entry.metadata
            }
        }
    }

    # Sort by similarity score descending, take top K
    $results = $results | Sort-Object { $_.Score } -Descending | Select-Object -First $TopK

    return $results
}

# ============================================================================
# EXPORT MODULE MEMBERS
# ============================================================================

Export-ModuleMember -Function @(
    'Get-KBConfig',
    'Import-EnvFile',
    'Split-TextIntoChunks',
    'Get-ContentHash',
    'Get-Embedding',
    'Get-CosineSimilarity',
    'Save-EmbeddingStore',
    'Get-EmbeddingStore',
    'Search-EmbeddingStore'
)
