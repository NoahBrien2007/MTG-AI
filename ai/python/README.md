# mtgai — the value network

A small PyTorch model that answers one question about a game state:

> **What is the probability that the player about to act wins this game?**

That single number is enough to make the AI noticeably stronger. `GreedyAgent`
already searches one ply ahead — it plays every legal action on a copy of the
state and scores the result with a hand-written formula (life difference, board
power, card count). Replacing that formula with a network trained on real games
is the smallest change that produces an agent which learned to play rather than
being told how.

Nothing here plays Magic by itself; it turns recorded games into a checkpoint,
and serves that checkpoint to Godot.

---

## Quick start

```bash
cd ai/python
python3 -m venv .venv
source .venv/bin/activate         # macOS / Linux
# .venv\Scripts\activate          # Windows — run this instead, on its own line
pip install -r requirements.txt

python -m mtgai.selftest          # 31 checks, no data needed (~15 s)
python -m mtgai.train             # trains on ../training/datasets/*.jsonl
python -m mtgai.evaluate          # calibration + accuracy report
python -m mtgai.serve             # http://127.0.0.1:8787 for a Godot agent
```

No recordings yet? In the game: **AI Training** → tick *Record training data* →
**Run**. A few hundred games is a reasonable first dataset; Heuristic vs Greedy
gives more varied positions than either agent against itself.

**Check the seat win rate before you train.** `train` and `evaluate` print it:

```
seat win rate: player 0 52.3%, player 1 47.7%
```

Anything past roughly 65/35 between two agents that are supposed to be
comparable means something is wrong — most likely one agent is not playing at
all. Note that the win/loss *decision* counts stay near 50/50 even then, because
each outcome is recorded relative to whoever was deciding, so they cannot tell
you this. At 95/5 the loader refuses to be quiet about it: a value network
trained on one-sided games learns "the seat that does things wins" and nothing
about play decisions.

To check the pipeline before generating real data:

```bash
python -m mtgai.train --smoke-test     # synthetic games, ~2 s
```

---

## Files

| file | what it does |
| --- | --- |
| `spec.py` | the encoding layout, mirroring `scripts/ai/state_encoder.gd` |
| `data.py` | loads `.jsonl` recordings, merges vocabularies, splits by game |
| `model.py` | `ValueNet` |
| `metrics.py` | accuracy, AUC, Brier score, calibration, accuracy per game stage |
| `train.py` | training entry point |
| `evaluate.py` | scores a checkpoint against a dataset |
| `export_onnx.py` | exports to ONNX for use outside Python |
| `policy.py` | `PolicyNet` — which action to take — plus its loader and training |
| `serve.py` | localhost HTTP server so a Godot agent can query the models |
| `vocab.py` | writes `ai/training/vocabulary.json` for the Godot encoder |
| `testdata.py` | synthetic datasets |
| `selftest.py` | self-checks for all of the above |

---

## The model

The state vector is 1110 floats, but it is not a flat blob: 37 numbers describe
the game as a whole (life totals, mana, phase, zone sizes, who is on the play)
and the remaining 1073 are 37 **card slots** of 29 numbers each — 10 for your hand, 12 for each
battlefield, 3 for the stack.

Feeding that flat into an MLP wastes capacity, because slot 3 of your
battlefield means exactly what slot 7 means. So instead:

```
card slot (29 floats) ─┐
                       ├─→ shared card encoder → 64 floats ─┐
card name → embedding ─┘                                    │
                                                            ├─ pool per zone (mean + max
                                                            │   over occupied slots)
global features (37) ───────────────────────────────────────┴─→ trunk → 1 logit → sigmoid
```

Three things fall out of that shape:

* **Permutation invariance.** Reordering cards inside a zone cannot change the
  prediction, so the model never has to learn the same pattern twice per slot.
  (`selftest.py` asserts this.)
* **A card lookup table.** The embedding gives every card name a learned vector,
  which is how the model can discover that Burst Lightning behaves differently
  from Island beyond what the 29 generic features say.
* **Masking.** The first feature of each slot is a "card is here" flag; empty
  slots are zeroed before pooling and excluded from the mean, so an empty board
  is not the same as a board full of 0/0s.

~186k parameters by default. Training on a few thousand decisions takes seconds
on a CPU; there is no reason to reach for a GPU until self-play datasets get
into the millions.

**Target.** Every decision in a game is labelled with that game's final result
from the acting player's point of view: win → 1, loss → 0, draw → 0.5, trained
with binary cross-entropy. Early-game states are therefore genuinely ambiguous
— a turn-one position is roughly a coin flip whatever you do — which is why the
report breaks accuracy down by game stage. Accuracy should climb steeply toward
the end of the game; if it is flat, the model is not learning position, it is
learning which deck goes first.

---

## Honest validation

Two details in `data.py` matter more than the architecture:

**Splitting by game, not by decision.** All 30 decisions in one game share a
label and are highly correlated. A random per-sample split puts near-duplicates
on both sides and reports a validation loss that flatters the model.
`split_by_game` keeps whole games together.

