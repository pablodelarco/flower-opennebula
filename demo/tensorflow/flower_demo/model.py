"""Keras Sequential CNN for CIFAR-10 and helper functions."""

import numpy as np
import tensorflow as tf
from tensorflow import keras


def SimpleCNN() -> keras.Model:
    """Lightweight CNN for CIFAR-10 (~880K parameters).

    Architecture:
        Conv2D(32, 5×5, same) → ReLU → MaxPool(2)
        Conv2D(64, 5×5, same) → ReLU → MaxPool(2)
        Flatten → Dense(512) → ReLU → Dense(10)
    """
    model = keras.Sequential([
        keras.layers.Conv2D(32, (5, 5), padding="same", activation="relu",
                            input_shape=(32, 32, 3)),
        keras.layers.MaxPooling2D((2, 2)),
        keras.layers.Conv2D(64, (5, 5), padding="same", activation="relu"),
        keras.layers.MaxPooling2D((2, 2)),
        keras.layers.Flatten(),
        keras.layers.Dense(512, activation="relu"),
        keras.layers.Dense(10, activation="softmax"),
    ])
    model.compile(
        optimizer="sgd",
        loss="sparse_categorical_crossentropy",
        metrics=["accuracy"],
    )
    return model


def get_weights(model: keras.Model) -> list[np.ndarray]:
    """Extract model parameters as a list of NumPy arrays."""
    return model.get_weights()


def set_weights(model: keras.Model, params: list[np.ndarray]) -> None:
    """Load parameters into a model."""
    model.set_weights(params)


def train(model: keras.Model, x: np.ndarray, y: np.ndarray,
          epochs: int, batch_size: int) -> None:
    """Train the model on local data."""
    model.fit(x, y, epochs=epochs, batch_size=batch_size, verbose=0)


def test(model: keras.Model, x: np.ndarray, y: np.ndarray) -> tuple[float, float]:
    """Evaluate the model. Returns (loss, accuracy)."""
    loss, accuracy = model.evaluate(x, y, verbose=0)
    return loss, accuracy
