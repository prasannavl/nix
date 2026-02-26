## Secrets

### Disallowed

- Never read or attempt to read any of the files with `.key` extension inside the tree of `data/secrets`.
- If an action absolutely requires it or indicentally results in requiring it, stop and inform the user and ask to proceed.

### Allowed

- Allowed to list them for agents when needed and assume resonable context from file names, but ALWAYS inform the user that you are listing them and NEVER read into the files directly or indirectly. 

## Tasks management

- Use `docs/ai/` folder for documenting tasks and relevant pieces. 
- Use `docs/ai/notes` to store specific notes if user intervenes in a task to change / modify or change direction. Record these memories, keep a file specific to the task. 
- Use `docs/ai/index` to keep a top record of indexes of other `docs/ai/**` files so that 
  agents can look into this to figure out which ones to add into context.