# The MCP tools server

The MCP tools server gives Emacs tools to the coding-agent instances (xref, imenu, tree-sitter, project information, and the tools that other files add).
It uses the MCP Streamable HTTP transport on `127.0.0.1`.
This document describes how a request finds its instance, how the server checks it, and the tools that this branch adds.

- Code: `claude-code-ide-mcp-server.el` (sessions, secrets, context, scopes) and `claude-code-ide-mcp-http-server.el` (HTTP).
- Tools: `claude-code-ide-emacs-tools.el`.
- Tests: `claude-code-ide-mcp-routing-tests.el`.
- Instances and providers: [session-schema.md](session-schema.md) and [providers.md](providers.md).

## Sessions

The server keeps one session for each registered key in `claude-code-ide-mcp-server--sessions`.

- A start of an instance registers its MCP session ID as the key, before the CLI starts.
- When an instance descriptor belongs to the key, the session records:
  - the instance ID,
  - the launch generation,
  - a new secret: 32 bytes from `/dev/urandom`, as 64 hexadecimal characters.
- **No weak secrets.** If Emacs cannot read 32 bytes from `/dev/urandom`, the registration signals an error that names the device. There is no fallback, and the global random generator is not used.
- A key without a descriptor (for example the `cowork` session of a user configuration) has no secret. Only the global token of that configuration protects it. A request reaches it only by its exact key.
- A request can name a session with a secret by its key or by its instance ID.
- `claude-code-ide-mcp-server-unregister-session` removes the session. Its ID is then unknown, and its requests get 403. When a newer launch of the same instance ID owns the instance ID, the newer route stays.

## Requests

### The URL

| URL | Meaning |
|---|---|
| `/mcp` | No session. Only a request with the coordinator credential may use it. Other requests get 403. |
| `/mcp/<id>` | The session `<id>`, a key or an instance ID. The secret, if the session has one, must be in the header. |
| `/mcp/<id>/<secret>` | The same, with the secret in the path. |

An unknown `<id>`, or the `<id>` of a session that ended, gets 403, with or without a secret.

### The headers

| Header | Value |
|---|---|
| `X-Emacs-MCP-Instance-Secret` | The secret of the instance (`claude-code-ide-mcp-server-secret-header`). |
| `X-Emacs-MCP-Coordinator` | The coordinator credential (`claude-code-ide-mcp-server-coordinator-header`). |
| `X-Emacs-MCP-Token` | The global token of `rp-emacs-mcp.el`, a user configuration. The package does not check it; the advice of that configuration does. |

Do not use `Authorization: Bearer`. The web-server package fails on that header.

### The check

The order is:

1. The advice of a user configuration on `claude-code-ide-mcp-http-server--handle-post` runs first. For example, it checks the global token, the `Origin`, and the `Host`.
2. **Requests from web pages** (`claude-code-ide-mcp-http-server--transport-refusal`). These checks run before the body is read:
   - A request with an `Origin` header gets 403. A browser adds this header; local MCP clients send none.
   - A request whose `Content-Type` is not `application/json` (parameters such as `; charset=utf-8` are allowed) gets 415. A web page can send this type only after a CORS preflight. The server never answers a preflight, and its replies have no CORS header (no `Access-Control-Allow-Origin`).
3. `claude-code-ide-mcp-server-check-request`:
   1. A coordinator credential, when the request has one, must be right.
   2. A request without `<id>` needs the coordinator credential.
   3. `<id>` must name a registered session.
   4. A session with a secret needs the secret in the path or in the header. A secret in the path must be right. A secret in the header must be right. A right secret in one place does not excuse a wrong secret in the other.
   5. A session without a secret is reached only by its exact key, and the request must carry no secret.

A request that fails gets HTTP `403` (or `415` for the content type) and a JSON-RPC error with code `-32000` and the message `Forbidden: <reason>`.
The reasons are:

- `Origin header not allowed`, `Content-Type must be application/json`
- `missing session ID`, `unknown session`
- `missing instance secret`, `wrong instance secret`, `unexpected instance secret`
- `wrong coordinator credential`

Other rules:

- A failed notification also gets `403`, not `202`.
- No tool runs for a refused request.
- The secret is compared in a time that does not depend on its content.
- The debug log shows the path as `/mcp/<id>/<secret>`, never the secret.

### Replies

- A notification (a message without `id`) gets `202 Accepted` with no body and no content type. The MCP Streamable HTTP transport requires this, and Codex drops the connection on any other reply.
- A request gets `200` with a JSON-RPC result or error.
- No reply has a CORS header.

## The generated config

