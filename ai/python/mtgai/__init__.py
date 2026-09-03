"""Learned agents for the MTG-AI Godot project.

Modules
    spec         encoding layout shared with scripts/ai/state_encoder.gd
    data         loading the .jsonl recordings the Training screen writes
    model        ValueNet — P(the acting player wins)
    train        training entry point (python -m mtgai.train)
    evaluate     score a checkpoint (python -m mtgai.evaluate)
    export_onnx  export for use outside Python
    serve        localhost HTTP server so a Godot agent can query the model
    vocab        write ai/training/vocabulary.json for the Godot encoder
    testdata     synthetic datasets for testing without Godot
"""

__all__ = ["spec", "data", "model", "metrics", "paths"]
__version__ = "0.1.0"
