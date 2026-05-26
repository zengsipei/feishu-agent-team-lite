# Manual 1Panel Deploy Gate

The 1Panel deployment stage is a human-operated gate, not remote CI/CD access and not an Agent-run server operation. Release Agent may review evidence, request explicit approval, and coordinate Feishu or GitHub workflows, but the actual 1Panel start, recreate, rollback, or server configuration work remains manual because the deployed Agents run inside containers and should not directly operate the server that hosts them.
