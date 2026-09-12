# Local Coding Assistant — Setup & Usage

What this gives you: a fully offline coding assistant running on your own
GPU via Ollama, usable from the terminal (Aider, OpenCode, Cline CLI) and
inside VS Code (Cline extension). No API calls, no cost, no internet
required once models are downloaded.

## 1. Run the script

```powershell
powershell -File V:\projects\setup-local-coding.ps1
```

It's safe to re-run any time — it skips anything already installed/configured.

What it does:
1. Installs Ollama if missing (via winget), makes sure the server is running.
2. Picks (or downloads, prompting you to choose) a coding-focused model. On
   this machine it selects **`qwen3-coder`** — benchmarked as the best
   time/quality tradeoff for an 8GB GPU (see "Why these choices" below).
3. Installs Aider (`pip install --user aider-chat`) and writes a launcher
   script at `~\.local\bin\aider-local.ps1`.
4. Installs OpenCode (`npm install -g opencode-ai`) and writes a launcher
   script at `~\.local\bin\opencode-local.ps1`.
5. Installs the Cline extension into VS Code (also usable as `cline` CLI).
6. Adds `aider-local` and `opencode-local` functions to your PowerShell
   profile.

Use `-NonInteractive` to skip all prompts and take the defaults (fails
instead of prompting if something requires a choice it can't make safely,
like picking a model to download from scratch).

## 2. What YOU need to do after running it

### One-time: open a new PowerShell window
The `aider-local` and `opencode-local` functions were added to your
PowerShell profile (`$PROFILE.CurrentUserAllHosts`). They only take effect
in **new** shells — close and reopen PowerShell (or run
`. $PROFILE.CurrentUserAllHosts`) once.

### One-time: connect Cline to Ollama
Cline's provider setup is inside its own panel, not VS Code's Settings.

1. Click the **Cline icon** in the Activity Bar (the vertical icon strip
   on the far-left edge of VS Code) to open the Cline chat panel.
2. At the bottom of the Cline panel, click the harness selector (it may
   say "Local") and choose **Auto**.
3. Click **Other Models** to open the model/provider management view.
4. Click **Install Model Providers**, then select and install **Ollama**
   (choose the non-deprecated one if both are listed).
5. Go to **Manage** → **Language Models**. Your Ollama models should
   appear automatically (Cline detects them from the running server).
6. Select **`qwen3-coder`** as your active model.

That's it — Cline remembers this per-VS-Code-install, not per-project.

## 3. How to use it

### Aider (terminal)
From any project directory:
```powershell
aider-local
```
Opens an interactive Aider session using the local model against the files
in your current directory. Talk to it like you would Claude Code — ask it
to add a function, fix a bug, refactor a file, etc. It shows you a diff and
applies it directly.

One-shot / scripted usage (no interactive prompt):
```powershell
aider-local --message "Add input validation to parse_config in config.py"
```

To point at a *different* local model for one session (e.g. the smaller,
lighter qwen2.5-coder:14b):
```powershell
aider-local --model ollama/qwen2.5-coder:14b
```

### OpenCode (terminal — tool-calling agent)
From any project directory:
```powershell
opencode-local
```
Opens an interactive OpenCode session. Unlike Aider, OpenCode uses **native
tool-calling** — the model invokes file-write/read tools directly, like
Claude Code does. This was verified working with qwen3-coder (created a
file in 5.9s). Use it when you want an agent that can read, write, and
run commands autonomously.

One-shot usage:
```powershell
opencode-local --prompt "Add error handling to the database connection in db.py"
```

### Cline CLI (terminal)
From any project directory:
```powershell
cline
```
Opens Cline's terminal interface (the `@@` face). Dismiss the ClinePass
ad (press any key other than Enter) — you don't need it since you're
running a local model for free.

### Cline (VS Code)
Open the Cline panel in VS Code and chat with it like any AI coding
assistant — it reads/edits files in your open workspace using the local
model, same as Aider but inside the editor with inline diffs.

## 4. Why these specific choices (so you don't have to re-derive it)

**Why these four tools?**
Each uses a different approach to get the model to edit files:

- **Aider**: asks the model for plain-text diffs, parses them itself. Most
  mature, works with any model. Best for careful multi-file edits.
- **OpenCode**: uses native tool-calling (the model invokes write/read tools
  directly). Only works with qwen3-coder — older models (qwen2.5-coder,
  devstral, llama3.1) all failed this. Fastest for simple tasks (5.9s).
- **Cline CLI/VS Code**: uses XML-tagged actions, parses them itself. Good
  middle ground, works in both terminal and editor.
- **Claude Code + local model**: still fails. Claude Code's complex system
  prompt is too much for even qwen3-coder's tool-calling to handle reliably.

**Why `qwen3-coder` as the default model?**
Benchmarked directly on this machine (RTX 2070 Super, 8GB VRAM) with a real
task — implement an LRU cache with correctness assertions, via Aider, timed
end-to-end, output actually executed to confirm it's correct:

| Model | Time | Result | Notes |
|---|---|---|---|
| **qwen3-coder (30B)** | **54s** | **PASS** | **Fastest AND largest — new best** |
| qwen2.5-coder:14b | ~100–130s | PASS | Previous best, still a solid fallback |
| qwen2.5-coder:32b | ~240–390s | PASS | Correct but very slow on 8GB VRAM |
| deepseek-coder-v2:16b | — | FAIL | Couldn't conform to Aider's edit format |

qwen3-coder's newer architecture is dramatically more efficient — despite
being a 30B model (~18GB), it runs nearly twice as fast as the 14B Qwen 2.5
on the same hardware. It spills past 8GB VRAM into system RAM but the
architecture handles this gracefully.

## 5. Files this setup created

| Path | Purpose |
|---|---|
| `V:\projects\setup-local-coding.ps1` | The setup script itself (re-runnable) |
| `~\.local\bin\aider-local.ps1` | The `aider-local` launcher |
| `~\.local\bin\opencode-local.ps1` | The `opencode-local` launcher |
| PowerShell profile (`$PROFILE.CurrentUserAllHosts`) | `aider-local` and `opencode-local` functions |
| Cline VS Code extension | Installed globally in VS Code (also `cline` CLI) |

Nothing about your existing `claude` CLI, Anthropic login, or any other
tooling was touched — this is entirely additive.
