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
python -m venv .venv && .venv\Scripts\activate      # Windows
pip install -r requirements.txt

python -m mtgai.selftest          # 27 checks, no data needed (~15 s)
python -m mtgai.train             # trains on ../training/datasets/*.jsonl
python -m mtgai.evaluate          # calibration + accuracy report
python -m mtgai.serve             # http://127.0.0.1:8787 for a Godot agent
```

No recordings yet? In the game: **AI Training** → tick *Record training data* →
**Run**. A few hundred games is a reasonable first dataset; Heuristic vs Greedy
gives more varied positions than either agent against itself.

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
| `serve.py` | localhost HTTP server so a Godot agent can query the model |
| `vocab.py` | writes `ai/training/vocabulary.json` for the Godot encoder |
| `testdata.py` | synthetic datasets |
| `selftest.py` | self-checks for all of the above |

---

## The model

The state vector is 1109 floats, but it is not a flat blob: 36 numbers describe
the game as a whole (life totals, mana, phase, zone sizes) and the remaining
1073 are 37 **card slots** of 29 numbers each — 10 for your hand, 12 for each
battlefield, 3 for the stack.

Feeding that flat into an MLP wastes capacity, because slot 3 of your
battlefield means exactly what slot 7 means. So instead:

```
card slot (29 floats) ─┐
                       ├─→ shared card encoder → 64 floats ─┐
card name → embedding ─┘                                    │
                                                            ├─ pool per zone (mean + max
                                                            │   over occupied slots)
global features (36) ───────────────────────────────────────┴─→ trunk → 1 logit → sigmoid
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
{"states": [{"features": [...1109 floats...], "card_ids": [...37 ints...]}, ...]}
→ {"values": [0.61, 0.48, ...]}
```

Send one request per decision containing every candidate state, not one request
per state — a searching agent evaluates every legal action, and the round trip
dominates the cost. A `ValueNetAgent` on the Godot side then looks like
`GreedyAgent` with `_evaluate_state()` replaced by a lookup into the response.

`python -m mtgai.export_onnx` writes `ai/models/value_net.onnx` plus a sidecar
`.json` with the encoding spec, for when you would rather run inference inside
Godot via a GDExtension than talk to a Python process. (Needs `pip install onnx
onnxscript`; the HTTP path does not.)

---

## Dataset format

One JSON object per line. Line 1 is the header:

```json
{"format": "mtg-ai-samples-v1", "feature_count": 1109, "global_features": 36,
 "card_features": 29, "action_features": 19,
 "slots": {"hand": 10, "battlefield": 12, "stack": 3},
 "vocabulary": ["", "Island", "Opt", ...], "games": 200}
```

Every following line is one decision:

| field | meaning |
| --- | --- |
| `features` | the state vector, from the acting player's view |
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

## What comes after this

1. **Wire it up.** A `ValueNetAgent` in Godot that calls `/value`. Measure it
   against Greedy on the Training screen — that number is the whole point.
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