**Merging vocabularies by name.** Card ids are assigned in the order cards are
first encountered, so two recording sessions can number the same card
differently. Loading several files remaps every file's ids onto one shared
vocabulary; without this, training on two datasets would silently scramble the
embedding table.

For the same reason, training writes `ai/training/vocabulary.json`, and the
Godot `StateEncoder` reads it at startup so the running game numbers cards
exactly the way the model expects. Regenerate it with `python -m mtgai.vocab`
if it ever goes missing.

---

## Serving it to Godot

```bash
python -m mtgai.serve
```

```
POST /value
{"states": [{"features": [...1110 floats...], "card_ids": [...37 ints...]}, ...]}
→ {"values": [0.61, 0.48, ...]}
```

Send one request per decision containing every candidate state, not one request
per state — a searching agent evaluates every legal action, and the round trip
dominates the cost. A `ValueNetAgent` on the Godot side then looks like
`GreedyAgent` with `_evaluate_state()` replaced by a lookup into the response.

The Godot side of this is `scripts/ai/value_net_agent.gd` — `GreedyAgent` with
`_evaluate_state()` replaced by a batched call to `/value`, selectable as
**Value Net AI** in the Training screen and as an opponent in a normal game.
Start `serve` first; the Training screen probes `/health` before a series and
refuses to run without it, so a stopped server can never be mistaken for a weak
model. If the server dies mid-series the agent warns once and finishes on the
inherited heuristic — check the log for that warning before trusting a result.

`python -m mtgai.export_onnx` writes `ai/models/value_net.onnx` plus a sidecar
`.json` with the encoding spec, for when you would rather run inference inside
Godot via a GDExtension than talk to a Python process. (Needs `pip install onnx
onnxscript`; the HTTP path does not.)

---

## Dataset format

One JSON object per line. Line 1 is the header:

```json
{"format": "mtg-ai-samples-v1", "feature_count": 1110, "global_features": 37,
 "card_features": 29, "action_features": 19,
 "slots": {"hand": 10, "battlefield": 12, "stack": 3},
 "vocabulary": ["", "Island", "Opt", ...], "games": 200}
```

Every following line is one decision:

| field | meaning |
| --- | --- |
| `features` | the state vector, from the acting player's view (includes an "I am on the play" flag) |
| `card_ids` | one vocabulary index per card slot (0 = empty) |
| `legal` | one action vector per legal action |
| `legal_signatures` | canonical string per legal action |
| `chosen` | index into `legal` of the action actually taken |
| `outcome` | +1 the acting player won, −1 lost, 0 draw |
| `player`, `turn`, `game` | who decided, when, and in which game |

`legal` and `chosen` are unused by the value network — they are recorded so a
policy head (predict *which* action a strong player takes) can train on the
same files later.

---

## The policy network

`value_net.pt` answers "am I winning". `policy_net.pt` answers "what should I
play", and it is the one that picks moves well.

The difference is supervision. Outcome training labels every decision in a game
with that game's single result, so 2,000 games are 2,000 real signals spread
over 650,000 rows — measured here, the value net stopped improving after one or
two epochs however it was regularised, and playing greedily on it lost 94 games
in 100 against the agent that produced its data. `chosen` labels each decision
individually against the ~25 other legal actions of that same position: the
same files, three hundred times the supervision, aimed at the actual question.

```bash
python -m mtgai.policy --smoke-test    # synthetic, should approach 100%
python -m mtgai.policy                 # trains on ../training/datasets
python -m mtgai.serve --policy-checkpoint checkpoints/policy_net.pt
```

Watch **agreement**: the share of held-out positions where the network picks
the same move as the agent that recorded them. Chance is about 4%. The
`--max-per-game` flag exists because the whole dataset with its padded action
matrices needs several gigabytes; decisions inside one game are near-duplicates
anyway, so sampling costs little.

A policy trained this way tops out at the strength of whoever recorded. What it
buys is the move ordering that makes real search affordable — thirty candidates
narrowed to three worth looking at.

## What comes after this

1. **Measure it.** `ValueNetAgent` exists; run it against Greedy on the Training
   screen, ~200 games, recording off. That win rate is the whole point — if the
   model does not beat the formula whose games it was trained on, more epochs
   will not fix it.
2. **Deeper search.** With a value function, 2–3 ply beats 1 ply substantially.
   `duplicate_state()` already makes lookahead cheap.
3. **Self-play.** Once the network beats Greedy, generate data by playing it
   against itself and older copies, retrain, repeat. That loop is what takes an
   agent past the quality of the agents that produced its first dataset.
4. **Hidden information.** Magic is not chess: the opponent's hand and library
   order are unknown. When searching, sample plausible opponent hands from the
   unseen cards and average, rather than searching the true state.
5. **More decks.** A model trained on one matchup learns one matchup.
   Generalizing to unseen cards means training across many decks and feeding an
   embedding of the oracle text alongside the structured features.