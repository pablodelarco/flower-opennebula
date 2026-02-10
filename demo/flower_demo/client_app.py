"""Flower ClientApp: local CIFAR-10 training on each SuperNode."""

import torch
from flwr.client import ClientApp, NumPyClient
from flwr.common import Context
from flwr_datasets import FederatedDataset
from flwr_datasets.partitioner import IidPartitioner
from torch.utils.data import DataLoader

from flower_demo.model import SimpleCNN, apply_transforms, get_weights, set_weights, test, train

DEVICE = torch.device("cuda" if torch.cuda.is_available() else "cpu")


class FlowerClient(NumPyClient):
    """Flower client that trains a SimpleCNN on a CIFAR-10 partition."""

    def __init__(self, net, trainloader, testloader, local_epochs):
        self.net = net
        self.trainloader = trainloader
        self.testloader = testloader
        self.local_epochs = local_epochs

    def get_parameters(self, config):
        return get_weights(self.net)

    def fit(self, parameters, config):
        set_weights(self.net, parameters)
        train(self.net, self.trainloader, self.local_epochs, DEVICE)
        return get_weights(self.net), len(self.trainloader.dataset), {}

    def evaluate(self, parameters, config):
        set_weights(self.net, parameters)
        loss, accuracy = test(self.net, self.testloader, DEVICE)
        return loss, len(self.testloader.dataset), {"accuracy": accuracy}


def client_fn(context: Context):
    """Create a FlowerClient for this SuperNode's data partition."""
    # Read partition config — auto-assigned in OneFlow, fallback for manual deploy
    node_config = context.node_config
    num_partitions = int(node_config.get("num-partitions", 2))

    if "partition-id" in node_config:
        partition_id = int(node_config["partition-id"])
    else:
        # Manual deployment fallback: deterministic partition from node ID
        partition_id = int(context.node_id) % num_partitions

    # Read run config
    run_config = context.run_config
    local_epochs = int(run_config.get("local-epochs", 1))
    batch_size = int(run_config.get("batch-size", 32))

    # Load CIFAR-10 partition
    fds = FederatedDataset(
        dataset="uoft-cs/cifar10",
        partitioners={"train": IidPartitioner(num_partitions=num_partitions)},
    )
    train_partition = fds.load_partition(partition_id, "train")
    test_partition = fds.load_split("test")

    train_partition = train_partition.with_transform(apply_transforms)
    test_partition = test_partition.with_transform(apply_transforms)

    trainloader = DataLoader(train_partition, batch_size=batch_size, shuffle=True)
    testloader = DataLoader(test_partition, batch_size=batch_size)

    net = SimpleCNN().to(DEVICE)
    return FlowerClient(net, trainloader, testloader, local_epochs).to_client()


# Flower ClientApp entry point
app = ClientApp(client_fn=client_fn)
