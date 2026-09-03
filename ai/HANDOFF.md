# MTG-AI — state of the AI work

Written 2026-09-03. This is the working memory for the machine-learning side of
the project: what exists, what was measured, what the numbers mean, and what to
do next. Read the "Where things stand" table and the "Traps" section before
changing anything.

---

## Where things stand

Every number below is 100 games against `GreedyAgent`, alternating who is on
the play, standard error ±5%. Measured with `tests/sweep_blend.gd`.

> **These were measured before the double-untap fix (bug #8), under rules that
> handed both players free mana every turn.** The ordering is probably intact —
> the exploit was symmetric after turn one — but re-run
> `sweep_blend.gd -- 100` before quoting any of them, and re-record before
> training anything new.

| agent | win rate | what it is |
| --- | --- | --- |
| Greedy (control) | 53% | the hand-written 1-ply search, playing itself |
| value net, 1 ply | 6% | pick the successor state the value net rates highest |
| value net, 2 ply | 3% | same, with minimax over the opponent's replies |
| value net, mixed | 17% | half value net, half Greedy's formula |
| **policy alone** | **17%** | one forward pass, no search |
| **policy + 1 ply** | **49%** | policy nominates 4 moves, Greedy's formula searches them |
| **policy + 2 ply** | **53%** | same, one ply deeper |

**The headline: a learned agent is at parity with the hand-written agent that
taught it.** The progression 17 → 49 → 53 is the whole story — imitation loses
36 points to compounding error, and search puts all of them back.

**The loop is now closed.** The search (53%) is much stronger than the policy
inside it (17%). Training the policy on the *search's* decisions makes the
policy stronger; putting search on top of the better policy makes it stronger
again. That crank is what can exceed Greedy. Everything before this point was
capped at Greedy by construction.

---

## The pieces

### Godot side (`scripts/ai/`)

| file | role |
| --- | --- |
| `state_encoder.gd` | state → 1295 floats + 37 card ids; action → 18 floats |
| `game_recorder.gd` | writes `.jsonl` training data into `ai/training/datasets/` |
| `greedy_agent.gd` | 1-ply plan search on a hand-written formula. The baseline, and the fallback for every network agent |
| `net_client.gd` | blocking HTTP/JSON to the local model server |
| `policy_agent.gd` | asks the policy net which legal action to play |
| `policy_search_agent.gd` | **the current best agent** — policy picks 4 candidates, minimax searches them with Greedy's evaluator |
| `value_net_agent.gd` | value-net search. Kept for reference; it does not work (see below) |

Agents are registered in `scripts/game/game_config.gd` (`AGENT_TYPES` +
`create_agent`) and appear in the Training screen and the opponent dropdown.

**AI Stats** (main menu -> `scenes/AIStats.tscn`, `scripts/ui/ai_stats.gd`)
shows every agent with its measured win rate, what it needs, and what it is good
and bad at. The numbers live in `data/ai_stats.json` and are rewritten by
`sweep_blend.gd`, so the screen cannot drift from the last real measurement; the
prose in that file is hand-maintained. The status beside each agent is a live
`/health` probe, which is how you see that a row would be the Greedy fallback
*before* spending 100 games on it.

### Python side (`ai/python/mtgai/`)

| file | role |
| --- | --- |
| `spec.py` | the encoding layout, mirrored from `state_encoder.gd` |
| `data.py` | loads `.jsonl` for the value net, merges vocabularies, splits by game |
| `model.py` | `ValueNet` — P(acting player wins). `state_embedding()` is shared with the policy |
| `policy.py` | `PolicyNet` — which action to take — plus its loader and training |
| `serve.py` | localhost server: `POST /value`, `POST /policy`, `GET /health` |
| `train.py` / `evaluate.py` | value-net training and scoring |

### Test and measurement harnesses (`tests/`)

| file | what it answers |
| --- | --- |
| `test_rules.gd` | the engine still works; run after every change |
| `sweep_blend.gd` | how strong is each agent, in win rate. Takes a sample size: `-- 100` |
| `diagnose_value_net.gd` | what is the value agent actually doing, decision by decision |
| `compare_evaluators.gd` | does the network judge positions better than the hand-written formula |

---

## What was measured, and what it means

These are the results that should govern future decisions. Several of them are
counter-intuitive and were expensive to learn.

**Resolving the stack before judging a position is worth ~17 points.**
Measured at 100 games: the same agent with and without it, 66% vs 49%. Judging
a board with a spell still in flight compares positions mid-exchange, before
the thing that decides the comparison has happened. Now built into
`GreedyAgent._settle()`, so every agent inherits it. (Chess calls this
quiescence.)

**The value network judges positions well and picks moves terribly.**
`compare_evaluators.gd` over 6,080 positions: the network ranks positions at
0.800 AUC against the hand-written formula's 0.656 — and in the early game the
formula is *inverted*, 0.341, worse than a coin flip. Yet the formula plays at
53% and the value net at 6%. Ranking *different* positions and ranking the
*successors of one position* are different skills; only the second picks moves.
Do not read a good AUC as a good agent.

**Outcome training is starved of signal.** A game's single result labels all
~300 of its decisions, so 2,000 games carry about 2,000 real supervision
signals across 650,000 rows. Every value-net run peaked at epoch 1–2 no matter
how it was regularised. `chosen` labels each decision individually against its
~25 alternatives: same files, three hundred times the supervision. The policy
net reached **87.7% agreement** (chance 29.4%), **97.4% top-3**.

**Greedy vs Greedy is the right recording matchup.** Heuristic vs Greedy gave
63/37, and part of what the model learned was "which agent made this board" —
a shortcut that is worthless, and actively misleading, when the model judges
its own positions.

**Eight games measures nothing.** Standard error is ±18% at n=8; four separate
sweeps at that size produced no usable information. Use 100.

---

## Bugs found and fixed (do not reintroduce)

1. **Recordings went to `user://`** — the OS user-data folder, not the project.
   Now `res://ai/training/datasets/`, which is where the Python trainer looks.
2. **Everything buffered in memory.** 1000 games is ~350k decisions × 1110
   floats; the run would have died before finishing. `GameRecorder.begin_stream()`
   writes each game as it completes and shards every 250 games.
3. **No `game` field on samples.** `data.py` groups train/validation by it, so
   every decision looked like one game, `n_val` computed to 0, and training ran
   with no validation set while cheerfully reporting "N decisions from 1 game".
4. **The value agent encoded from its own seat.** In the recordings the encoded
   player is *always* the acting player, so "acting player is me" is a constant
   1.0 in every training row. Scoring post-action states set it to 0.0 — an
   arbitrary weight swinging the comparison between passing and acting. The
   agent passed every turn and lost 200/200. Now every state is encoded from
   whoever is about to act, and flipped (`1 - v`) when that is the opponent.
5. **The encoder could not see what a spell targeted.** "Burst Lightning at the
   opponent" and "at my own face" were byte-identical vectors, so the search
   took whichever came first and burned its own face every game. Five features
   per card slot now carry targets and kicked; `feature_count` 1110 → 1295.
6. **`ACTION_FEATURES` said 19, `encode_action` emits 18.** Nothing used the
   constant, so nothing caught it, until the policy refused to load the data.
   The recorder now writes `action_features` into every header.
7. **`/health` did not distinguish a value server from a policy server**, so
   value rows ran against a server with no value net, silently measuring the
   Greedy fallback under the model's name. Three runs were wasted on this. The
   sweep now prints a `net calls` column and flags any row with zero.
8. **The untap step ran twice, and gave priority.** `_execute_cleanup_step()`
   untapped the new active player's permanents and then left `current_step` at
   `UNTAP`. Nothing gates `get_legal_actions()` by step, so the active player
   held priority in the untap step — and passing out of it hit
   `_advance_step()`'s `UNTAP` branch, which untapped everything a *second*
   time. Tap three lands in the untap step, cast an instant, pass: the lands
   come back untapped. Free mana, every turn, for humans and agents alike.
   Cleanup now advances straight through the untap step (CR 502.4: no player
   receives priority there), so `_execute_untap_step()` runs once, from one
   place. Regression: `test_untap_happens_once`.

   **Two consequences worth knowing.** Every recording in
   `ai/training/datasets/` was made under those rules, so its decisions were
   made in a game that is not this one; the win rates in the table above were
   too. Both sides had the exploit from their second turn onward, so the
   *ordering* of the agents is probably intact, but the numbers need a fresh
   `sweep_blend.gd -- 100` before they mean anything again. And the exploit was
   asymmetric on turn one: `GameSession.setup()` starts the game at `MAIN_1`, so
   the player on the play never got an untap-step window on their first turn
   while the player on the draw did — see the open question below.

---

## Commands

```bash
# engine tests — after every change
godot --headless -s tests/test_rules.gd

# new .gd files with a class_name need one import pass before headless can see them
godot --headless --import

# record: Training screen -> pick agents, tick "Record training data", Run
#   output lands in ai/training/datasets/

# train the policy (the one that works)
cd ai/python && source .venv/bin/activate
python -m mtgai.policy                     # add --smoke-test to check the loop
python -m mtgai.policy --max-per-game 120 --epochs 60

# train the value net (kept for reference; does not produce a strong agent)
python -m mtgai.train --lr 3e-4 --weight-decay 1e-2 --dropout 0.35 \
  --batch-size 512 --embed-dim 16 --card-hidden 64 --card-out 32 \
  --trunk-hidden 128 --out-dir checkpoints/B

# serve — both models can run off one process
python -m mtgai.serve --policy-checkpoint checkpoints/policy_net.pt \
  --checkpoint checkpoints/B/value_net.pt

# measure — also rewrites data/ai_stats.json for the AI Stats screen
godot --headless -s tests/sweep_blend.gd -- 100
```

---

## Next steps, in order

### 1. Retrain the policy on a single teacher (~30 min)

The current policy imitates two agents that disagree: `games_2026-09-03T12-33-44*`
is pre-settle Greedy, `games_2026-09-03T13-17-46*` is post-settle Greedy — and
it is judged only against the stronger one. Half the data, one teacher, twice
the decisions per game (half the files means half the memory):

**1. Check the engine is where you left it.**

```bash
godot --headless -s tests/test_rules.gd      # must end in ALL TESTS ... SUCCESSFULLY
```

**2. Confirm the teacher set is encoding-compatible.** Both current sets are
`feature_count` 1295 / `card_features` 34; anything else cannot be trained
against this build.

```bash
head -c 200 ai/training/datasets/games_2026-09-03T13-17-46.jsonl
```

**3. Train, into its own folder.** `--out-dir` keeps the two-teacher checkpoint
intact, so the old and new policies can be compared instead of one replacing
the other.

```bash
cd ai/python && source .venv/bin/activate
python -m mtgai.policy ../training/datasets/games_2026-09-03T13-17-46*.jsonl \
  --max-per-game 120 --epochs 60 --out-dir checkpoints/policy_single
```

Watch `agreement` climb. Expect above 87.7% — every point there compounds
through the search sitting on top of it. If it plateaus in the first two epochs
the way every value-net run did, the labels are the problem, not the schedule.

**4. Serve it and check what is actually loaded.** A stopped or half-loaded
server does not fail; it silently measures Greedy under the model's name.

```bash
python -m mtgai.serve --policy-checkpoint checkpoints/policy_single/policy_net.pt
curl -s localhost:8787/health      # "policy": true, "feature_count": 1295
```

**5. Measure, at 100 games.**

```bash
godot --headless -s tests/sweep_blend.gd -- 100
```

Read the `greedy` control first: if it is not near 50%, nothing else on that run
means anything. Then check `net calls` is non-zero on the policy rows. The sweep
writes its rows into `data/ai_stats.json`, so the AI Stats screen shows the new
numbers with no further work.

**6. Keep it or drop it.** Better than 17% policy / 53% policy+search: copy
`checkpoints/policy_single/policy_net.pt` over `checkpoints/policy_net.pt`, so
every documented `serve` command picks it up without a new flag. Worse: serve
the old path again — the two-teacher checkpoint was never touched.

One trap: training rewrites `ai/training/vocabulary.json`, which the Godot
encoder reads at startup. Card ids are assigned in first-encountered order, so
a checkpoint only matches the vocabulary written by *its own* run. If you keep
two checkpoints, only the most recently trained one is safe to serve.

### 2. Test search depth 3 (one sweep)

`search_depth` in `policy_search_agent.gd`, or the constant at the top. Depth
1 → 2 was worth 4 points. Cost multiplies by `BRANCH` (6) per ply, so depth 3
is ~6× slower per decision; check it pays before committing an hour of
recording to it.

### 3. Turn the crank — this is the one that matters

The search is stronger than the policy inside it. Collect that gap:

1. Record ~500 games with **Policy + Search AI** on both sides (server running,
   Record ticked). Slower than Greedy because of the round trip per decision —
   start at 500 and check the timing before scaling.
2. Retrain the policy on *only* those games. Its target is now an agent that
   searched, so the policy inherits search strength in one forward pass.
3. Measure with `sweep_blend.gd -- 100`. The new `policy` row should be well
   above 17%, and the new `policy+search` row above 53%.
4. Repeat from 1.

Each turn, the policy absorbs what the search found and the search improves on
the better policy. Stop when a cycle stops moving the win rate.

### 4. After that

- **Deeper search on a better filter.** As agreement rises, `POLICY_TOP_K` can
  fall — top-3 already holds the right move 97.4% of the time. Narrower and
  deeper beats wider and shallower once the filter is trustworthy.
- **The value net as a leaf evaluator.** It judges positions better than the
  formula (0.800 vs 0.656 AUC) but is unusable as a move picker. Inside a deep
  search it is only ever asked to judge, which is what it is good at. Worth
  retrying as `PolicySearchAgent`'s leaf evaluation once the loop is running.
- **More decks.** Everything so far is one Izzet list mirrored, 19 distinct
  cards. A model trained on one matchup knows one matchup.
- **Hidden information.** The search assumes the opponent's hand is known.
  Sampling plausible hands from the unseen cards and averaging is the honest
  version.

---

## Traps

- **New `.gd` file with a `class_name`?** Run `godot --headless --import` once,
  or headless scripts report "Identifier not declared".
- **Datasets are encoding-versioned.** Changing `state_encoder.gd` changes
  `feature_count` and invalidates every recording and checkpoint. The `/health`
  check catches the mismatch and refuses rather than playing badly.
- **A sweep row with 0 `net calls` is the fallback agent**, not the model.
- **Both agents fall back to Greedy when the server dies**, and warn once. A
  result with those warnings in the log is a measurement of Greedy.
- **`--checkpoint` needs the file**, not the directory:
  `checkpoints/B/value_net.pt`.
- **Recording memory**: `--max-per-game` exists because the full dataset with
  padded action matrices needs several GB. Raise it only with RAM to spare.

---

## Open questions worth answering some day

- Going first was a small *disadvantage* in this engine: 46.1% of games were
  won by the player on the play, across 1000 games with balanced seats — 
  backwards from real Magic. **The double-untap bug (#8) is the leading
  suspect.** The game starts at `MAIN_1`, so the player on the play had no
  untap step on turn one and no free-mana window; the player on the draw got
  one on their first turn. That is a one-turn mana advantage handed to the
  wrong seat. Re-measure now that untap is fixed before looking for any other
  cause.
- Greedy's formula is inverted in the early game (0.341 AUC before turn 7) and
  still plays well. Its early-game terms are doing something other than what
  they claim to.
