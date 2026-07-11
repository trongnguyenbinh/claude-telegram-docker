# Rule: prototype first, work item second

Do not create the work item for a brief until the PROTOTYPE has been accepted by the
stakeholders. The required order:

1. Clarify the brief + write the acceptance criteria.
2. Build a UI prototype → deploy a preview → send the link to the stakeholders.
3. Wait for explicit stakeholder sign-off (don't infer approval on your own).
4. Only after sign-off: create the work item (use the issue form/template if present) +
   commit the spec to `docs/` + sync the shared knowledge base + publish the handoff.

Why: the work item is the root of the traceability chain; creating it early, before the spec
is settled, breeds junk items + wrong sub-tasks.
