# Continue + classroom LiteLLM — testing playground

Small scratch workspace for eyeballing what the classroom cluster actually produces. Open **this folder** (not the parent `ml-capstone-platform/`) in VS Code, so the `.vscode/settings.json` here becomes the workspace-level config and forces Continue on / Copilot off just for this folder.

```bash
code ~/classes/BigData/ml-capstone-platform/test-playground
```

Everywhere else (other projects), your global preferences apply — Copilot on, Continue autocomplete off — so this workspace is the only place the classroom cluster does inline suggestions.

## Before you start

1. Connected to BYU VPN
2. Continue extension installed
3. `~/.continue/config.yaml` has the Classroom block from the Student Guide §Option 1 Step 3
4. Signed **out** of Continue Hub if you were auto-signed-in — Hub assistants shadow local config
5. This folder opened as the workspace root — the shipped `.vscode/settings.json` disables Copilot and enables Continue autocomplete only when this is the workspace root
6. Reload VS Code once after any of the above
7. Continue's current assistant is **Classroom** and the chat model chip shows **Classroom Chat**

Quick self-check before you dive into the exercises:

```
Cmd+L                    # opens Continue chat
```

Type "what is 2+2?" — you should see a Qwen response within a few seconds. If it fails, fix the setup before spending time judging code quality.

## What to test

### 1. `fib.py` — inline autocomplete (FIM)

Open the file, put your cursor at the `TODO` marker inside each function body, and wait ~1 second. Ghost-text should appear from `classroom-autocomplete` (Qwen2.5-Coder-7B). Press **Tab** to accept.

Good signals: reasonable-looking code, appears within a second or two, doesn't hallucinate imports or types that aren't in scope.

Bad signals: nothing appears (Continue not configured, VPN off, or Copilot still stealing the ghost-text), 30-second hang (FIM engine overloaded), completions that are always the same regardless of context.

### 2. `chat-prompts.md` — chat panel (`classroom-chat`)

Open Continue's chat panel (bottom left, or **Cmd+L**). Try each prompt in `chat-prompts.md`. Use `Cmd+L` or highlight-then-`Cmd+I` to include selected code as context.

Good signals: coherent multi-file reasoning, honors constraints in the prompt, uses the right idioms for the file's language.

Bad signals: repeats itself, ignores the code you highlighted, streams for 60+ seconds, tool-call errors.

### 3. `broken.py` — bug-fix workflow

Open, run it (`python broken.py`) and see the error. Highlight the whole file, `Cmd+L` to send to chat, ask "why does this crash and how do I fix it." Then accept or edit the suggested fix and rerun.

Good signals: diagnoses the root cause, produces a fix that actually runs, explains the fix concisely.

Bad signals: fixates on the symptom rather than the cause, invents error messages, "fixes" one bug while introducing another.

### 4. `hard-prompt.md` — the stress test

A single long prompt for the chat panel. Exercises long-context handling, structured output, and reasoning depth. Paste it all at once. Judge by whether the response covers everything the prompt asked for.

## Reporting back

If any of these misbehave, the useful shape of a bug report is:
- Which file / which prompt
- What the model returned
- What you expected instead
- Whether direct-to-vLLM (`http://castor.cs.byu.edu:8000/v1`) shows the same behavior — that separates LiteLLM routing bugs from actual model behavior
