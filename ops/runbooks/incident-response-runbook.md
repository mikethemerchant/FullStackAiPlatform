# Incident Response Runbook (API / AI Health)

**Scope:** Stacker API on IIS (Windows Auth). Focus on availability, 5xx errors, AI health failures, or slow responses.

## Quick Triage
1) Check health endpoints with Windows credentials:
   - `Invoke-WebRequest http://server:8080/health -UseDefaultCredentials`
   - `Invoke-WebRequest http://server:8080/api/ai/health -UseDefaultCredentials`
   - Adjust host/port for Test
2) If 401 from PowerShell: retry with `-UseDefaultCredentials`.
3) If 503/500: note correlation ID (if returned) and timestamp.

## Data to Collect
- Correlation ID, endpoint, status code, timestamp
- Recent entries from `logs/Stacker-*.log`
- Windows Event Viewer (Application) errors for AspNetCoreModuleV2 or Stacker
- App pool state (`Get-WebAppPoolState`) and recent recycle/stop events

## Remediation Steps
1) App pool down or hung: recycle/start
   - `Stop-WebAppPool -Name "Stacker_Test"` / `Start-WebAppPool -Name "Stacker_Test"` (or Prod pool)
2) Ollama unreachable: verify service
   - `Invoke-WebRequest http://localhost:11434` on the server
   - Restart Ollama service/process if needed
3) Config or deployment regression: consider rollback (see rollback runbook)
4) Persistent 5xx: capture logs and halt changes; avoid repeated restarts if errors persist

## Verification After Fix
- `/health` returns 200
- `/api/ai/health` returns 200 and shows correct model/endpoint
- No new errors in Event Viewer or Serilog logs during retest

## Escalation
- If Prod impact or unable to stabilize in 15 minutes, execute rollback
- Escalate with: correlation IDs, timestamps, error messages, and steps already taken
