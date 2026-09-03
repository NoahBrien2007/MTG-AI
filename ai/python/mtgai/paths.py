"""Project-relative paths, so the scripts work from any working directory."""

from __future__ import annotations

from pathlib import Path

#: ai/python/mtgai/paths.py -> the Godot project root
PROJECT_ROOT = Path(__file__).resolve().parents[3]

AI_DIR = PROJECT_ROOT / "ai"
PYTHON_DIR = AI_DIR / "python"
TRAINING_DIR = AI_DIR / "training"
DATASET_DIR = TRAINING_DIR / "datasets"
MODEL_DIR = AI_DIR / "models"
CHECKPOINT_DIR = PYTHON_DIR / "checkpoints"

#: Read by `StateEncoder` in Godot to keep card ids stable across runs.
VOCABULARY_PATH = TRAINING_DIR / "vocabulary.json"

DEFAULT_CHECKPOINT = CHECKPOINT_DIR / "value_net.pt"
DEFAULT_ONNX = MODEL_DIR / "value_net.onnx"
