# Rollback Runbook (Test/Prod)

**Scope:** Restore previous Stacker API IIS deployment when a new release causes downtime, major defects, or performance regression.

## Triggers
- API down or unstable after deploy
- Major functional regression with no quick fix
- Performance degradation >30% vs baseline

## Prerequisites
- Previous known-good artifact/build available in Azure DevOps
- Backup of current deployment folder taken during deploy
- For schema changes: pre-deployment DB backup available (Prod only)

## Steps (File/Artifact rollback)
1) Stop application pool:
   - `Stop-WebAppPool -Name "Stacker_Test"` or `Stop-WebAppPool -Name "Stacker_Production"`
2) Restore previous artifact to site path (from ADO artifact or the backup folder):
   - Overwrite `web.config`, binaries, and configs with the prior version
3) Start application pool:
   - `Start-WebAppPool -Name "Stacker_Test"` or `Start-WebAppPool -Name "Stacker_Production"`
4) Warm up and verify endpoints with Windows credentials:
   - `Invoke-WebRequest http://server:8080/health -UseDefaultCredentials`
   - `Invoke-WebRequest http://server:8080/api/ai/health -UseDefaultCredentials`
   - Adjust host/port for Test

## Steps (Database rollback) — only if schema change broke Prod
1) Stop application pool for the affected site.
2) Restore database from the pre-deployment backup.
3) Re-deploy the previous known-good artifact (matching that schema).
4) Start application pool and verify endpoints.

## Verification Checklist
- `/` and `/health` return 200
- `/api/ai/health` returns 200 (Ollama reachable)
- No new errors in Windows Event Viewer (Application) or `logs/Stacker-*.log`
- If relevant, quick functional smoke test of the first app once available

## Notes
- Keep correlation IDs and timestamps from failing calls for postmortem.
- If rollback fails, stop and escalate before retrying.
