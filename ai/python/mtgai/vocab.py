"""Write the canonical card vocabulary Godot's StateEncoder reads.

    python -m mtgai.vocab                    # from the recorded datasets
    python -m mtgai.vocab --from-checkpoint  # from a trained model

Card ids are assigned in the order cards are first seen, so two recording
sessions can number the same card differently. A trained embedding table is
tied to one numbering, so the model and the game must agree: this writes
`ai/training/vocabulary.json`, which `StateEncoder` loads at startup.

`train.py` writes the same file automatically; this command exists for when you
need to regenerate it (a fresh clone, or after moving checkpoints around).
"""

from __future__ import annotations

import argparse
import json

from .data import load_samples
from .model import ValueNet
from .paths import DATASET_DIR, DEFAULT_CHECKPOINT, VOCABULARY_PATH
from .spec import EncodingSpec


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("datasets", nargs="*", default=[str(DATASET_DIR)])
    parser.add_argument("--from-checkpoint", nargs="?", const=str(DEFAULT_CHECKPOINT),
                        help="take the vocabulary from a checkpoint instead of the datasets")
    parser.add_argument("--out", default=str(VOCABULARY_PATH))
    args = parser.parse_args(argv)

    if args.from_checkpoint:
        spec: EncodingSpec = ValueNet.load(args.from_checkpoint).spec
        source = args.from_checkpoint
    else:
        spec = load_samples(args.datasets, verbose=False).spec
        source = ", ".join(str(p) for p in args.datasets)

    VOCABULARY_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump({"vocabulary": spec.vocabulary}, handle, indent=1, ensure_ascii=False)

    print(f"wrote {spec.vocab_size - 1} card names to {args.out}")
    print(f"  source: {source}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
