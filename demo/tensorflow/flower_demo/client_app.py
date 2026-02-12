"""Flower ClientApp: local CIFAR-10 training on each SuperNode (TensorFlow)."""

import numpy as np
from flwr.client import ClientApp, NumPyClient
from flwr.common import Context
from flwr_datasets import FederatedDataset
from flwr_datasets.partitioner import IidPartitioner

from flower_demo.model import SimpleCNN, get_weights, set_weights, test, train


class FlowerClient(NumPyClient):
    """Flower client that trains a Keras CNN on a CIFAR-10 partition."""

    def __init__(self, model, x_train, y_train, x_test, y_test, local_epochs, batch_size):
        self.model = model
        self.x_train = x_train
        self.y_train = y_train
        self.x_test = x_test
        self.y_test = y_test
        self.local_epochs = local_epochs
        self.batch_size = batch_size

    def get_parameters(self, config):
        return get_weights(self.model)

    def fit(self, parameters, config):
        set_weights(self.model, parameters)
        train(self.model, self.x_train, self.y_train,
              self.local_epochs, self.batch_size)
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

    run_config = context.run_config
    local_epochs = int(run_config.get("local-epochs", 1))
    batch_size = int(run_config.get("batch-size", 32))

    # Load CIFAR-10 partition as numpy arrays
    fds = FederatedDataset(
        dataset="uoft-cs/cifar10",
        partitioners={"train": IidPartitioner(num_partitions=num_partitions)},
    )
    train_partition = fds.load_partition(partition_id, "train")
    test_partition = fds.load_split("test")

    train_partition.set_format("numpy")
    test_partition.set_format("numpy")

    x_train = train_partition["img"].astype(np.float32) / 255.0
    y_train = train_partition["label"]
    x_test = test_partition["img"].astype(np.float32) / 255.0
    y_test = test_partition["label"]

    model = SimpleCNN()
    return FlowerClient(
        model, x_train, y_train, x_test, y_test, local_epochs, batch_size,
    ).to_client()


# Flower ClientApp entry point
app = ClientApp(client_fn=client_fn)
