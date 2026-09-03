"""Loading the .jsonl datasets the Godot Training screen records.

A dataset file is one JSON object per line:

* line 1 — header: layout + card vocabulary (see `spec.EncodingSpec`)
* the rest — one decision each: `features`, `card_ids`, `legal`, `chosen`,
  `outcome`, `player`, `turn`, `game`

Only `features`, `card_ids` and `outcome` are needed to train a value network;
`legal` / `chosen` are kept in the arrays so a policy head can reuse the same
loader later.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Iterator, Sequence

import numpy as np
import torch
from torch.utils.data import DataLoader, Dataset

from .spec import EncodingSpec

#: Value target per recorded outcome (+1 win, -1 loss, 0 draw).
OUTCOME_TO_TARGET = {1: 1.0, -1: 0.0, 0: 0.5}


@dataclass
class Samples:
    """A whole dataset in memory, as flat arrays."""

    features: np.ndarray      # (N, feature_count) float32
    card_ids: np.ndarray      # (N, total_slots)   int64
    targets: np.ndarray       # (N,)               float32 in {0, 0.5, 1}
    turns: np.ndarray         # (N,)               int32
    groups: np.ndarray        # (N,)               int32 — game id, unique across files
    spec: EncodingSpec

    def __len__(self) -> int:
        return int(self.features.shape[0])

    def subset(self, indices: Sequence[int] | np.ndarray) -> Samples:
        idx = np.asarray(indices, dtype=np.int64)
        return Samples(
            features=self.features[idx],
            card_ids=self.card_ids[idx],
            targets=self.targets[idx],
            turns=self.turns[idx],
            groups=self.groups[idx],
            spec=self.spec,
        )

    def describe(self) -> str:
        wins = int((self.targets == 1.0).sum())
        losses = int((self.targets == 0.0).sum())
        draws = len(self) - wins - losses
        return (
            f"{len(self)} decisions from {len(np.unique(self.groups))} games "
            f"({wins} win / {losses} loss / {draws} draw), "
            f"turns {int(self.turns.min())}-{int(self.turns.max())}, "
            f"{self.spec.vocab_size - 1} distinct cards"
        )


class ValueDataset(Dataset):
    """Torch view over `Samples` for the value network."""

    def __init__(self, samples: Samples) -> None:
        self.samples = samples
        self._features = torch.from_numpy(samples.features)
        self._card_ids = torch.from_numpy(samples.card_ids)
        self._targets = torch.from_numpy(samples.targets)
        self._turns = torch.from_numpy(samples.turns.astype(np.int64))

    def __len__(self) -> int:
        return len(self.samples)

    def __getitem__(self, index: int) -> dict[str, torch.Tensor]:
        return {
            "features": self._features[index],
            "card_ids": self._card_ids[index],
            "target": self._targets[index],
            "turn": self._turns[index],
        }


# --------------------------------------------------------------------- files

def find_datasets(paths: Iterable[str | Path]) -> list[Path]:
    """Expands directories and globs into a sorted list of .jsonl files."""
    found: list[Path] = []
    for raw in paths:
        path = Path(raw)
        if path.is_dir():
            found.extend(sorted(path.rglob("*.jsonl")))
        elif any(ch in str(raw) for ch in "*?["):
            found.extend(sorted(Path().glob(str(raw))))
        elif path.is_file():
            found.append(path)
        else:
            raise FileNotFoundError(f"no dataset at {raw}")
    unique = sorted({p.resolve() for p in found})
    if not unique:
        raise FileNotFoundError(f"no .jsonl datasets found in {list(paths)}")
    return unique


def _read_lines(path: Path) -> Iterator[dict]:
    with path.open(encoding="utf-8") as handle:
        for line_no, line in enumerate(handle, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError as error:
                # A run interrupted mid-write leaves a truncated last line.
                raise ValueError(f"{path}:{line_no}: malformed JSON ({error})") from error


def load_samples(paths: Iterable[str | Path], verbose: bool = True) -> Samples:
    """Loads and concatenates datasets, unifying their card vocabularies."""
    files = find_datasets(paths)

    spec: EncodingSpec | None = None
    feature_rows: list[np.ndarray] = []
    id_rows: list[np.ndarray] = []
    targets: list[float] = []
    turns: list[int] = []
    groups: list[int] = []
    next_group = 0

    for path in files:
        lines = _read_lines(path)
        try:
            header = next(lines)
        except StopIteration:
            continue
        if header.get("format") != "mtg-ai-samples-v1":
            raise ValueError(f"{path}: unexpected format {header.get('format')!r}")

        file_spec = EncodingSpec.from_header(header)
        if spec is None:
            spec = file_spec
            remap = {i: i for i in range(file_spec.vocab_size)}
        else:
            if not spec.compatible_with(file_spec):
                raise ValueError(
                    f"{path}: encoding layout differs from earlier files — "
                    "retrain from a single generation of recordings"
                )
            remap = spec.merge_vocabulary(file_spec.vocabulary)

        seen_games: dict[int, int] = {}
        count = 0
        for sample in lines:
            outcome = int(sample.get("outcome", 0))
            if outcome not in OUTCOME_TO_TARGET:
                continue

            features = np.asarray(sample["features"], dtype=np.float32)
            if features.shape[0] != spec.feature_count:
                raise ValueError(
                    f"{path}: sample has {features.shape[0]} features, "
                    f"expected {spec.feature_count}"
                )
            ids = np.asarray(sample["card_ids"], dtype=np.int64)
            if ids.shape[0] != spec.total_slots:
                raise ValueError(
                    f"{path}: sample has {ids.shape[0]} card slots, "
                    f"expected {spec.total_slots}"
                )

            feature_rows.append(features)
            id_rows.append(np.array([remap.get(int(i), 0) for i in ids], dtype=np.int64))
            targets.append(OUTCOME_TO_TARGET[outcome])
            turns.append(int(sample.get("turn", 0)))

            # Group id: unique per (file, game) so a split never puts two
            # decisions from the same game on both sides.
            local = int(sample.get("game", 0))
            if local not in seen_games:
                seen_games[local] = next_group
                next_group += 1
            groups.append(seen_games[local])
            count += 1

        if verbose:
            print(f"  {path.name}: {count} decisions, {len(seen_games)} games")

    if spec is None or not feature_rows:
        raise ValueError("datasets contained no usable samples")

    return Samples(
        features=np.stack(feature_rows),
        card_ids=np.stack(id_rows),
        targets=np.asarray(targets, dtype=np.float32),
        turns=np.asarray(turns, dtype=np.int32),
        groups=np.asarray(groups, dtype=np.int32),
        spec=spec,
    )


# -------------------------------------------------------------------- splits

def split_by_game(
    samples: Samples, val_fraction: float = 0.15, seed: int = 0
) -> tuple[Samples, Samples]:
    """Train/validation split that keeps whole games together.

    Decisions inside one game are highly correlated, so a per-sample split
    would leak and report a validation loss that flatters the model.
    """
    games = np.unique(samples.groups)
    rng = np.random.default_rng(seed)
    rng.shuffle(games)

    n_val = max(1, int(round(len(games) * val_fraction))) if len(games) > 1 else 0
    val_games = set(games[:n_val].tolist())

    is_val = np.fromiter((g in val_games for g in samples.groups), dtype=bool, count=len(samples))
    return samples.subset(np.flatnonzero(~is_val)), samples.subset(np.flatnonzero(is_val))


def make_loaders(
    train: Samples,
    val: Samples,
    batch_size: int = 256,
    workers: int = 0,
) -> tuple[DataLoader, DataLoader | None]:
    train_loader = DataLoader(
        ValueDataset(train),
        batch_size=batch_size,
        shuffle=True,
        num_workers=workers,
        drop_last=False,
    )
    val_loader = None
    if len(val) > 0:
        val_loader = DataLoader(
            ValueDataset(val),
            batch_size=max(batch_size, 512),
            shuffle=False,
            num_workers=workers,
        )
    return train_loader, val_loader
