"""MLPClassifier for CIFAR-10 and helper functions."""

import numpy as np
from sklearn.neural_network import MLPClassifier
from sklearn.metrics import log_loss, accuracy_score


def create_model() -> MLPClassifier:
    """Create an MLPClassifier for CIFAR-10 (~1.6M parameters).

    Architecture:
        Input(3072) → Hidden(512) → Output(10)

    Uses warm_start=True and max_iter=1 for incremental training via
    partial_fit across federated rounds.
    """
    return MLPClassifier(
        hidden_layer_sizes=(512,),
        max_iter=1,
        warm_start=True,
    )


def get_weights(model: MLPClassifier) -> list[np.ndarray]:
    """Extract model parameters as a list of NumPy arrays."""
    return [
        model.coefs_[0],
        model.intercepts_[0],
        model.coefs_[1],
        model.intercepts_[1],
    ]


def set_weights(model: MLPClassifier, params: list[np.ndarray]) -> None:
    """Load parameters into a model."""
    model.coefs_ = [params[0], params[2]]
    model.intercepts_ = [params[1], params[3]]


def init_model(model: MLPClassifier, n_features: int, n_classes: int) -> None:
    """Initialize model internals so get_weights/predict work before real training.

    sklearn's MLPClassifier creates many internal attributes only after fit().
    Rather than manually setting each one (fragile across sklearn versions),
    we do a single partial_fit on tiny dummy data to let sklearn initialize
    everything, then overwrite with small random weights.
    """
    rng = np.random.default_rng(42)
    x_dummy = rng.standard_normal((n_classes, n_features)).astype(np.float32)
    y_dummy = np.arange(n_classes)
    model.partial_fit(x_dummy, y_dummy, classes=y_dummy)

    # Overwrite with small random weights (the dummy fit produces arbitrary ones)
    model.coefs_ = [
        rng.standard_normal((n_features, 512)).astype(np.float32) * 0.01,
        rng.standard_normal((512, n_classes)).astype(np.float32) * 0.01,
    ]
    model.intercepts_ = [
        np.zeros(512, dtype=np.float32),
        np.zeros(n_classes, dtype=np.float32),
    ]


def train(model: MLPClassifier, x: np.ndarray, y: np.ndarray) -> None:
    """Train the model on local data using partial_fit."""
    model.partial_fit(x, y, classes=np.arange(10))


def test(model: MLPClassifier, x: np.ndarray, y: np.ndarray) -> tuple[float, float]:
    """Evaluate the model. Returns (loss, accuracy)."""
    loss = log_loss(y, model.predict_proba(x), labels=np.arange(10))
    accuracy = accuracy_score(y, model.predict(x))
    return loss, accuracy
