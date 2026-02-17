"""Flower ClientApp: local CIFAR-10 training on each SuperNode (scikit-learn)."""

import numpy as np
from flwr.client import ClientApp, NumPyClient
from flwr.common import Context
from flwr_datasets import FederatedDataset
from flwr_datasets.partitioner import IidPartitioner

from flower_demo.model import create_model, get_weights, set_weights, init_model, test, train


class FlowerClient(NumPyClient):
    """Flower client that trains an MLPClassifier on a CIFAR-10 partition."""

    def __init__(self, model, x_train, y_train, x_test, y_test):
        self.model = model
        self.x_train = x_train
        self.y_train = y_train
        self.x_test = x_test
        self.y_test = y_test

    def get_parameters(self, config):
        return get_weights(self.model)

    def fit(self, parameters, config):
        set_weights(self.model, parameters)
        train(self.model, self.x_train, self.y_train)
        return get_weights(self.model), len(self.x_train), {}

    def evaluate(self, parameters, config):
        set_weights(self.model, parameters)
        loss, accuracy = test(self.model, self.x_test, self.y_test)
        return loss, len(self.x_test), {"accuracy": accuracy}


def client_fn(context: Context):
    """Create a FlowerClient for this SuperNode's data partition."""
    node_config = context.node_config
    num_partitions = int(node_config.get("num-partitions", 2))

    if "partition-id" in node_config:
        partition_id = int(node_config["partition-id"])
    else:
        partition_id = int(context.node_id) % num_partitions

    # Load CIFAR-10 partition as numpy arrays (flattened for sklearn)
    fds = FederatedDataset(
        dataset="uoft-cs/cifar10",
        partitioners={"train": IidPartitioner(num_partitions=num_partitions)},
    )
    train_partition = fds.load_partition(partition_id, "train")
    test_partition = fds.load_split("test")

    # Flatten 32×32×3 images to 3072-dim vectors for MLP
    x_train = np.array(train_partition["img"], dtype=np.float32).reshape(-1, 3072) / 255.0
    y_train = np.array(train_partition["label"])
    x_test = np.array(test_partition["img"], dtype=np.float32).reshape(-1, 3072) / 255.0
    y_test = np.array(test_partition["label"])

    model = create_model()
    init_model(model, n_features=3072, n_classes=10)

    return FlowerClient(model, x_train, y_train, x_test, y_test).to_client()


# Flower ClientApp entry point
app = ClientApp(client_fn=client_fn)
