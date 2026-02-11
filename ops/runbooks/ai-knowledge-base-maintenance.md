# AI Knowledge Base Maintenance Runbook

## Overview

The Stacker AI Knowledge Base stores vector embeddings of source code, documentation, application logs, and Azure DevOps pipeline data. These embeddings power the semantic search and RAG (Retrieval-Augmented Generation) query system.

This runbook covers day-to-day maintenance: how to rebuild, verify, troubleshoot, and monitor the knowledge base.

---

## Architecture Quick Reference

| Component | Location | Purpose |
|-----------|----------|---------|
| Embedding stores (live) | `C:\Stacker\knowledge-base\*.json` | Local JSON files used for queries |
| Embedding stores (backup) | `tools/knowledge-base/embeddings/` | Version-controlled copy in repo |
| Indexer scripts | `tools/knowledge-base/indexer/` | PowerShell scripts that build the stores |
| Query scripts | `tools/knowledge-base/query/` | Search and RAG scripts |
| Configuration | `tools/knowledge-base/config.json` | All settings (model, paths, thresholds) |
| Audit log | `C:\Stacker\knowledge-base\query-audit.log` | Log of all RAG queries |
| Ollama server | `http://server:11434` | Hosts nomic-embed-text (embeddings) and llama3 (chat) |

---

## Routine Maintenance

### Automated Updates (CI/CD)

Knowledge base updates run automatically as part of the Azure DevOps pipeline. After every successful deployment to Test, the `UpdateKnowledgeBase` stage executes:

1. `Index-SourceCode.ps1` — re-indexes changed `.cs`, `.csproj`, `.json` files
2. `Index-Documentation.ps1` — re-indexes changed `.md` files
3. `Index-ApplicationLogs.ps1` — indexes recent log files (90-day retention)
4. `Fetch-DevOpsData.ps1 -MaxRuns 20` — fetches latest pipeline runs

All scripts run in incremental mode (skip unchanged content). Typical duration: **2-5 minutes**.

The pipeline verifies all 4 store files exist after indexing. If any store fails to update, the stage fails and the pipeline sends a notification.

### Manual Full Rebuild

To rebuild the entire knowledge base from scratch (useful after major refactors or if stores become corrupted):

```powershell
cd tools\knowledge-base\indexer
Import-Module .\EmbeddingHelpers.psm1 -Force

# Full rebuild — forces re-embedding of all content
.\Index-SourceCode.ps1 -Force
.\Index-Documentation.ps1 -Force
.\Index-ApplicationLogs.ps1 -Force
.\Fetch-DevOpsData.ps1 -Force -MaxRuns 20
```

Expected duration for full rebuild: **15-30 minutes** (depends on repository size and Ollama response time).

### Manual Incremental Update

To update only changed content (same as what the CI/CD pipeline does):

```powershell
cd tools\knowledge-base\indexer
Import-Module .\EmbeddingHelpers.psm1 -Force

.\Index-SourceCode.ps1
.\Index-Documentation.ps1
.\Index-ApplicationLogs.ps1
.\Fetch-DevOpsData.ps1 -MaxRuns 10
```

---

## Verify Data Freshness

### Check Store File Timestamps

```powershell
Get-ChildItem "C:\Stacker\knowledge-base\*.json" | Select-Object Name, @{N='SizeKB';E={[Math]::Round($_.Length/1KB,1)}}, LastWriteTime | Format-Table
```

Expected output: all 4 files updated within the last pipeline run.

### Check Entry Counts

```powershell
$stores = @("source-code", "documentation", "application-logs", "devops-pipelines")
foreach ($store in $stores) {
    $file = "C:\Stacker\knowledge-base\$store.json"
    if (Test-Path $file) {
        $data = Get-Content $file -Raw | ConvertFrom-Json
        Write-Host "$store : $($data.entryCount) entries, created $($data.createdAt)"
    }
}
```

### Test a Query

```powershell
cd tools\knowledge-base\query
.\Search-KnowledgeBase.ps1 -Query "health check endpoint" -SimilarityThreshold 0.4
```

If results are returned, the knowledge base is functional.

---

## Retention Policies

| Store | Retention | Policy |
|-------|-----------|--------|
| Source code | Indefinite | Always keep; re-indexed on every change |
| Documentation | Indefinite | Always keep; re-indexed on every change |
| Application logs | 90 days | Logs older than 90 days are excluded during indexing |
| DevOps pipelines | 90 days | Pipeline runs older than 90 days are excluded |

Retention periods are configured in `tools/knowledge-base/config.json` under `storage.retentionDays`.

To change retention:
1. Edit `config.json` → `storage.retentionDays.logs` or `storage.retentionDays.devops`
2. Run the affected indexer with `-Force` to apply the new retention window

---

## Troubleshooting

### Indexing Fails with "Connection refused"

**Cause:** Ollama server is down or unreachable.

```powershell
# Test connectivity
cd tools\knowledge-base\indexer
Import-Module .\EmbeddingHelpers.psm1 -Force
.\Test-OllamaConnection.ps1
```

