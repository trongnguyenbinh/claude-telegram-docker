# Rule: every PR must Closes #issue + pass the gates + ship a migration

Required traceability chain: work item → branch/PR → commit → release → bug.

- Every PR ALWAYS has a **`Closes #<sub-task>`** line in its description.
- Commit using Conventional Commits (`feat:`, `fix:`, `docs:`, …).
- Branch from the integration branch (e.g. `dev`), named by area/task.
- **Schema change → ship a migration** (never edit the DB by hand); a destructive migration
  must be confirmed by the owner/lead before running against an environment with real data.
- **Don't merge into the integration branch until the gates pass:** quality + security checks
  (static analysis, secret scanning, dependency audit, code scanning).
- Don't self-merge PRs into protected/promotion branches (a human gate — reviewer/lead).
  Don't commit secrets.
