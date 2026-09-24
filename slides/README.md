# Slides

`Lecture2_CICD_IaC.pptx` — CI/CD, cloud deployment, and Infrastructure as Code.
Assumes Docker and GitHub have already been covered.

Built by `build_deck.py`, which opens `~/Downloads/Lecture1_MLOps_Intro.pptx`,
strips its slides, and rebuilds from the same master — so theme, fonts, and
layouts match the earlier deck exactly.

```bash
pip3 install python-pptx
python3 slides/build_deck.py
```

Edit the `.pptx` directly for one-off tweaks. Edit `build_deck.py` when you want
the change to survive a rebuild — particularly for the diagrams, which are laid
out with explicit inch coordinates and are tedious to nudge by hand.

## Diagrams

Four slides are drawn from shapes rather than bullets:

| Slide | What it shows |
|---|---|
| The System, End to End | laptop + Docker, GitHub + Actions, Coolify with staging and production, Traefik, users |
| One Push, Step by Step | the ten steps from `git push` to production, and where the gate is |
| Terraform's Four Ideas | provider / resource / state / plan→apply, and desired-vs-actual |
| Moving to a Different Provider | what changes vs what doesn't when you swap clouds |
