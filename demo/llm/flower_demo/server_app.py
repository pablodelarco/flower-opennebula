"""Flower ServerApp for federated LLM fine-tuning.

IMPORTANT: This module must NOT import torch or any ML framework.
The ServerApp runs on the SuperLink container which only has flwr installed.
"""

from flwr.server import ServerApp, ServerAppComponents, ServerConfig
from flwr.server.strategy import FedAvg


def server_fn(context):
    """Configure the strategy and server from run config."""
    cfg = context.run_config
    num_rounds = int(cfg.get("num-server-rounds", 3))
    min_fit = int(cfg.get("min-fit-clients", 2))
    min_available = int(cfg.get("min-available-clients", 2))

    def on_fit_config_fn(server_round: int):
        return {"current_round": server_round, "total_rounds": num_rounds}

    strategy = FedAvg(
        fraction_fit=1.0,
        fraction_evaluate=0.0,  # No eval for LLM — too slow on CPU
        min_fit_clients=min_fit,
        min_available_clients=min_available,
        on_fit_config_fn=on_fit_config_fn,
    )
    config = ServerConfig(num_rounds=num_rounds)
    return ServerAppComponents(strategy=strategy, config=config)


# Flower ServerApp entry point
app = ServerApp(server_fn=server_fn)
