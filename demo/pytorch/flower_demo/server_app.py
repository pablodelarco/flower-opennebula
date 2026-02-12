"""Flower ServerApp: FedAvg strategy for CIFAR-10 classification.

IMPORTANT: This module must NOT import torch or any ML framework.
The ServerApp runs on the SuperLink container which only has flwr installed.
"""

from flwr.server import ServerApp, ServerAppComponents, ServerConfig
from flwr.server.strategy import FedAvg


def server_fn(context):
    """Configure the FedAvg strategy and server."""
    num_rounds = int(context.run_config.get("num-server-rounds", 3))

    strategy = FedAvg(
        fraction_fit=1.0,
        fraction_evaluate=1.0,
        min_fit_clients=2,
        min_available_clients=2,
        # No initial_parameters: first client's weights become the starting point.
        # This avoids importing torch on the SuperLink.
    )

    config = ServerConfig(num_rounds=num_rounds)
    return ServerAppComponents(strategy=strategy, config=config)


# Flower ServerApp entry point
app = ServerApp(server_fn=server_fn)
