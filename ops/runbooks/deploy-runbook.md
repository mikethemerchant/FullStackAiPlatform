# Deploy Runbook (Test/Prod)

**Scope:** IIS-hosted Stacker API (ASP.NET Core 8) on Windows Server 2022 with Windows Auth. Covers Test and Prod deployments via Azure DevOps artifacts.

## Prerequisites
- Azure DevOps build artifact available (API package) and release approval granted
- Target server reachable and IIS running
- App pool and site created (Stacker_Test: port 8081, Stacker_Production: port 8080) or equivalent in your environment
- Credentials: domain account with deploy rights to target server and site folder
- Confirm .NET 8 Hosting Bundle and Web Deploy installed

## Inputs
- Build ID / artifact name and drop path
- Target environment: Test or Prod
- Expected appsettings (verify Ollama endpoint and logging paths)

## Steps
1) Backup current deployment folder (zip or copy) to a dated backup path.
2) (Prod only) Confirm DB backup completed if schema changes are included.
3) Stop application pool for target site:
   - `Stop-WebAppPool -Name "Stacker_Test"` or `Stop-WebAppPool -Name "Stacker_Production"`
4) Deploy artifact to site path (Web Deploy or file copy from artifact):
   - Ensure `web.config`, `Stacker.api.dll`, and `appsettings*.json` are updated.
5) Start application pool:
   - `Start-WebAppPool -Name "Stacker_Test"` or `Start-WebAppPool -Name "Stacker_Production"`
6) Warm up site by hitting root and health endpoints with Windows credentials:
   - `Invoke-WebRequest http://server:8080/ -UseDefaultCredentials` (Prod)
   - `Invoke-WebRequest http://server:8080/health -UseDefaultCredentials`
   - `Invoke-WebRequest http://server:8080/api/ai/health -UseDefaultCredentials`
   - Replace host/port for Test as needed.

## Verification
- Expect HTTP 200 on `/`, `/health`, `/api/ai/health`
- Check Serilog file logs under `logs/` for startup entries and correlation IDs
- Spot-check Windows Event Viewer (Application) for AspNetCoreModuleV2 errors
- Optional: run a basic API call used by the first app when available

## Common Issues
- 401 from PowerShell: add `-UseDefaultCredentials` (Windows Auth)
- 503: app pool stopped, missing DLL, or Ollama not reachable; check `/api/ai/health`, service status, and logs
- 500 on startup: review Windows Event Viewer and `logs/Stacker-*.log` for stack traces

## Escalation
- If Prod deploy fails and quick fix is unclear, stop and follow rollback runbook
- Capture correlation ID, timestamp, endpoint, and error message before escalating
