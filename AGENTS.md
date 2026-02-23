## Secrets

### Disallowed

- Never read or attempt to read any of the files inside `data/secrets`.
- If an action absolutely requires it or indicentally results in requiring it, stop and inform the user and ask to proceed.

### Allowed

- Allowed to list them for agents when needed and assume resonable context from file names, but ALWAYS inform the user that you are listing them and NEVER read into the files directly or indirectly. 