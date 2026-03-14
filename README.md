# 🏠 Homelab-Ops: High-Availability Personal Cloud

A project focused on repurposing legacy hardware into a resilient, self-hosted data ecosystem. This repository serves as the "Source of Truth" for my home server infrastructure.

## 🚀 The Vision
To move away from fragmented SaaS dependencies by hosting a private instance of **Nextcloud** (File management) and **Immich** (Photo backup), managed via Docker and backed up across dual redundant HDDs.

## 🛠 Tech Stack
- **Compute:** Legacy Laptop (Ubuntu Server)
- **Orchestration:** Docker & Docker Compose
- **Storage:** Dual 2TB HDDs (Mounted via UUID for stability)
- **Second Brain:** Obsidian (Notes & Runbooks)

## 📖 Operational Runbooks
Detailed guides for recovery and maintenance can be found in the `/docs` folder:
- [Storage Recovery Runbook](./docs/recovery-runbook.md) - *What to do when the "Dirty Bit" strikes.*
- [System Architecture](./docs/architecture.md)
