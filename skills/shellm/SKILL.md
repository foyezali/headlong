---
name: shellm
description: Reference for the shellm system — recursive LLM shell, identity management, memory, skills, trajectory, and all CLI tools. Use when working on shellm itself, debugging agent behavior, or understanding how the pieces fit together.
---

# shellm

> **This skill may be out of date.** The source of truth is always the code in `bin/`. If you find discrepancies, use the `skill-author` skill to update this file and open a PR.

## Architecture overview

shellm is a set of composable bash scripts that turn an LLM into an autonomous agent living in a shell. The stack, bottom to top:

```
llm              raw LLM calls (Anthropic, OpenAI, Gemini, ...)
shellm           recursive execute-in-shell loop on top of llm
traj / context   step log (DAG) + message assembly for multi-turn
mem / skills     persistent memory + learnable capabilities
identity         isolated agent identities (own mem, skills, traj)
thinkers / chat  autonomous thought processes + human conversation
recap            tiered rollup of a long trajectory, for context
```

An agent activates an identity (`source .identities/<name>/activate`), which sets env vars. All tools read from those env vars — no global config files.

## bin/ reference

### Core engine

| Script | Purpose |
|--------|---------|
| `shellm` | Recursive LLM-in-bash loop. Sends a prompt to the LLM, executes returned bash code blocks, feeds output back, repeats until `FINAL` is set. The heart of the system. |
| `llm` | Multi-provider LLM CLI. `llm [options] prompt` or stdin. Supports Anthropic, OpenAI, Gemini. Key flags: `-m MODEL`, `-s SYSTEM`, `-M MESSAGES_JSON`, `--stream`, `--thinking`. |

### Identity & activation

| Script | Purpose |
|--------|---------|
| `identity` | Manage isolated identities. Each has its own memories, skills, kernel, traj. Subcommands: `new`, `list`, `info`, `sync-kernel`, `sync-thinkers`, `default`, `delete`, `export`, `import`, `shell`, `prompt`. It lives in `tools/` and is on PATH. |

Activate an identity to set env vars for all other tools:
```bash
source .identities/myagent/activate   # activate in current shell
deactivate_identity                    # undo
identity shell myagent                 # or: start a subshell
```

### Thinking & conversation

| Script | Purpose |
|--------|---------|
| `thinkers` | The dispatcher for thought processes. `thinkers start`, `stop`, `status`, `list`, `step <name>`, `watch`, `new`, `logs`, `repl`. It watches trajectories and fires a thinker's `step` when a step type it subscribes to appears, plus `monolith-wake` on a timer. |
| `chat` | Conversation with people. `chat send` / `chat reply` write a `message` step and hand it to the outbound bridge; `chat repl` is a readline loop; `chat history`, `chat sent`, `chat pending` read the derived conversation indexes. |
| `recap` | Roll a trajectory up into themes and episodes. `recap --context` prints a budget bounded staircase (tiered rollups, newest steps verbatim); `--cached` never calls the model. |

### Memory & skills

| Script | Purpose |
|--------|---------|
| `mem` | File-based memory store (markdown + YAML frontmatter). `mem add --type TYPE <text>`, `mem search <query>`, `mem list`, `mem show <name>`, `mem forget <name>`, `mem edit <name> <text>`. |
| `skills` | Skill management. `skills install <src>`, `skills show <name>`, `skills promote <name>` (to kernel), `skills search <query>`, `skills remote add <path>`. |

### Trajectory & context

| Script | Purpose |
|--------|---------|
| `traj` | Trajectory operations (single-file and tree). Uses `TRAJ_DIR` + `TRAJ_ID`. `traj new`, `traj append`, `traj tail`, `traj cat`, `traj fork`, `traj merge`, `traj show`, `traj list`, `traj root`. `show` is unified: pass any ID (trajectory or step) and it searches all files in traj_dir. |
| `context` | Reads traj, outputs a JSON messages array for `llm -M`. Maps step types to assistant/user roles. Key flags: `--traj_dir`, `--tail N`, `--head N`, `--max-bytes`, `--pin <step_id>`. |

### Docker sandboxing

| Script | Purpose |
|--------|---------|
| `shellm-docker` | Constrained Docker facade for sandboxed execution. `run`, `build`, `ps`, `logs`, `rm`. It is not a pass-through for the docker CLI. |
| `tools/shellm-docker-broker` | Host-side broker that manages Docker containers for sandboxed shellm envs. |
| `tools/shellm-explore` | Read-only exploration tool (in `tools/`, not `bin/`). |

Everything under `tools/` runs *around* the mind rather than inside it and does
not count against the core line budget: `identity` (identity management, on
PATH), `headlong-skills` (the install/search/remote half of `skills`),
`headlong-init`, `headlong-killall`, `headlong-slack-bridge`,
`headlong-telegram-bridge`, `headlong-web`, `persona`, `pr-committee`.

## Key environment variables

These are set by `source .identities/<name>/activate`:

