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
  - a new secret of 64 hexadecimal characters.
- A key without a descriptor (for example the `cowork` session of a user configuration) has no secret. Only the global token of that configuration protects it.
- A request can name a session by its key or by its instance ID.
- `claude-code-ide-mcp-server-unregister-session` removes the session. When a newer launch of the same instance ID owns the instance ID, the newer route stays.

## Requests

### The URL

| URL | Meaning |
|---|---|
| `/mcp` | No session. Tools that need a context answer "No session context available". Coordinators use this URL. |
| `/mcp/<id>` | The session `<id>`, a key or an instance ID. The secret, if the session has one, must be in the header. |
| `/mcp/<id>/<secret>` | The same, with the secret in the path. |

### The headers

| Header | Value |
|---|---|
| `X-Emacs-MCP-Instance-Secret` | The secret of the instance (`claude-code-ide-mcp-server-secret-header`). |
| `X-Emacs-MCP-Coordinator` | The coordinator credential (`claude-code-ide-mcp-server-coordinator-header`). |
| `X-Emacs-MCP-Token` | The global token of `rp-emacs-mcp.el`, a user configuration. The package does not check it; the advice of that configuration does. |

Do not use `Authorization: Bearer`. The web-server package fails on that header.

### The check

`claude-code-ide-mcp-server-check-request` decides. The order is:

1. The advice of a user configuration on `claude-code-ide-mcp-http-server--handle-post` runs first. For example, it checks the global token, the `Origin`, and the `Host`.
2. A coordinator credential, when the request has one, must be right.
3. A session with a secret needs the secret in the path or in the header.
4. A secret in the path must be right. A secret in the header must be right. A right secret in one place does not excuse a wrong secret in the other.

A request that fails gets HTTP `403` and a JSON-RPC error with code `-32000` and the message `Forbidden: <reason>`.
The reasons are `missing instance secret`, `wrong instance secret`, and `wrong coordinator credential`.
A failed notification also gets `403`, not `202`.
The secret is compared in a time that does not depend on its content.
The debug log shows the path as `/mcp/<id>/<secret>`, never the secret.

### Replies

- A notification (a message without `id`) gets `202 Accepted` with no body and no content type. The MCP Streamable HTTP transport requires this, and Codex drops the connection on any other reply.
- A request gets `200` with a JSON-RPC result or error.

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

  A provider can pass a header value through an environment variable (for Codex: `env_http_headers`). Then the secret does not show in the argument list of the CLI. Add the variable to `shell_environment_policy.exclude`, so that the shell commands of the model cannot read it.
- `path`: the URL is `http://localhost:PORT/mcp/<instance-id>/<secret>`, with no header. Every local program that can list processes can read the URL.

The server accepts the secret in both places, whatever the defcustom says.
A session without a secret keeps the URL `/mcp/<key>` and gets no header.

### Advice on the config

A user configuration can add headers with a `:filter-return` advice on `claude-code-ide-mcp-server-get-config`.
`rp-emacs-mcp.el` appends a second `headers` entry with its global token.
A JSON reader keeps only the last of two equal keys, so the secret would be lost.

The package therefore adds its own advice, `claude-code-ide-mcp-server--merge-config-headers`, with depth `-100` (the outermost).
It runs after every other advice and merges the `headers` entries in order.
A later header with the same name (case does not matter) wins.
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
- `claude-code-ide-mcp-server--track-buffer` runs in `post-command-hook` while a session is registered. It works for every instance, also one without an IDE connection (Codex).
- `claude-code-ide-mcp-server-update-last-active-buffer` applies the same rule. It returns non-nil when the buffer changed.

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

- **File:** `claude-code-ide-mcp-server-coordinator-credential-file`. The default (nil) is `coordinator-credential` in the report directory of the session registry. With the default registry settings, that is `~/.emacs-claude-code-ide-state-reports/coordinator-credential`.
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
- With `operation`: `{"status": "available", "capability": "<operation>"}`, or `{"status": "unavailable", "capability": "<operation>"}`. An unknown operation name is unavailable.
- No instance (for example a request to `/mcp`): `{"status": "unavailable", "reason": "no-instance"}`.
- A provider that is not registered: `{"status": "unavailable", "reason": "unknown-provider", "provider": "<name>"}`.
- Another instance without the coordinator credential: `{"status": "unavailable", "reason": "coordinator-only"}`.

`claude-code-ide-mcp-capabilities` returns the same data as an alist, for Lisp callers.

## Compatibility with `rp-emacs-mcp.el`

- **The guard advice** on `claude-code-ide-mcp-http-server--handle-post` still runs first. The entry point keeps its name and its argument.
- **The token advice** on `claude-code-ide-mcp-server-get-config` still adds its header. The merge advice keeps the secret beside it.
- **The `cowork` session** has no descriptor, so it has no secret. Its context advice on `claude-code-ide-mcp-server-get-session-context` still works, because tools call that function.
- **The approval advice** on `claude-code-ide-mcp-server-get-tool-names` is unchanged. `get_capabilities` is a new name in that list.
