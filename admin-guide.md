# Classroom AI Cluster — Administrator Guide

This is the **server-side** setup guide. It covers building, running, and maintaining the three-machine inference cluster. Students get their own document — hand out [`student-guide.md`](student-guide.md) for the client-side setup (Continue, opencode, or GitHub Copilot BYOK) and the Coolify deploy lab. The front-end host also runs Coolify for student app deployments — see [`coolify-runbook.md`](coolify-runbook.md).

The cluster is a load-balanced, fault-tolerant AI inference deployment across two GPU inference machines (each with 2× NVIDIA RTX Pro 6000 Blackwell GPUs, 96 GB VRAM per card) and a front-end host with 4× NVIDIA A6000 GPUs that also runs Coolify (student PaaS) and TLJH (JupyterHub). It uses **vLLM** for native FP8 inference and a single **LiteLLM** proxy on the front-end host for cross-engine load balancing and failover, without requiring any network-admin permissions (no VIP, no shared DNS, no L4 load balancer).

Because each GPU card has 96 GB of VRAM, workloads are split:

- **Chat** runs on **GPU 0** of each GPU machine using a large coder model.
- **Inline autocomplete** runs on **GPU 1** of each GPU machine using a smaller FIM-native model. Autocomplete is latency-critical and small; running it against the big chat model wastes latency and throughput.

Redundancy is layered:

- **Centralized load balancing.** A single LiteLLM proxy on the front-end host (rigel.cs.byu.edu) lists both GPU machines' chat engines as one pool and both FIM engines as another. Requests fan out across castor and pollux automatically, keeping both hosts busy without any client-side coordination.
- **Engine-level failover.** If a vLLM engine crashes — or a whole GPU host goes offline — LiteLLM routes to the surviving engine transparently. Students see nothing worse than a slightly slower first response.
- **Single client-facing endpoint.** Every student's editor points at `http://ml-capstone.cs.byu.edu:4000/v1` regardless of role. No Group A / Group B split anymore — load balancing is done server-side.

The one failure mode that's now class-wide is a **front-end host outage**: if rigel.cs.byu.edu is down, every student loses proxy access. Recovery is a manual client-config edit pointing directly at a raw vLLM engine on castor or pollux — see §3 and the recovery section in the Student Guide.

---

## 1. System Architecture & Traffic Flow

```
+-----------------------------------------------------------------------------------+
|                                STUDENT WORKSTATIONS                               |
|                                                                                   |
|     [ VS Code + Continue / opencode / Copilot BYOK ]                              |
|                          |                                                        |
|                          | chat + autocomplete                                    |
|                          | (single endpoint for the whole class)                  |
|                          v                                                        |
+--------------------------+--------------------------------------------------------+
                           |
                           v
        +------------------+-------------------+
        |   FRONT-END HOST (rigel.cs.byu.edu)   |
        |   4× NVIDIA A6000 GPUs                |
        |                                       |
        |  +-------------------------------+    |
        |  | LiteLLM Proxy (Port 4000)     |    |
        |  |   classroom-chat pool:        |    |
        |  |     castor :8000 + pollux :8000|    |
        |  |   classroom-autocomplete pool:|    |
        |  |     castor :8010 + pollux :8010|    |
        |  +---------------+---------------+    |
        |  + Coolify (student app deploys, GPUs)|
        |  + TLJH (JupyterHub via qsynology)    |
        +------------------+--------------------+
                           |
              balanced fan-out to both GPU hosts
              +-----------+-----------+
              |                       |
              v                       v
+---------------------------------------+   +---------------------------------------+
|          CASTOR (castor.cs.byu.edu)        |   |          POLLUX (pollux.cs.byu.edu)        |
|                                       |   |                                       |
|  +-------------+     +-------------+  |   |  +-------------+     +-------------+  |
|  | vLLM :8000  |     | vLLM :8010  |  |   |  | vLLM :8000  |     | vLLM :8010  |  |
|  | Chat model  |     | FIM model   |  |   |  | Chat model  |     | FIM model   |  |
|  | GPU 0 (96G) |     | GPU 1 (96G) |  |   |  | GPU 0 (96G) |     | GPU 1 (96G) |  |
|  | Qwen3-Coder |     | Qwen2.5-    |  |   |  | Qwen3-Coder |     | Qwen2.5-    |  |
|  | -Next-FP8   |     | Coder-7B    |  |   |  | -Next-FP8   |     | Coder-7B    |  |
|  +-------------+     +-------------+  |   |  +-------------+     +-------------+  |
+---------------------------------------+   +---------------------------------------+
```

