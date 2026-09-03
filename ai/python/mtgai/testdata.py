"""Synthetic datasets, so the pipeline can be tested without running Godot.

The fake games are deliberately learnable: the winner is decided by a hidden
linear score over life difference, board power and card advantage, plus noise.
A healthy value network reaches ~0.8 accuracy on this; if it sits at 0.5 the
plumbing is broken, not the model.
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np

from .data import OUTCOME_TO_TARGET, Samples
from .spec import EncodingSpec

FAKE_CARDS = [
    "Island", "Steam Vents", "Spirebluff Canal", "Riverpyre Verge", "Multiversal Passage",
    "Eddymurk Crab", "Hydro-Man, Fluid Felon", "Slickshot Show-Off", "Stormchaser's Talent",
    "Burst Lightning", "Opt", "Shore Up", "Spell Pierce", "Vibrant Outburst",
    "Boomerang Basics", "Flow State", "Sleight of Hand",
]


def _spec() -> EncodingSpec:
    spec = EncodingSpec()
    spec.merge_vocabulary([""] + FAKE_CARDS)
    return spec


def synthetic_samples(games: int = 100, seed: int = 0) -> Samples:
    """Builds a `Samples` in memory with the same shapes as a real recording."""
    spec = _spec()
    rng = np.random.default_rng(seed)

    features: list[np.ndarray] = []
    card_ids: list[np.ndarray] = []
    targets: list[float] = []
    turns: list[int] = []
    groups: list[int] = []

    for game in range(games):
        # One hidden "true" advantage per game decides who wins.
        advantage = rng.normal(0.0, 1.0)
        outcome = 1 if advantage > 0 else -1
        n_decisions = int(rng.integers(8, 40))

        for step in range(n_decisions):
            # Signal strength grows as the game progresses, like the real thing.
            confidence = 0.15 + 0.85 * (step / max(n_decisions - 1, 1))
            noise = rng.normal(0.0, 1.0 - 0.7 * confidence)
            signal = advantage * confidence + noise

            vector = np.zeros(spec.feature_count, dtype=np.float32)
            ids = np.zeros(spec.total_slots, dtype=np.int64)

            turn = 1 + step // 2
            vector[0] = min(turn / 30.0, 1.0)                      # turn
            vector[1] = float(step % 2 == 0)                       # my turn
            vector[2] = 1.0                                        # I am acting
            vector[6 + (step % spec.card_features % 12)] = 1.0     # a step one-hot
            my_life = float(np.clip(10 + 6 * signal + rng.normal(0, 2), 1, 20))
            opp_life = float(np.clip(10 - 6 * signal + rng.normal(0, 2), 1, 20))
            vector[18] = my_life / 20.0
            vector[19] = opp_life / 20.0
            vector[20] = rng.integers(0, 8) / 10.0                 # my hand size

            # Fill a few battlefield slots on both sides.
            mine = int(np.clip(2 + 2 * signal + rng.normal(0, 1), 0, spec.battlefield_slots))
            theirs = int(np.clip(2 - 2 * signal + rng.normal(0, 1), 0, spec.battlefield_slots))
            for zone_index, (_, start, end) in enumerate(spec.zone_bounds()):
                if zone_index == 1:
                    count = mine
                elif zone_index == 2:
                    count = theirs
                elif zone_index == 0:
                    count = int(rng.integers(0, 6))
                else:
                    count = 0
                for slot in range(start, min(start + count, end)):
                    base = spec.global_features + slot * spec.card_features
                    vector[base] = 1.0                              # present
                    vector[base + 2] = 1.0                          # creature
                    vector[base + 8] = rng.uniform(0.1, 0.7)        # power
                    vector[base + 9] = rng.uniform(0.1, 0.7)        # toughness
                    vector[base + 15] = float(zone_index != 2)      # is mine
                    ids[slot] = int(rng.integers(1, spec.vocab_size))

            features.append(vector)
            card_ids.append(ids)
            targets.append(OUTCOME_TO_TARGET[outcome])
            turns.append(turn)
            groups.append(game)

    return Samples(
        features=np.stack(features),
        card_ids=np.stack(card_ids),
        targets=np.asarray(targets, dtype=np.float32),
        turns=np.asarray(turns, dtype=np.int32),
        groups=np.asarray(groups, dtype=np.int32),
        spec=spec,
    )


def write_synthetic_dataset(path: str | Path, games: int = 100, seed: int = 0) -> Path:
    """Writes a synthetic dataset in the exact .jsonl format Godot produces."""
    samples = synthetic_samples(games=games, seed=seed)
    spec = samples.spec
    target_to_outcome = {1.0: 1, 0.0: -1, 0.5: 0}

    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        handle.write(json.dumps({
            "format": "mtg-ai-samples-v1",
            "feature_count": spec.feature_count,
            "global_features": spec.global_features,
            "card_features": spec.card_features,
            "action_features": spec.action_features,
            "slots": {
                "hand": spec.hand_slots,
                "battlefield": spec.battlefield_slots,
                "stack": spec.stack_slots,
            },
            "vocabulary": spec.vocabulary,
            "games": games,
        }) + "\n")

        for i in range(len(samples)):
            handle.write(json.dumps({
                "player": int(i % 2),
                "turn": int(samples.turns[i]),
                "game": int(samples.groups[i]),
                "features": [round(float(v), 5) for v in samples.features[i]],
                "card_ids": [int(v) for v in samples.card_ids[i]],
                "legal": [[0.0] * spec.action_features],
                "legal_signatures": ["0|0|0"],
                "chosen": 0,
                "outcome": target_to_outcome[float(samples.targets[i])],
            }) + "\n")
    return path


if __name__ == "__main__":
    import argparse

    from .paths import DATASET_DIR

    parser = argparse.ArgumentParser(description="Write a synthetic dataset for testing.")
    parser.add_argument("--out", default=str(DATASET_DIR / "synthetic.jsonl"))
    parser.add_argument("--games", type=int, default=100)
    parser.add_argument("--seed", type=int, default=0)
    written = parser.parse_args()
    print("wrote", write_synthetic_dataset(written.out, written.games, written.seed))
