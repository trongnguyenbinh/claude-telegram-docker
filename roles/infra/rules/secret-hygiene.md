# Rule: secret hygiene in infra operations

- Never print a token, key, password, or connection string to chat, a log file, or any
  file outside a proper secret store.
- Read secrets into shell variables (or a short-lived, tightly-permissioned env file);
  avoid putting them directly on a command line where they'd land in shell history or be
  visible via `ps`.
- Delete any temp file that held a secret immediately after it's no longer needed.
- If a secret leaks anywhere (chat, a public repo, a log, a screenshot) — tell the owner to
  rotate it right away; don't wait to be asked.