No tensor parallelism — each model owns its GPU. This removes the per-layer all-reduce overhead of TP=2 and lets each workload scale KV cache independently. The specific model names in the diagram (`Qwen3-Coder-Next-FP8`, `Qwen2.5-Coder-7B`) reflect the default `qwen3-coder` install profile; the architecture is model-agnostic — see §2 for how to pick a different profile.

---

## 2. Server Setup — GPU Hosts (castor and pollux)

The GPU hosts run only vLLM. The LiteLLM proxy lives on the front-end host and is documented separately in [`coolify-runbook.md`](coolify-runbook.md) §5.

### Prerequisites

Before running the install script, each GPU machine needs:

- Ubuntu 22.04 or newer (24.04 recommended).
- A working NVIDIA driver (`nvidia-smi` returns without error).
- **CUDA Toolkit 13.0 installed at `/usr/local/cuda`** (matches torch 2.11's build). Without this, vLLM's vendored DeepGEMM can't locate CUDA at import time and the FP8 chat engine crashes at first inference. Install via:

    ```bash
    cd /tmp
    wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
    sudo dpkg -i cuda-keyring_1.1-1_all.deb
    sudo apt update
    sudo apt install -y cuda-toolkit-13-0
    ```

    The installer preflights for `/usr/local/cuda*` and refuses to run without it.
- At least two GPUs visible to the OS. The installer auto-detects and pins each engine to a card by UUID.
- LAN reachability from the **front-end host (rigel.cs.byu.edu)** on TCP **8000** (chat) and **8010** (FIM). The front-end's LiteLLM connects out to these ports directly. Students never talk to the GPU hosts directly.
- The two scripts shipped with this guide (`install-qwen-cluster.sh` and `uninstall-qwen-cluster.sh`) copied to each host.

### Choosing a model

The installer ships with named **profiles** for tested chat + autocomplete combinations. List them:

```bash
./install-qwen-cluster.sh --list-profiles
```

Currently included:

| Profile           | Chat model                                | Autocomplete model     | Notes |
|-------------------|-------------------------------------------|------------------------|-------|
| `qwen3-coder`     | `Qwen/Qwen3-Coder-Next-FP8`               | `Qwen/Qwen2.5-Coder-7B` | Default. Recommended coder-focused setup. |
| `qwen3-coder-30b` | `Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8`   | `Qwen/Qwen2.5-Coder-7B` | Fallback if `Next` isn't in your vLLM release yet. |
| `glm-45-air`      | `zai-org/GLM-4.5-Air-FP8`                 | `Qwen/Qwen2.5-Coder-7B` | GLM chat, Qwen FIM (GLM lacks FIM training). |

You can also pass any Hugging Face repo id directly with `--chat-model` / `--fim-model`, plus per-engine vLLM flags via `--chat-extra-args` and `--fim-extra-args`. See `--help` for the full option list.

**Add a new profile** by editing `install-qwen-cluster.sh` — add the name to `KNOWN_PROFILES`, then add matching branches to `_apply_profile` (model + args + max-len) and `_profile_desc` (short description).

### Install

The GPU-host install is handled by `install-qwen-cluster.sh`. It installs vLLM under `/opt/qwen-cluster`, pre-downloads the chosen models, writes two systemd units, and enables them as daemons that autostart on boot. The script is idempotent — re-running it (including with a different `--profile`) is safe and is the intended way to swap the running model. The front-end LiteLLM proxy lives on rigel and is documented in [`coolify-runbook.md`](coolify-runbook.md) §5; the GPU hosts run only vLLM.

The installer auto-detects the two largest GPUs by VRAM and pins each vLLM engine to one by GPU UUID (via `CUDA_DEVICE_ORDER=PCI_BUS_ID` + `CUDA_VISIBLE_DEVICES=<uuid>`). Chat lands on the biggest card, FIM on the second — so castor's heterogeneous Blackwell + RTX 4090 layout and pollux's homogeneous 2× Blackwell layout both work with the same command. FIM's `--max-model-len` also auto-scales to the FIM card's VRAM (8k at <30 GB, 16k at <50 GB, 32k otherwise) so a small card doesn't OOM at KV-cache-hungry defaults.

**On each GPU machine:**

1. Copy `install-qwen-cluster.sh` to the box (`scp`, USB, whatever).
2. Run it as root:

    ```bash
    # Default profile (qwen3-coder):
    sudo ./install-qwen-cluster.sh

    # Explicit profile:
    sudo ./install-qwen-cluster.sh --profile glm-45-air

    # Custom model not covered by a profile:
    sudo ./install-qwen-cluster.sh \
        --chat-model deepseek-ai/DeepSeek-Coder-V2-Lite-Instruct \
        --chat-extra-args "--trust-remote-code"
    ```

    The startup summary prints which physical GPU each engine will use — eyeball it before it commits.

Each GPU machine ends up with two units:

| Unit                        | What it runs                          | Port | GPU (pinned by UUID)               |
|-----------------------------|---------------------------------------|------|------------------------------------|
| `qwen-chat.service`         | vLLM serving the chosen chat model    | 8000 | Largest-VRAM card on the host      |
| `qwen-autocomplete.service` | vLLM serving the chosen FIM model     | 8010 | Second-largest-VRAM card           |

The unit names stay `qwen-*` regardless of profile (they predate the multi-model support and are the systemd handle for the cluster).

**Verify** once each GPU machine finishes downloading and warming up (watch with `journalctl -u qwen-chat -f`):

```bash
# From the front-end host (rigel.cs.byu.edu), or any workstation with LAN access:
curl http://castor.cs.byu.edu:8000/v1/models   # castor chat
curl http://castor.cs.byu.edu:8010/v1/models   # castor FIM
curl http://pollux.cs.byu.edu:8000/v1/models   # pollux chat
curl http://pollux.cs.byu.edu:8010/v1/models   # pollux FIM

# The front-end LiteLLM (installed per Coolify runbook §5) is the student-facing endpoint:
curl http://ml-capstone.cs.byu.edu:4000/v1/models   # should list classroom-chat + classroom-autocomplete
```

**Full-stack verification.** A repeatable smoke test ships in the repo — run it from your laptop over VPN whenever you want to confirm the cluster is healthy:

```bash
./smoke-test-cluster.sh                       # LLM + Coolify UI + sentiment app (default deploy URL)
./smoke-test-cluster.sh -p 8100               # sentiment app at http://rigel.cs.byu.edu:8100 (host-port bypass, no DNS needed)
./smoke-test-cluster.sh --local               # sentiment app on localhost:8000 (for local docker run)
./smoke-test-cluster.sh --no-sentiment        # skip the sentiment section entirely
```

It runs 14 checks: LiteLLM chat + FIM (with the actual prompt and model output printed so you can eyeball quality), direct-to-vLLM on both GPU hosts, Coolify UI reachability, and — if enabled — three sentiment classifications against the reference `sentiment-test-app/`. Every check runs even if earlier ones fail; exit code is non-zero on any failure.

The reference `sentiment-test-app/` (see its `README.md`) is a small FastAPI service that calls LiteLLM for sentiment classification. It's the canonical "test Coolify deploy" workload — build the Docker image via `docker build`, run locally, deploy to Coolify with a host-port mapping, or eventually via GitHub App push-to-deploy.

Manage the vLLM daemons with the usual `systemctl` verbs:

```bash
sudo systemctl status  qwen-chat qwen-autocomplete
sudo systemctl restart qwen-chat qwen-autocomplete
```

### Swapping to a different model

Because the front-end LiteLLM exposes stable aliases (`classroom-chat`, `classroom-autocomplete`), students' client configs keep working across model changes. Swapping the underlying model is a two-step process:

1. **On both GPU hosts**, re-run the installer with a different `--profile` (or `--chat-model` etc.):

    ```bash
    sudo ./install-qwen-cluster.sh --profile glm-45-air <peer-ip>
    ```

    The installer is idempotent — it downloads the new model (if not already cached), rewrites `/opt/qwen-cluster/config.yaml` and the systemd units with the new model + args, and `systemctl restart`s the services. The old model's weights stay in `/opt/qwen-cluster/hf-cache` (disk cost only) so switching back is a fast re-run.

2. **On the front-end host**, update `/etc/litellm/config.yaml` so its `model:` field references the new HF model id vLLM is now serving, and restart the container:

    ```bash
    sudo docker restart litellm
    ```

    If you skip step 2, the front-end LiteLLM will still route requests, but with the wrong model name in its upstream call — vLLM will 404 because it no longer serves the old model id.

### Rolling back a bad install

If something goes wrong and you want a clean slate, run `uninstall-qwen-cluster.sh` on the affected machine. It stops the services, removes their unit files, deletes `/opt/qwen-cluster`, removes the `qwen` user, and drops the ufw rules — reversing everything the installer did.

```bash
sudo ./uninstall-qwen-cluster.sh                # interactive; asks to confirm
sudo ./uninstall-qwen-cluster.sh -y             # non-interactive
sudo ./uninstall-qwen-cluster.sh --keep-models  # preserve /opt/qwen-cluster/hf-cache
```

The `--keep-models` flag is worth knowing about: the chat model download alone is many GB, so preserving the HF cache between install attempts saves a lot of time when iterating on config issues.

---

## 3. Architectural Advantages & Emergency Procedures

- **Right-sized model per workload.** A small FIM model on GPU 1 gives sub-100 ms ghost-text suggestions; the big chat model on GPU 0 keeps its throughput for the requests that actually need it.
- **No tensor-parallel overhead.** Each model owns its GPU, so there's no per-layer all-reduce between cards. Both engines run at TP=1.
- **Prefix caching.** `--enable-prefix-caching` retains reusable prefix KV state (shared system prompt, common assignment scaffolding) in GPU memory. When many students run the model against the same file, repeated evaluations drop to milliseconds.
- **Continuous batching.** vLLM dynamically batches independent student requests, so dozens of concurrent completions run without serializing.
- **Centralized failover.** A single vLLM engine crash — or a whole GPU host going offline — is invisible to students: the front-end LiteLLM has both hosts' engines in its pool and routes around the dead one automatically. No client-side reconfiguration needed. The engine restarts under systemd; LiteLLM's health checks pick it back up.
- **Front-end host failure (the new class-wide outage mode).** If rigel.cs.byu.edu goes down, every student loses `classroom-chat` and `classroom-autocomplete` at once. Recovery is a manual client-config edit pointing directly at one GPU host's raw vLLM engine — bypassing LiteLLM entirely. This means students also need to change the *model name* from the LiteLLM alias to the underlying HF id (e.g. `Qwen/Qwen3-Coder-Next-FP8`). Provide the fallback snippet below so they know what to paste.

### Emergency student fallback — front-end host is down

Direct-to-vLLM endpoints (no failover, no load balancing, but works if the front-end is dead):

- Chat: `http://castor.cs.byu.edu:8000/v1` or `http://pollux.cs.byu.edu:8000/v1` — model name `Qwen/Qwen3-Coder-Next-FP8` (or whatever profile is currently installed)
- Autocomplete: `http://castor.cs.byu.edu:8010/v1` or `http://pollux.cs.byu.edu:8010/v1` — model name `Qwen/Qwen2.5-Coder-7B`

Client edits by tool:
- **Continue:** `config.json` — change both `apiBase` values and both `model` values.
- **opencode:** `~/.config/opencode/opencode.json` — change `baseURL` and the model id under `models`.
- **Copilot Chat:** VS Code settings → `github.copilot.chat.customOAIModels` — change base URL and model id.
- **Copilot CLI:** `export COPILOT_PROVIDER_BASE_URL=http://castor.cs.byu.edu:8000/v1 COPILOT_MODEL=Qwen/Qwen3-Coder-Next-FP8`, then restart.

Once the front-end host is back up, students revert to `http://ml-capstone.cs.byu.edu:4000/v1` with the LiteLLM aliases — nothing else to reconfigure.

### Optional next step: speculative decoding

For any chat model that leaves substantial free VRAM on GPU 0 (Qwen3-Coder-Next-FP8 and GLM-4.5-Air-FP8 both do), you can enable vLLM speculative decoding by pairing the chat model (target) with a small draft model (e.g. `Qwen/Qwen2.5-Coder-1.5B`) on the same GPU. Big latency wins for chat, no extra hardware. Wire it up by adding the `--speculative-model` flags to `--chat-extra-args` when reinstalling. Do this once the base setup is stable.