`claude-code-ide-mcp-server-get-config` gives the config for the CLI.
For the session of an instance, it names the instance ID and carries the secret.
The defcustom `claude-code-ide-mcp-server-secret-placement` chooses where the secret goes:

- `header` (the default):

  ```json
  {"mcpServers": {"emacs-tools": {"type": "http",
                                  "url": "http://localhost:PORT/mcp/<instance-id>",
                                  "headers": {"X-Emacs-MCP-Instance-Secret": "<secret>"}}}}
  ```

  - **The header keeps the secret out of `ps` only for a provider that passes header values through the environment.** Codex can do this with `env_http_headers`. Add the variable to `shell_environment_policy.exclude`, so that the shell commands of the model cannot read it.
  - **Claude Code does not keep it out of `ps` today.** The main file passes the whole config as `--mcp-config "<json>"` on the command line, so the argument list shows the header. That is a known gap of the main file: the config should go to a `0600` file.
- `path`: the URL is `http://localhost:PORT/mcp/<instance-id>/<secret>`, with no header. Every local program that can list processes can read the URL.

The server accepts the secret in both places, whatever the defcustom says.
A session without a secret keeps the URL `/mcp/<key>` and gets no secret header.

### Extra headers

`claude-code-ide-mcp-server-extra-headers` is the supported way to add headers, for example a global token.

- It is an alist of `(NAME . VALUE)`. NAME is a string or a symbol.
- VALUE is a string, or a function without arguments that returns the value (for example one that reads a token file). A nil value drops the header.
- `get-config` merges the extra headers first and the secret header last, in one `headers` entry. A later header with the same name (case does not matter) wins, so an extra header cannot replace the secret.

Example: `(setq claude-code-ide-mcp-server-extra-headers '(("X-Emacs-MCP-Token" . my-token-function)))`.

### Advice on the config (compatibility)

An older way to add headers is a `:filter-return` advice on `claude-code-ide-mcp-server-get-config`.
`rp-emacs-mcp.el` does this: it appends a second `headers` entry with its global token.
A JSON reader keeps only the last of two equal keys, so the secret would be lost.

The package therefore keeps its own advice, `claude-code-ide-mcp-server--merge-config-headers`, with depth `-100` (the outermost).
The body of `get-config` cannot see what an advice adds after it returns, so only an advice can merge that entry.
It runs after every other advice and merges the `headers` entries in order, with the same rule as above.
The result has one `headers` entry with the secret and the token.

## The context of a request

During a request:

- `claude-code-ide-mcp-request-instance-id` returns the instance ID, or nil.
- `claude-code-ide-mcp-server-coordinator-request-p` returns non-nil for a request with the coordinator credential.
- `claude-code-ide-mcp-server-get-session-context` returns a plist.

The plist has these keys:

| Key | Value |
|---|---|
| `:project-dir` | The project root of the descriptor, else the folder of the registration. |
| `:worktree` | The worktree of the descriptor, or nil when it is not known. |
| `:buffer` | The terminal buffer of the descriptor, else the buffer of the registration. |
| `:last-active-buffer` | The last file buffer of the worktree (see below), or nil. |
| `:instance-id`, `:generation`, `:provider` | From the descriptor. |
| `:start-time` | The time of the registration. |

- The plist never holds the secret.
- Only the descriptor of the same launch generation counts. A later launch of the same instance ID does not change the context of an older session.
- The selected window plays no part.
- `tools/call` binds `default-directory` to `:project-dir` around the tool, also around the advice of the tool function. `claude-code-ide-mcp-server-with-session-context` keeps that `default-directory` inside the buffer that it makes current. So a relative file name resolves in the caller's project.

### The last active buffer

- The last active buffer of a session changes only for a buffer that visits a file inside the worktree of its instance.
- The nearest folder above the file with a `.git` entry must be that worktree. So a file of a worktree that is nested inside it does not count.
- When the worktree is not known, the project folder of the session is the limit.
- **One tracker.** `claude-code-ide-mcp--track-active-buffer` (in `claude-code-ide-mcp.el`) is the only function in `post-command-hook` that tracks the active buffer:
  - It records the buffer for the IDE connection of each connected instance of the project, and updates the tools server session of that instance.
  - Then it calls `claude-code-ide-mcp-server-note-buffer` for every other tools server session. So an instance without an IDE connection (Codex) also gets its buffer.
  - The hook is on while an IDE session or a tools server session is registered. It is removed when neither is left.
- `claude-code-ide-mcp-server-update-last-active-buffer` applies the worktree rule for every caller. It returns non-nil when the buffer changed.

## Tool scopes

`claude-code-ide-make-tool` takes the key `:scope`:

- `instance` (the default): the tool runs for every request that passes the check.
- `coordinator`: the tool runs only for a request with the coordinator credential.

