# Research Students — Using the Classroom LLM

You have access to a shared GPU cluster running an open-weights coding model. This
page covers the two ways to use it: **opencode**, an agentic assistant for your
terminal or desktop, and **calling it from Python**.

Nothing here involves Coolify, Docker, or deployment — that is the capstone
course's half of this cluster, and you can ignore it.

---

## What you have access to

| | |
|---|---|
| Endpoint | `http://ml-capstone.cs.byu.edu:4000/v1` |
| Model | `classroom-chat` |
| API style | OpenAI-compatible |
| Auth | none — the cluster is protected by the VPN, not by a key |
| Context window | 131,072 tokens |

It speaks the OpenAI API, so anything that talks to OpenAI talks to this: the
`openai` Python SDK, LangChain, LlamaIndex, `curl`, your own HTTP calls. Point the
base URL here and use `classroom-chat` as the model name.

> There is a second model, `classroom-autocomplete`. Ignore it. It is a
> fill-in-the-middle model for editor ghost-text — not instruction-tuned, no chat
> behaviour, and it will produce nonsense if you prompt it conversationally.

---

## Step 1 — Get on the CS VPN

The cluster is on the CS network and is not reachable from the public internet.

BYU runs two different VPN gateways, and they are **not** interchangeable:

| | Gateway | Reaches the cluster? |
|---|---|---|
| BYU campus VPN | `vpn.byu.edu` | **no** |
| **CS VPN** | **`cs-vpn.byu.edu`** | yes |