| Variable | Points to |
|----------|-----------|
| `IDENTITY_NAME` | Identity name (e.g. "andy") |
| `IDENTITY_DIR` | Identity root dir (e.g. `.identities/andy`) |
| `MEM_DIR` | `$IDENTITY_DIR/memories` |
| `SKILLS_DIR` | `$IDENTITY_DIR/skills` |
| `SKILLS_KERNEL_DIR` | `$IDENTITY_DIR/kernel` |
| `TRAJ_DIR` | `$IDENTITY_DIR/trajectories` |
| `TRAJ_ID` | UUID of root trajectory |
| `SHELLM_TRAJ_DIR` | Trajectory directory (default `$HOME/.shellm/trajectories`) |
| `SHELLM_ENVS_DIR` | Env/container state directory |
| `SHELLM_WORKDIRS_DIR` | Working directories base |
| `SHELLM_BROKER_DIR` | Docker broker state directory |
| `THINK_MODEL` | Model for thinker steps |
| `THINK_TICK_INTERVAL` | Seconds between autonomous ticks |
| `THINK_CONTEXT_TAIL` | Steps of context a thinker step reads (default 30) |
| `THINKERS_DIR` | Thinker registry for this identity |
| `ROOT_TRAJ_ID` | UUID of the root trajectory (`TRAJ_ID` points at it too) |
| `CHATRC` | This identity's chat config |

Other important vars (not identity-scoped):

| Variable | Purpose |
|----------|---------|
| `SHELLM_MODEL` | Default model for shellm |
| `ANTHROPIC_API_KEY` | Anthropic API key for llm |
| `OPENAI_API_KEY` | OpenAI API key for llm |

## Identity directory layout

```
.identities/<name>/
  info.txt                   name=, created=, root_trajectory=
  activate                   source-able activation script
  bootstrap-answers.txt      answers from identity new
  core_identity_prompt.md    (optional) custom system prompt
  .env                       (optional) identity-specific env vars
  memories/                  mem entries (markdown files)
  skills/                    installed skills (symlinked to the repo tree)
  kernel/                    kernel skills (listed, never inlined)
  thinkers/                  this identity's thinker dirs (symlinks)
  trajectories/              trajectory files; the root traj holds the mind
    <hex>-<slug>/trajectory.jsonl
    <hex>-<slug>/blobs/       spilled large fields
  chat/                      .chatrc and the derived message indexes
    messages.jsonl, deferrals.jsonl, deliveries.jsonl
  run/                       dispatcher state: active_thinkers, claimed,
                             dispatcher.pid, and per-thinker wake_at files
  retrieval/                 retrieval index (index.tsv, seen)
  usage/llm.jsonl            per-call model usage/cost log
  secrets/                   credentials the identity was given
  .shellm/                   envs, workdirs, docker-broker state
  workdir/                   working directory for thinker steps
```

## How a wake works

There is no `think` cycle any more. The main mind is the `monolith` thinker, one
shellm run per wakeup:

1. The dispatcher fires `monolith` when a step type it subscribes to appears
   (`observation`, `action`, `merge`) or when its own scheduled `monolith-wake`
   comes due.
2. `thinkers/monolith/step` assembles the wake prompt: the function menu from
   `thinkers/monolith/prompt.md`, the goals from mem, the tiered life summary
   from `recap`, and the recent trajectory.
3. It runs `shellm` once. The model picks one function (act, share, think,
   learn, recall, goals, values, idle), carries it out in bash, and sets `FINAL`.
4. The run's steps are appended to the trajectory. A plain `thought` step wakes
   `retrieval`; a pending chat request wakes the mind again.
5. Pacing lives in `run/<name>.wake_at`, armed in an EXIT trap. The delay is 0
   while engaged and backs off exponentially to a cap while nothing happens
   (see `design/monolith_backoff.md`).

## Thinkers

Thinkers live in `thinkers/` (symlinked per identity into
`.identities/<name>/thinkers/`). Each has a `step` script and a
`subscriptions.jsonl` naming the step types that wake it; `prompt.md` holds the
prompt. Only three ship today:

- **monolith** — the whole mind, one function per wakeup. Subscribes to
  `observation`, `action`, `merge`, `monolith-wake`; `trigger_self: false`, so
  its own steps never re-fire it.
- **responder** — immediate chat replies. Subscribes to `message`, writes an
  observation recording the decision, and can defer work it cannot do itself by
  appending an `action` for the monolith plus a deferral record.
- **retrieval** — surfaces related stored memories. Subscribes to `thought`,
  `message`, `observation`; it scores candidate memory files locally and does
  one small model call for the relations. Ships with a `disabled` marker and is
  only useful once its index has been built.

## Tips

- All tools are designed to be composed via pipes and env vars
- Nothing but `llm` speaks to a provider. `shellm` is the main caller, but a few
  tools make their own single `llm` call rather than paying for a whole shellm
  loop: `mem search` ranks its candidates directly, and `recap` summarizes with
  one. The rest build prompts and go through `shellm`.
- The `context` script is the bridge between traj (step log) and llm (messages
  array). `--max-bytes` is unset by default; `--tail-block` and `--block-limit`
  keep the rendered prefix stable so provider prompt caches stay warm
- Skills are loaded on demand with `skills show <name>`. Even kernel skills are only *listed* in the prompt, never inlined (see design/wake_prompt_cull.md)
- To understand any script's full interface, run it with `--help` or read the source in `bin/`
