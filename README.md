# Enterprise Platform Modernization Reference Implementation (v7)

**Author:** Michael Bender  
**Stack:** React + TypeScript, .NET 8, EF Core, SQL Server, Azure DevOps, IIS / Azure App Service, Local AI (Ollama)  
**Date:** January 2026

---

# Executive Summary

Modern enterprises often migrate core systems to COTS platforms (ERP, CRM, HRIS), yet a long tail of legacy internal applications remains. These systems are frequently under-governed, inconsistently deployed, and operationally fragile.

This project is a **reference implementation of a Microsoft-first internal application platform** designed to:

- Modernize legacy applications using an API-first architecture  
- Standardize CI/CD and deployment governance  
- Implement structured logging and measurable performance baselines  
- Introduce AI-assisted DevOps triage using a local LLM  
- Reduce operational risk through explicit rollback and approval gates  

This is not a tutorial project. It is a production-oriented blueprint demonstrating how to build, govern, deploy, monitor, and evolve internal systems with enterprise discipline.

---

## YouTube video link: https://youtu.be/Xo6qMjg7wek

-----

# Business Outcomes (Phase 1 Baseline)

Phase 1 establishes measurable operational capability before application migration begins.

**Delivery Governance**
- YAML-based CI/CD pipelines with approval gates  
- Repeatable IIS deployments (Test + Production)  
- Version traceability from work item → PR → build → deployment  

**Operational Discipline**
- Structured logging with correlation IDs  
- Defined rollback decision matrix  
- Explicit production backup + restore procedures  
- Health endpoints + deployment validation checks  

**AI-Assisted DevOps (Local RAG Model)**
- Vectorized indexing of source code, documentation, logs, and pipeline history  
- Natural-language query interface for operational triage  
- Incremental embedding rebuild (<5 minutes) integrated into CI pipeline  

**Performance Baseline Established**
- API p95 target: <200ms  
- DB query p95 target: <100ms  
- Frontend load target: <1.5s  
- Performance regression blocking in CI/CD (>30% degradation)

This foundation enables reduced MTTR, safer deployments, and scalable modernization of remaining legacy systems.

---

# 1. Vision Statement

Create a fully integrated Microsoft-based application platform for internal business systems, enabling rapid deployment, maintainability, and AI-assisted automation.

The platform modernizes legacy applications into secure, web-based systems hosted on Windows Server using IIS, backed by Azure DevOps CI/CD pipelines and enhanced by a local AI triage agent.

Containers are supported but intentionally deferred to avoid premature architectural complexity.

---

# 2. Architectural Principles

- **API-first:** Business logic lives in the backend API; UI is replaceable.  
- **Identity-first:** Authentication externalized (Windows Integrated / Entra).  
- **Monolith-first:** Modular monolith preferred over premature microservices.  
- **Minimum viable platform:** Standardize logging + CI/CD before orchestration layers.  
- **Application-managed authorization:** Business roles owned by the app, not AD groups.

---

# 3. System Overview

| Layer | Technology | Purpose |
|--------|-------------|----------|
| Frontend | React + TypeScript | Modern decoupled UI |
| Backend API | ASP.NET Core (.NET 8) | RESTful API contract |
| Database | SQL Server 2022 | Relational data store |
| ORM | EF Core 8 | Data access + migrations |
| DevOps | Azure DevOps (YAML) | CI/CD + approvals |
| Hosting | IIS (Windows Server) | Controlled enterprise hosting |
| Observability | Serilog + OpenTelemetry | Structured logs + tracing |
| AI Layer | Local LLM (Ollama) | DevOps triage + RAG |

---

# 4. Security Model (Intranet-Oriented)

**Authentication**  
- Windows Integrated Authentication (Kerberos/Negotiate)  
- Transparent SSO for domain users  
- No login forms or token flows for intranet usage  

**Authorization**  
- Role-based access stored in SQL  
- Enforced exclusively in backend API  
- No dependency on AD group management  

**AI Access Controls**  
- Dev/Test: PR + pipeline interaction via service principal  
- Prod: Read-only logs + metrics  
- No secret exposure or bypass of approval gates  

---

# 5. Deployment Governance

| Stage | Trigger | Target |
|--------|----------|---------|
| Dev | Local build | IIS Express / Kestrel |
| CI | Commit / PR | Build + tests |
| Test | Merge to main | Test IIS |
| Prod | Approval gate | Production IIS |

Each deployment includes:
- Linked work items  
- Automated test execution  
- Artifact versioning  
- Health verification  
- Correlation-based logging  

Rollback is governed by:
- Mandatory database backup  
- Artifact retention  
- Severity-based decision matrix  

---

# 6. AI-Assisted DevOps (Local RAG)

The platform includes a local AI agent that indexes:

- Source code  
- Documentation  
- Structured logs  
- Azure DevOps pipeline history  

Capabilities:
- “Summarize last deployment failure.”  
- “Which endpoints use Windows Auth?”  
- “Show recent API errors with correlation IDs.”  

Knowledge base updates automatically on merge to `main`.

Measured baseline:
- Full index build: ~40 seconds (current repo size)  
- Incremental rebuild: ~4 seconds when unchanged  

---

# 7. Performance & Monitoring Baseline

Performance thresholds established in Phase 1 to detect regressions early.

| Metric | Target |
|--------|--------|
| API p95 | <200ms |
| DB Query p95 | <100ms |
| Frontend Load | <1.5s |
| Deployment Block Threshold | >30% degradation |

Performance regressions automatically block production deployment.

---

# 8. Testing Strategy

| Level | Tooling | Purpose |
|-------|---------|---------|
| Unit | xUnit | Code validation |
| Integration | WebApplicationFactory | API contract integrity |
| E2E | Playwright | Critical workflows |

Contract testing prevents breaking changes from impacting frontend consumers.

---

# 9. Roadmap

| Phase | Goal |
|--------|------|
| Phase 1 | Core infrastructure + AI foundation (Complete) |
| Phase 2 | First legacy app migration |
| Phase 3 | Centralized monitoring + decision trees |
| Phase 4+ | Scaled automation + controlled AI autonomy |

---

# 10. Implementation Status

### Phase 1 — Complete

- Azure DevOps repo + YAML pipelines  
- Branch policies + approval gates  
- IIS hosting validated  
- Windows Auth enabled  
- Structured logging + correlation IDs  
- Health endpoints  
- Local AI agent integrated  
- Knowledge base indexing + RAG queries  
- CI-triggered incremental embedding rebuild  

Phase 2 will migrate the first legacy application onto this platform foundation.

---

# Positioning Statement

This repository demonstrates end-to-end ownership of:

- Platform architecture  
- Deployment governance  
- Operational risk management  
- AI-assisted DevOps workflows  
- Enterprise-grade modernization strategy  

It reflects systems thinking beyond feature development — focusing on delivery maturity, stability, and scalable transformation.

---

**End of Document**