Install **GlobalProtect** from [vpn.byu.edu](https://vpn.byu.edu), then set the
**Portal** to `cs-vpn.byu.edu` and connect.

Check it works:

```bash
curl -sS http://ml-capstone.cs.byu.edu:4000/v1/models
```

You should get JSON listing `classroom-chat` and `classroom-autocomplete`.

If that hangs or fails while GlobalProtect says "Connected", you are almost
certainly on the campus gateway rather than the CS one. If `cs-vpn.byu.edu` rejects
you or does not appear in GlobalProtect at all, you have not been granted CS
network access — email your advisor or the cluster admin with your NetID. It is a
separate entitlement from your NetID, and it is not instant.

---

## Step 2 — Install opencode

[opencode](https://opencode.ai) is an agentic coding assistant: it reads your
files, proposes edits, and works through multi-step tasks. Similar to Claude Code,
but pointed at this cluster instead of a commercial API.

**macOS:**

```bash
brew install opencode                   # terminal
brew install --cask opencode-desktop    # optional GUI
```

**Windows** — install the desktop app from [opencode.ai/download](https://opencode.ai/download).
For the terminal version, install it inside **WSL**:

```bash
curl -fsSL https://opencode.ai/install | bash
```

**Linux:**

```bash
curl -fsSL https://opencode.ai/install | bash
```

---

## Step 3 — Point opencode at the cluster

Create `~/.config/opencode/opencode.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "classroom": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Classroom Cluster",
      "options": {
        "baseURL": "http://ml-capstone.cs.byu.edu:4000/v1",
        "apiKey": "sk-noauth"
      },
      "models": {
        "classroom-chat": {
          "name": "Classroom Chat",
          "limit": { "context": 131072, "output": 32768 }
        }
      }
    }
  }
}
```

**Where that file goes:**

| You installed | Path |
|---|---|
| macOS or Linux | `~/.config/opencode/opencode.json` |
| Windows **desktop app** | `%USERPROFILE%\.config\opencode\opencode.json` |
| Windows **terminal in WSL** | `~/.config/opencode/opencode.json` *inside WSL* |

> Running both the Windows desktop app and the WSL terminal? You need this file in
> **both** places — they have different home directories, so a config in one is
> invisible to the other.

Creating it:

```bash
mkdir -p ~/.config/opencode
nano ~/.config/opencode/opencode.json
```

```powershell
# Windows PowerShell, for the desktop app
mkdir -Force $env:USERPROFILE\.config\opencode
notepad $env:USERPROFILE\.config\opencode\opencode.json
```

### Then use it

- **Terminal:** run `opencode`, type `/models`, pick **Classroom Cluster › Classroom Chat**
- **Desktop app:** choose the same from the model picker
- **Browser:** `opencode web` starts a local server and opens a tab — same engine, no extra install

Try something agentic rather than conversational — *"what files are in this
directory and what does each one do?"* — since that exercises the tool-calling
path, not just chat.

---

## Step 4 — Call it from Python

### With the OpenAI SDK

```bash
pip install openai
```

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://ml-capstone.cs.byu.edu:4000/v1",
    api_key="sk-noauth",          # required by the SDK, ignored by the server
)

response = client.chat.completions.create(
    model="classroom-chat",
    messages=[
        {"role": "system", "content": "You are terse."},
        {"role": "user", "content": "Name three Python testing libraries, comma separated."},
    ],
    max_tokens=60,
    temperature=0.2,
)

print(response.choices[0].message.content)
print(response.usage.total_tokens, "tokens")
```

```
pytest, unittest, nose2
33 tokens
```

### Streaming

Worth using for anything long — you see output as it is produced instead of
waiting for the whole response:

```python
stream = client.chat.completions.create(
    model="classroom-chat",
    messages=[{"role": "user", "content": "Explain gradient descent in three sentences."}],
    stream=True,
)

for chunk in stream:
    if chunk.choices[0].delta.content:
        print(chunk.choices[0].delta.content, end="", flush=True)
print()
```

### Listing what is available

```python
print([m.id for m in client.models.list().data])
# ['classroom-chat', 'classroom-autocomplete']
```

### Without any dependencies

If you would rather not install anything:

```python
import json
import urllib.request

req = urllib.request.Request(
    "http://ml-capstone.cs.byu.edu:4000/v1/chat/completions",
    data=json.dumps({
        "model": "classroom-chat",
        "messages": [{"role": "user", "content": "Reply with exactly: pong"}],
        "max_tokens": 20,
        "temperature": 0,
    }).encode(),
    headers={
        "Content-Type": "application/json",
        "Authorization": "Bearer sk-noauth",
    },
)

with urllib.request.urlopen(req, timeout=60) as r:
    data = json.load(r)

print(data["choices"][0]["message"]["content"])
```

Every example on this page was run against the live endpoint.

---

## Things worth knowing

**It is a shared cluster.** Two GPU hosts behind a load balancer, serving a whole
class as well as you. A long batch job will slow other people down. If you need
sustained throughput for an experiment, talk to the admin first rather than
discovering the limits empirically.

**There is no authentication.** The `sk-noauth` key is decorative — the endpoint is
protected by being on the CS network, not by a secret. Don't put anything through
it you wouldn't put on a shared departmental machine.

**Prompts are not logged.** Logging is off, so nobody is reading your prompts — but
that also means nobody can recover them for you.

**The model may change.** `classroom-chat` is a stable alias in front of whatever
model is currently deployed. Your code keeps working across a swap, but exact
outputs will shift — so don't treat responses as reproducible across a semester.

**No VPN, no cluster.** There is no public route in. If you need access from off
campus, that is the VPN, not a firewall exception.

---

## When it does not work

| Symptom | Cause |
|---|---|
| `curl` hangs, GlobalProtect says "Connected" | On `vpn.byu.edu` instead of `cs-vpn.byu.edu` |
| `cs-vpn.byu.edu` rejects you or is missing from GlobalProtect | No CS network access yet — ask for it, with your NetID |
| `nslookup ml-capstone.cs.byu.edu` returns NXDOMAIN | VPN DNS is not resolving internal names |
| opencode shows no "Classroom Cluster" | Config file in the wrong place — see the table in step 3 |
| Model replies with nonsense | You selected `classroom-autocomplete`; use `classroom-chat` |
| `litellm.BadRequestError` mentioning `--enable-auto-tool-choice` | Server-side; report it to the admin |
