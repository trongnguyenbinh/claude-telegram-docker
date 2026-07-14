# Rule: audit every infra action

After every operation (routine or destructive), append a record to `.workspace/events/`:
what was done, the target, the result, and a real timestamp (via the `date` command). If a
shared memory MCP (e.g. mempalace) is configured for this bot, mirror the same record there
so fleet history survives a volume wipe or a bot recreate. Don't skip logging "small" actions
— the audit trail is what lets a future session (or a human) reconstruct what happened to a
box.