If the connection test fails:
1. Verify Ollama is running on `server`: `Invoke-WebRequest http://server:11434`
2. Check firewall rules allow port 11434
3. Restart Ollama service on the server if needed

### Indexing Fails with "401 Unauthorized" (DevOps)

**Cause:** Azure DevOps PAT expired or missing.

1. Check PAT is loaded: `$env:Stacker_DEVOPS_PAT.Length` (should return a positive number)
2. Verify `.env` file exists at repo root with `Stacker_DEVOPS_PAT=<token>`
3. Test PAT manually: `Invoke-RestMethod -Uri "https://dev.azure.com/company/_apis/projects?api-version=7.0" -Headers @{Authorization = "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$env:Stacker_DEVOPS_PAT")))"}`
4. If expired, create a new PAT in Azure DevOps with Build (Read), Release (Read), Code (Read) scopes

For CI/CD pipeline: ensure `Stacker_DEVOPS_PAT` is configured as a pipeline variable (secret) in Azure DevOps.

### Knowledge Base Returns Poor Results

**Symptoms:** Queries return irrelevant results or no results.

1. **Check threshold:** Default is 0.7. Try lowering: `.\Search-KnowledgeBase.ps1 -Query "your question" -SimilarityThreshold 0.4`
2. **Check data freshness:** Verify stores were recently updated (see "Verify Data Freshness" above)
3. **Force rebuild:** Run all indexers with `-Force` to regenerate embeddings
4. **Check chunk size:** If code files are very large, chunks may split important context. Review `config.json` → `embedding.chunkSize`

### Store File Corrupted

**Symptoms:** JSON parse errors when loading a store.

1. Delete the corrupted local file: `Remove-Item "C:\Stacker\knowledge-base\<store-name>.json"`
2. Copy from repo backup: `Copy-Item "tools\knowledge-base\embeddings\<store-name>.json" "C:\Stacker\knowledge-base\"`
3. Or rebuild from scratch: run the affected indexer with `-Force`

### Embedding Model Changed

If you switch from `nomic-embed-text` to a different model:

1. Update `config.json` → `embedding.model` and `embedding.dimensions`
2. **You must do a full rebuild** — old embeddings are incompatible with a new model
3. Run all indexers with `-Force`

---

## Monitoring

### Audit Log

All RAG queries are logged to `C:\Stacker\knowledge-base\query-audit.log`. Each line is a JSON object:

```json
{
  "timestamp": "2026-02-10T11:24:31Z",
  "correlationId": "493f853cd7f3",
  "question": "How do I check if Ollama is healthy?",
  "user": "WG34524",
  "machine": "D6RXFC4",
  "stores": "source-code,documentation,application-logs,devops-pipelines",
  "resultsCount": 5,
  "topScore": 0.6641,
  "model": "llama3",
  "durationMs": 52975,
  "answerLength": 1298
}
```

### Key Metrics to Watch

| Metric | Healthy Range | Action if Outside |
|--------|--------------|-------------------|
| Top similarity score | > 0.5 | If consistently low, content may be missing from KB |
| Query duration | < 60 seconds | If slow, check Ollama server load |
| Store file size | Growing over time | If shrinking, check retention or indexing errors |
| Entry count | Stable or growing | If dropping, check for indexing failures |

### Disk Space

Approximate storage requirements:
- Source code store: ~5-20 MB (depends on codebase size)
- Documentation store: ~5-15 MB
- Application logs store: ~2-10 MB (within retention window)
- DevOps pipelines store: ~1-5 MB
- Total: **~15-50 MB**

---

## Quick Reference Commands

```powershell
# Test Ollama connectivity
cd tools\knowledge-base\indexer
.\Test-OllamaConnection.ps1

# Incremental update (all stores)
Import-Module .\EmbeddingHelpers.psm1 -Force
.\Index-SourceCode.ps1
.\Index-Documentation.ps1
.\Index-ApplicationLogs.ps1
.\Fetch-DevOpsData.ps1 -MaxRuns 10

# Full rebuild (all stores)
.\Index-SourceCode.ps1 -Force
.\Index-Documentation.ps1 -Force
.\Index-ApplicationLogs.ps1 -Force
.\Fetch-DevOpsData.ps1 -Force -MaxRuns 20

# Search the knowledge base
cd ..\query
.\Search-KnowledgeBase.ps1 -Query "your question" -SimilarityThreshold 0.4

# Ask Stacker AI (full RAG)
.\Ask-StackerAI.ps1 "your question"

# Check store health
Get-ChildItem "C:\Stacker\knowledge-base\*.json" | Select-Object Name, @{N='SizeKB';E={[Math]::Round($_.Length/1KB,1)}}, LastWriteTime

# View recent queries
Get-Content "C:\Stacker\knowledge-base\query-audit.log" | Select-Object -Last 5 | ForEach-Object { $_ | ConvertFrom-Json } | Format-Table timestamp, question, topScore, durationMs
```
