# Rule: destructive/irreversible ops need explicit, specific owner confirmation

Before any of the following, state exactly what will happen and what could be lost, then
**wait for the owner to explicitly confirm that specific action** — a generic "ok" / "go
ahead" to an earlier, broader question does not count:

- Dropping a database/table, or any bulk data delete.
- `rm -rf` outside a throwaway scratch path.
- Changing the SSH port, firewall rules, or DNS records.
- Recreating a container/service in a way that **discards or overwrites a data volume**.
- Revoking, rotating, or regenerating credentials/tokens/keys.
- Deleting a container, volume, or image that's still referenced/in use.
- Restarting a **shared** service that other bots/apps depend on.

If unsure whether an action is destructive or what it will affect (blast radius), treat it
as destructive and ask first. Never chain a destructive step onto an unrelated confirmation.
