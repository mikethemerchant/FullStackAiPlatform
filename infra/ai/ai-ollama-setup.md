# AI Integration - Ollama Setup

## Phase 1: Ollama Foundation

### Installation & Setup

**Installation Details:**
- **Product:** Ollama v0.14.2
- **Server:** server (Windows Server, Xeon Gold 6544Y, 32GB RAM)
- **Installation Type:** Windows application with system tray auto-start
- **API Endpoint:** http://localhost:11434
- **Launch Method:** Auto-starts on system login via Start menu shortcut
- **Network Scope:** Intranet-only (no external exposure)

### Model: Llama 3

**Model Specifications:**
- **Name:** llama3
- **Size:** ~4.7 GB
- **Download Date:** 2026-01-20
- **Storage Location:** `%USERPROFILE%\.ollama\models`
- **Inference Status:** ✅ Operational

**Performance Baseline (Initial Test):**
- **Query:** "What is .NET Core?"
- **Response Quality:** Excellent - comprehensive, accurate explanation
- **Test Date:** 2026-01-20
- **Response Type:** Streaming (real-time token generation visible)
- **Non-stream timing (warm):** ~14.4 s total (load_duration ~6.38 s, eval_duration ~7.55 s) for prompt "Summarize .NET Core in one sentence."
- **Streaming check:** `stream=true` works (prompt: "List three benefits of .NET Core.") — received NDJSON chunks; elapsed ~26.9 s (includes full stream capture)

### API Endpoints

#### Health Check
```
GET http://localhost:11434
```
Returns version and basic health info.

#### Completions (Generate Text)
```
POST http://localhost:11434/api/generate
Content-Type: application/json

{
  "model": "llama3",
  "prompt": "What is .NET Core?",
  "stream": false
}
```

**Response Format:**
```json
{
  "model": "llama3",
  "created_at": "2026-01-20T00:00:00Z",
  "response": "...",
  "done": true,
  "context": [...],
  "total_duration": 123456789,
  "load_duration": 12345678,
  "prompt_eval_count": 10,
  "prompt_eval_duration": 1234567,
  "eval_count": 50,
  "eval_duration": 111111111
}
```

**Streaming Response** (`"stream": true`):
Responses come as newline-delimited JSON objects, one token at a time.

### Model Management

#### List Available Models
```powershell
ollama list
```

#### Pull a New Model
```powershell
ollama pull llama3  # Already installed
ollama pull llama2  # Example: pull alternative model
```

#### Remove a Model
```powershell
ollama rm llama3
```

#### Run Interactive Mode
```powershell
ollama run llama3
```

### Windows Service Configuration

**Current Setup:** Auto-starts on login via Start menu shortcut running in system tray

**For Production Deployment:**
Consider using NSSM (Non-Sucking Service Manager) to register Ollama as a Windows service for more robust boot-time startup:
```powershell
# Install NSSM if needed
# Then register Ollama as service:
nssm install Ollama "C:\Users\user\AppData\Local\Programs\Ollama\ollama.exe" serve
nssm start Ollama
```

### Troubleshooting

#### Ollama Not Responding
1. Check if Ollama process is running: `Get-Process ollama`
2. Verify API endpoint: `curl http://localhost:11434`
3. Check Windows Firewall settings (ensure localhost access)
4. Restart from system tray icon

#### Model Download Issues
1. Check disk space (Llama 3 needs ~5GB total)
2. Verify internet connectivity
3. Try: `ollama pull llama3 --verbose`

#### High Memory Usage
- Llama 3 model runs in 8-bit quantized form (~4.7GB)
- With 32GB RAM on server, this is well-supported
- Monitor with: `Get-Process ollama | Select-Object WorkingSet`

#### API Timeouts
- Default timeout is generous
- For long responses, ensure client timeouts are > 60 seconds
- Stream responses for better UX on long queries

### Performance Expectations

**Hardware:** Xeon Gold 6544Y, 32GB RAM, Windows Server

**Llama 3 Performance:**
- Model load time: Varies on first request (5-10 seconds typically)
- Token generation: ~10-20 tokens/second (depending on context window)
- Typical response time (10-50 tokens): 2-5 seconds
- Memory footprint: ~5-6GB during inference

### Integration with Stacker API

**Architecture:**
- Stacker API (src/Stacker-api) calls Ollama via HTTP locally
- All requests logged with correlation IDs
- No external network calls needed
- Structured logging captures:
  - Model name
  - Query latency
  - Token counts
  - Temperature settings
  - Request correlation ID

**Health Check Integration:**
```
GET /api/ai/health → calls Ollama /api/endpoint
- Returns Ollama availability status
- Logged with correlation IDs
```

### Quick Reference Commands

**Check Status:**
```powershell
# Is Ollama running?
curl http://localhost:11434
$? # Checks if last command succeeded

# Process info
Get-Process ollama
```

**Common Operations:**
```powershell
# Test with a prompt (interactive)
ollama run llama3 "Your prompt here"

# List models
ollama list

# Pull a new model
ollama pull llama2  # or any model from https://ollama.ai/library

# Remove a model
ollama rm llama3

# Stop Ollama (from system tray menu) or:
Stop-Process -Name ollama
```

**API Testing (PowerShell):**
```powershell
# Health check
Invoke-WebRequest http://localhost:11434

# Generate (non-streaming)
$body = @{model="llama3"; prompt="Your prompt"; stream=$false} | ConvertTo-Json
Invoke-RestMethod -Uri http://localhost:11434/api/generate -Method Post -Body $body -ContentType "application/json"

# Generate (streaming) - outputs NDJSON chunks
Invoke-WebRequest -Uri http://localhost:11434/api/generate -Method Post -Body $body -ContentType "application/json" -UseBasicParsing
```

### Next Steps (Phase 2)

1. Create StackerAiConnector .NET library
   - HTTP client wrapper for Ollama
   - Async streaming support
   - Structured logging integration
2. Implement Stacker API endpoints
   - `/api/ai/health` - Health check
   - `/api/ai/generate` - Text generation with correlation ID
3. Add comprehensive error handling and retry logic
4. Performance monitoring and metrics

---

**Last Updated:** 2026-01-20  
**Status:** ✅ Phase 1 Complete - Ollama installed, Llama 3 model operational, API validated
