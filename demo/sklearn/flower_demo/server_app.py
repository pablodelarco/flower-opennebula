"""Flower ServerApp: configurable strategy for CIFAR-10 classification.

IMPORTANT: This module must NOT import torch or any ML framework.
The ServerApp runs on the SuperLink container which only has flwr installed.
"""

from flwr.server import ServerApp, ServerAppComponents, ServerConfig
from flwr.server.strategy import FedAvg, FedProx, FedAdam

STRATEGY_MAP = {
    "FedAvg": FedAvg,
    "FedProx": FedProx,
    "FedAdam": FedAdam,
}


def server_fn(context):
    """Configure the strategy and server from run config."""
    cfg = context.run_config
    num_rounds = int(cfg.get("num-server-rounds", 3))
    strategy_name = cfg.get("strategy", "FedAvg")
    min_fit = int(cfg.get("min-fit-clients", 2))
    min_available = int(cfg.get("min-available-clients", 2))

    strategy_cls = STRATEGY_MAP.get(strategy_name, FedAvg)

    kwargs = dict(
        fraction_fit=1.0,
        fraction_evaluate=1.0,
        min_fit_clients=min_fit,
        min_available_clients=min_available,
    )

    if strategy_name == "FedProx":
        kwargs["proximal_mu"] = float(cfg.get("proximal-mu", 1.0))
    elif strategy_name == "FedAdam":
        kwargs["eta"] = float(cfg.get("server-lr", 0.01))
        kwargs["tau"] = float(cfg.get("tau", 0.1))

    strategy = strategy_cls(**kwargs)
    config = ServerConfig(num_rounds=num_rounds)
    return ServerAppComponents(strategy=strategy, config=config)


# Flower ServerApp entry point
app = ServerApp(server_fn=server_fn)
