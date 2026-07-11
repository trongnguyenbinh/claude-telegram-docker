# Rule: every PR must Closes #issue + pass the gates

Required traceability chain: work item → branch/PR → commit → release → bug.

- Every PR ALWAYS has a **`Closes #<sub-task>`** line in its description (linking the PR back
  to the sub-task → back to the original brief).
- Commit using Conventional Commits (`feat:`, `fix:`, `docs:`, …).
- Branch from the integration branch (e.g. `dev`), named by area/task.
- **Don't merge into the integration branch until the gates pass:** quality + security checks
  (static analysis, secret scanning, dependency audit, code scanning). A failing gate → fix
  it, don't force.
- Don't self-merge PRs into protected/promotion branches (a human gate — reviewer/lead).
  Don't commit secrets.
