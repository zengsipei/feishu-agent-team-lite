# Feishu Agent Team Services

This context names the operating boundaries for the Feishu Agent Team services and the 1Panel deployment flow. It exists to keep release, deployment, and Agent-team terms precise across runbooks.

## Language

**Agent Team**:
A set of eight independent Feishu Bot Apps that act as code R&D roles. The team is not tied to a single Feishu group; a project group may invite the relevant Agents it needs.
_Avoid_: one group, single project bot

**Project Group**:
A Feishu chat that represents one project workspace. It is where humans and selected Agent Team members exchange visible project messages.
_Avoid_: whole team, deployment environment

**Release Agent**:
An Agent Team role that reviews release evidence and coordinates external gates. It may request approval, trigger Feishu or GitHub workflows, and prepare checklists, but it is not a server operator.
_Avoid_: deployment robot, server operator

**Read-Only Pre-Check**:
A server evidence collection stage that verifies files, Compose config, ports, health, status files, logs, and backup prerequisites without changing server state.
_Avoid_: deployment, startup, migration

**Manual 1Panel Deploy Gate**:
A release stage where reviewed read-only evidence can authorize a human operator to perform the 1Panel deployment action after explicit approval. It does not authorize Agent-run server operations, remote CI/CD deployment, SSH execution, or automatic container control.
_Avoid_: remote CI/CD access, automatic server operation, Agent-run deployment

**Formal Deployment**:
The human-approved start, recreate, or equivalent 1Panel action performed by the operator after the Manual 1Panel Deploy Gate opens.
_Avoid_: pre-check, evidence review

**Off-Host Backup Target**:
A backup destination outside the target 1Panel server that can survive server loss or rollback mistakes. It must be known before Formal Deployment.
_Avoid_: local-only backup, same-host copy

**Rollback Owner**:
The human responsible for deciding and executing rollback if Formal Deployment or post-deploy checks fail.
_Avoid_: generic approver, runtime Agent

## Example Dialogue

Developer: The read-only pre-check is green. Can the Release Agent deploy now?

Domain expert: No. The Release Agent can move the evidence into the Manual 1Panel Deploy Gate and ask for explicit approval, but a human operator performs the 1Panel action.

Developer: Can it trigger a GitHub workflow?

Domain expert: Yes, for external systems when that is part of coordination. It still must not SSH into the 1Panel server, write server config, or restart containers.