For any other request, a coordinator tool:

- does not show in `tools/list`,
- gives the result text `{"status": "unavailable", "reason": "coordinator-only"}` when it is called. This is a normal result, not an error. Its arguments are not checked.

Another value of `:scope` is an error.
`claude-code-ide-mcp-server-tool-scope` returns the scope of a spec.
A coordinator tool takes an explicit instance ID as an argument. It must not use the instance of the request as its target.

## The coordinator credential

### What the scope protects against

- **It protects against mistakes, and against other local clients.** An instance does not get the credential in its config, so it cannot call a coordinator tool by accident. A local program without the credential gets `coordinator-only` or 403.
- **It does not protect against an agent that runs as the same user and reads files.** Every instance runs as your user. An instance that reads the credential file (with a shell command, or with `emacs_eval`) can then send coordinator requests. The file mode `0600` stops other users only.
- So do not treat the coordinator scope as a security boundary between instances. The threat model is an open question for the user.

### The file

- **File:** `claude-code-ide-mcp-server-coordinator-credential-file`. The default (nil) is `coordinator-credential` in the report directory of the session registry. With the default registry settings, that is `~/.emacs-claude-code-ide-state-reports/coordinator-credential`.
- **One path.** `claude-code-ide-mcp-server--report-directory` computes the report directory from the two registry options (`claude-code-ide-session-registry-report-directory` and `claude-code-ide-state-file`), and from their defaults when the registry is not loaded. So the path is the same whether or not the registry is loaded. A test checks that it equals the registry's own function.
- **Value:** 64 hexadecimal characters, separate from every instance secret.
- **Made:** when the server starts and a coordinator tool is registered, or when a coordinator tool is registered while the server runs. The file gets mode `0600`. A new folder gets mode `0700`.
- **Kept:** across Emacs restarts, so that a coordinator keeps working.
- **Refused:** a file that does not belong to the user, or that the group or others can read. Emacs then shows a message, and no request is a coordinator request.
- **Replace it:** `M-x claude-code-ide-mcp-server-rotate-coordinator-credential`. Coordinators must read the file again.
- **Use it:** read the file, and send its content in the header `X-Emacs-MCP-Coordinator` to `/mcp`. If the user configuration checks a global token, send that header too.

A coordinator request to `/mcp/<id>` still needs the secret of that instance.

## `get_capabilities`

An instance tool. It returns JSON text.

Arguments:

| Argument | Meaning |
|---|---|
| `operation` (optional) | One provider operation, for example `fork` or `submit_prompt` (underscores or hyphens). |
| `instance_id` (optional) | Another instance. Only a coordinator request may name another instance. |

Results:

- Without `operation`:

  ```json
  {"instance_id": "<id>", "provider": "claude", "generation": 1,
   "capabilities": ["detect", "launch", "..."],
   "unavailable": [{"status": "unavailable", "capability": "fork"}]}
  ```

  `capabilities` lists the operations of `claude-code-ide-provider-operations` that the provider of the instance has. `unavailable` has one entry for each other operation.
- With `operation`: `{"status": "available", "capability": "<operation>"}`, or `{"status": "unavailable", "capability": "<operation>"}`. An unknown operation name is unavailable. The name is looked up with `intern-soft`, so a client string never makes a new symbol.
- No instance (a coordinator request to `/mcp` without `instance_id`): `{"status": "unavailable", "reason": "no-instance"}`.
- A provider that is not registered: `{"status": "unavailable", "reason": "unknown-provider", "provider": "<name>"}`.
- Another instance without the coordinator credential: `{"status": "unavailable", "reason": "coordinator-only"}`.

`claude-code-ide-mcp-capabilities` returns the same data as an alist, for Lisp callers.

## Compatibility with `rp-emacs-mcp.el`

- **The guard advice** on `claude-code-ide-mcp-http-server--handle-post` still runs first. The entry point keeps its name and its argument.
- **The token advice** on `claude-code-ide-mcp-server-get-config` still adds its header. The merge advice keeps the secret beside it. A future version of that configuration can use `claude-code-ide-mcp-server-extra-headers` instead.
- **The `cowork` session** registers itself with `claude-code-ide-mcp-server-register-session`. It has no descriptor, so it has no secret. Its bridge reaches it by its exact key, `/mcp/cowork`, with `Content-Type: application/json` and no `Origin`, so the new checks accept it. Its context advice on `claude-code-ide-mcp-server-get-session-context` still works, because tools call that function.
- **The approval advice** on `claude-code-ide-mcp-server-get-tool-names` is unchanged. `get_capabilities` is a new name in that list.
