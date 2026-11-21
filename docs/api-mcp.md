# The MCP tools server

The MCP tools server gives Emacs tools to the coding-agent instances (xref, imenu, tree-sitter, project information, and the tools that other files add).
It uses the MCP Streamable HTTP transport on `127.0.0.1`.
This document describes how a request finds its instance, how the server checks it, and the tools that this branch adds.

- Code: `claude-code-ide-mcp-server.el` (sessions, secrets, context, scopes) and `claude-code-ide-mcp-http-server.el` (HTTP).
- Tools: `claude-code-ide-emacs-tools.el`.
- Tests: `claude-code-ide-mcp-routing-tests.el`.
  - The tests mock web-server, except the tests named `…-web-server-…`. Those run only when the web-server package is on the `load-path`, and they are skipped otherwise. `./scripts/compile-and-test.sh` adds the newest `~/.emacs.d/elpa/web-server-*` folder when there is one.
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

1. Before the body, the filter checks the head (see [The body](#the-body)), and the functions of `claude-code-ide-mcp-http-server-head-functions` run. After the body, the advice of a user configuration on `claude-code-ide-mcp-http-server--handle-post` runs first. For example, it checks the global token, the `Origin`, and the `Host`.
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

### The body

The filter of the connections (`claude-code-ide-mcp-http-server--filter`) reads each request before web-server sees it. **The filter is the authority.** It refuses every head that web-server could read in another way. It gives web-server exactly one request: the head and exactly `Content-Length` bytes of body.

- **Why.** The web-server package calls the handler as soon as the headers end, with the part of the body that has arrived until then. It does not read `Content-Length`. Python's `http.client` (and so `urllib`, and the stdio bridge of `rp-emacs-mcp.el`) sends the headers and the body in two writes. When Emacs reads the headers alone, the handler sees an empty or partial body.
  - Before this filter, such a request got a JSON-RPC error with `id` null (`End of file while parsing JSON`), and its tool did not run. A client that waits for its own `id` waited until its time limit. A client that was still sending got `Connection reset by peer`.
- **One place.** The filter is the only code that depends on how web-server reads a request (tested with web-server 20210708.2242). It calls `ws-filter` once. Every handler and every advice on a handler sees whole requests only. The filter keeps each part of the body as it comes, and joins the parts once.
- **The head** (`claude-code-ide-mcp-http-server--parse-head`) gets 400 when web-server could read it in another way:
  - A lone CR or LF outside the CRLF line breaks. web-server would start a new line there, for example a request line `POST /mcp/…` that the filter did not see.
  - A request line that is not `METHOD PATH HTTP/x.y`, or a method that is not one of web-server's methods in upper case. web-server matches the method without case, so `post` would be a POST to web-server.
  - A header line that is not `NAME: VALUE` with one colon and one space. The value is all the text after `": "`, as web-server takes it, so `Content-Length:  5` (two spaces) is not a plain integer.
  - An `Authorization` header: web-server parses its value in its own way.
  - A header section above 64 KiB, or more than 100 header lines, gets 431, also when the head comes in one read.
  - **No interning.** The filter interns no header name of the input, so a client cannot fill the obarray. A name whose keyword exists (the server uses it, or loaded code names it) becomes that keyword; any other name stays an upper case string. The keywords that the server uses are in `claude-code-ide-mcp-http-server--known-headers`.
- **Checks before the body.** The filter runs these checks on the head, in this order. A refused request gets its reply at once, and no body is kept:
  0. The route. A path that is not `/mcp` or `/mcp/…` gets 404. A method other than POST gets 405, with the header `Allow: POST`. So no request without a session check collects a body or reaches web-server (web-server would intern its header names).
  1. A multipart or form `Content-Type` (`multipart/…`, `application/x-www-form-urlencoded`): 415. Two `Content-Type` headers: 400. web-server parses such bodies itself, and it uses the last `Content-Type`.
  2. For a POST to `/mcp…`: `Origin` and `Content-Type` (403, 415), and `claude-code-ide-mcp-server-check-request` (403), as in [The check](#the-check).
  3. The body length (`claude-code-ide-mcp-http-server--body-length`, the one parser of `Content-Length`):
     - `Transfer-Encoding` (for example `chunked`): 411. The server reads only `Content-Length`.
     - A POST without `Content-Length`: 411.
     - A `Content-Length` that is not plain digits, or two different values: 400.
     - A `Content-Length` above `claude-code-ide-mcp-http-server-max-body-bytes` (default 16 MiB): 413.
  4. The functions of `claude-code-ide-mcp-http-server-head-functions` (see below).
  - The reply of a refusal has a JSON-RPC error with `id` null. After the reply, the server ends its side of the connection and drops the data that still comes, so that the client does not lose the reply to a reset.
- **After the body.** Bytes after `Content-Length` bytes of body (for example a pipelined request) are dropped. If web-server leaves the connection open after it has the request, the filter answers 400 and closes it.
- **Connection limit.** At most `claude-code-ide-mcp-http-server-max-connections` connections (default 32) are open at once. A connection above the limit gets 503 at once and is closed. When connections close, new ones are served again.
- **Time limit.** A connection must send its whole request within `claude-code-ide-mcp-http-server-body-timeout` seconds (default 30). Then it gets 408 and is closed, and the filter forgets it. The limit also closes a connection that sends nothing.
- **`Expect: 100-continue`.** A request with this header and no body yet gets `HTTP/1.1 100 Continue` first. curl sends this header for a body of 1 MB or more. Without the reply, curl waits 1 s before it sends the body.
- **The handler.**
  - It uses the session check that the filter made on the head. It does not check, or read the coordinator credential, a second time.
  - It runs the transport checks again, as a cheap assertion that cannot disagree.
  - It reads `Content-Length` with the parser of the filter. A bad value, or a body shorter than the value, gets 400 and is never parsed. Without the filter, for example in a test, it makes the session check itself.

### Checks of a user configuration: `claude-code-ide-mcp-http-server-head-functions`

- **What it is.** An abnormal hook. Each function gets `METHOD` (upper case), `PATH` (without the query), and `HEADERS` (an alist from a keyword such as `:X-EMACS-MCP-TOKEN` to the value; a name whose keyword does not exist is an upper case string). It returns nil to let the request pass, or `(STATUS . REASON)` (or a `STATUS` alone) to refuse it.
- **When it runs.** In the filter, for every request that passes the built-in checks, before any body is read. The functions run until one refuses. A function that signals an error refuses with 500.
- **Why.** An advice on `claude-code-ide-mcp-http-server--handle-post` runs only after the whole body has arrived. A check that needs only the head (a global token, the `Host`) belongs in this hook: a refused client then sends no body.
- **Example** (a token check like the guard of `rp-emacs-mcp.el`):

  ```elisp
  (add-hook 'claude-code-ide-mcp-http-server-head-functions
            (lambda (_method _path headers)
              (unless (equal (alist-get :X-EMACS-MCP-TOKEN headers) (rp-emacs-mcp-token))
                '(403 . "bad or missing token"))))
  ```

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

- **It protects against mistakes, and against other local clients.** Only an instance with the role `coordinator` gets the credential in its config (see below). So another instance cannot call a coordinator tool by accident. A local program without the credential gets `coordinator-only` or 403.
- **It does not protect against an agent that runs as the same user and reads files.** Every instance runs as your user. An instance that reads the credential file (with a shell command, or with `emacs_eval`) can then send coordinator requests. The file mode `0600` stops other users only.
- So do not treat the coordinator scope as a security boundary between instances. **Decision (user):** this is the intended threat model.

### The file

- **File:** `claude-code-ide-mcp-server-coordinator-credential-file`. The default (nil) is `coordinator-credential` in the report directory of the session registry. With the default registry settings, that is `~/.emacs-claude-code-ide-state-reports/coordinator-credential`.
- **One path.** `claude-code-ide-mcp-server--report-directory` computes the report directory from the two registry options (`claude-code-ide-session-registry-report-directory` and `claude-code-ide-state-file`), and from their defaults when the registry is not loaded. So the path is the same whether or not the registry is loaded. A test checks that it equals the registry's own function.
- **Value:** 64 hexadecimal characters, separate from every instance secret.
- **Made:** when the server starts and a coordinator tool is registered, when a coordinator tool is registered while the server runs, or when the config of a coordinator instance is generated. The file gets mode `0600`. A new folder gets mode `0700`.
- **Kept:** across Emacs restarts, so that a coordinator keeps working. **Decision (user).**
- **Refused:** a file that does not belong to the user, or that the group or others can read. Emacs then shows a message, and no request is a coordinator request.
- **Replace it:** `M-x claude-code-ide-mcp-server-rotate-coordinator-credential`. Coordinators must read the file again.
- **Use it:** read the file, and send its content in the header `X-Emacs-MCP-Coordinator` to `/mcp`. If the user configuration checks a global token, send that header too.

A coordinator request to `/mcp/<id>` still needs the secret of that instance.

### Coordinator instances

**Decision (user):** an instance that Emacs launches with the role `coordinator` gets the credential in its generated MCP config automatically.

- `claude-code-ide-mcp-server-get-config` reads the role from the instance descriptor of that launch generation (`claude-code-ide-instance-role`). The role is the string `"coordinator"`.
- The config then has the header `X-Emacs-MCP-Coordinator` beside the instance secret, in every secret placement. The instance uses its own URL `/mcp/<instance-id>`, so its requests pass both checks.
- No other session gets the header: not an instance with another role or no role, not a session without a descriptor (such as `cowork`), and not an older launch of an ID whose newer launch has the coordinator role.
- The same `ps` rule as for the secret applies. For Claude Code, the config is on the command line today, so `ps` shows the credential too.

### The `cowork` session

**Decision (user):** the `cowork` session of `rp-emacs-mcp.el` stays as it is. It has no own credential and no secret; the global token of that configuration protects it.

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

- **The guard advice** on `claude-code-ide-mcp-http-server--handle-post` still runs first. The entry point keeps its name and its argument. It runs after the whole body has arrived. The same check can move to `claude-code-ide-mcp-http-server-head-functions`, which refuses before the body (see [the example](#checks-of-a-user-configuration-claude-code-ide-mcp-http-server-head-functions)).
- **The token advice** on `claude-code-ide-mcp-server-get-config` still adds its header. The merge advice keeps the secret beside it. A future version of that configuration can use `claude-code-ide-mcp-server-extra-headers` instead.
- **The `cowork` session** registers itself with `claude-code-ide-mcp-server-register-session`. It has no descriptor, so it has no secret. Its bridge reaches it by its exact key, `/mcp/cowork`, with `Content-Type: application/json` and no `Origin`, so the new checks accept it. Its context advice on `claude-code-ide-mcp-server-get-session-context` still works, because tools call that function.
- **The approval advice** on `claude-code-ide-mcp-server-get-tool-names` is unchanged. `get_capabilities` is a new name in that list.
