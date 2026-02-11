<#
.SYNOPSIS
    Tests connection to Ollama and verifies nomic-embed-text model is available.

.DESCRIPTION
    Validates that Ollama is running and the embedding model is pulled.
    This script should be run first before any indexing operations.

.EXAMPLE
    .\Test-OllamaConnection.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

# Load configuration
$configPath = Join-Path $PSScriptRoot "..\config.json"
$config = Get-Content $configPath -Raw | ConvertFrom-Json

$ollamaEndpoint = $config.embedding.ollamaEndpoint
$embeddingModel = $config.embedding.model
$localStoragePath = $config.storage.localPath

Write-Host "Testing Ollama connection..." -ForegroundColor Cyan

try {
    # Test Ollama endpoint
    $response = Invoke-RestMethod -Uri "$ollamaEndpoint/api/tags" -Method Get
    Write-Host "[PASS] Ollama is running at $ollamaEndpoint" -ForegroundColor Green
    
    # Check if nomic-embed-text is available
    $modelFound = $response.models | Where-Object { $_.name -like "nomic-embed-text*" }
    
    if ($modelFound) {
        Write-Host "[PASS] Model '$embeddingModel' is available" -ForegroundColor Green
        Write-Host "  Model details:" -ForegroundColor Gray
        Write-Host "    Name: $($modelFound.name)" -ForegroundColor Gray
        Write-Host "    Size: $([math]::Round($modelFound.size / 1MB, 2)) MB" -ForegroundColor Gray
        Write-Host "    Modified: $($modelFound.modified_at)" -ForegroundColor Gray
    } else {
        Write-Host "[FAIL] Model '$embeddingModel' not found" -ForegroundColor Red
        Write-Host ""
        Write-Host "To install the model, run:" -ForegroundColor Yellow
        Write-Host "  ollama pull nomic-embed-text" -ForegroundColor White
        Write-Host ""
        Write-Host "Available models:" -ForegroundColor Gray
        $response.models | ForEach-Object { Write-Host "  - $($_.name)" -ForegroundColor Gray }
        exit 1
    }
    
    # Test embedding generation
    Write-Host ""
    Write-Host "Testing embedding generation..." -ForegroundColor Cyan
    
    $testPayload = @{
        model = $embeddingModel
        prompt = "This is a test sentence for embedding generation."
    } | ConvertTo-Json
    
    $embedResponse = Invoke-RestMethod -Uri "$ollamaEndpoint/api/embeddings" -Method Post -Body $testPayload -ContentType "application/json"
    
    if ($embedResponse.embedding -and $embedResponse.embedding.Count -gt 0) {
        Write-Host "[PASS] Successfully generated test embedding (dimension: $($embedResponse.embedding.Count))" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] Failed to generate embedding" -ForegroundColor Red
        exit 1
    }
    
    # Check local storage path
    Write-Host ""
    Write-Host "Checking storage paths..." -ForegroundColor Cyan
    
    if (-not (Test-Path $localStoragePath)) {
        Write-Host "[WARN] Local storage path does not exist: $localStoragePath" -ForegroundColor Yellow
        Write-Host "  Creating directory..." -ForegroundColor Gray
        New-Item -ItemType Directory -Path $localStoragePath -Force | Out-Null
        Write-Host "[PASS] Created local storage directory" -ForegroundColor Green
    } else {
        Write-Host "[PASS] Local storage path exists: $localStoragePath" -ForegroundColor Green
    }
    
    $repoBackupPath = Join-Path $PSScriptRoot "..\embeddings"
    if (-not (Test-Path $repoBackupPath)) {
        Write-Host "[WARN] Repository backup path does not exist" -ForegroundColor Yellow
        Write-Host "  Creating directory..." -ForegroundColor Gray
        New-Item -ItemType Directory -Path $repoBackupPath -Force | Out-Null
        Write-Host "[PASS] Created repository backup directory" -ForegroundColor Green
    } else {
        Write-Host "[PASS] Repository backup path exists" -ForegroundColor Green
    }
    
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "All checks passed! Ready to index." -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    
} catch {
    Write-Host "[FAIL] Connection test failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "Troubleshooting steps:" -ForegroundColor Yellow
    Write-Host "1. Verify Ollama is running: Get-Process ollama" -ForegroundColor White
    Write-Host "2. Check Ollama endpoint: $ollamaEndpoint" -ForegroundColor White
    Write-Host "3. Pull the model: ollama pull nomic-embed-text" -ForegroundColor White
    exit 1
}