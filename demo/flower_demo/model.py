"""SimpleCNN for CIFAR-10 and helper functions."""

from collections import OrderedDict

import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.utils.data import DataLoader


class SimpleCNN(nn.Module):
    """Lightweight CNN for CIFAR-10 (~878K parameters).

    Architecture:
        Conv2d(3→32, 5×5, pad=1) → ReLU → MaxPool(2)
        Conv2d(32→64, 5×5, pad=1) → ReLU → MaxPool(2)
        Flatten → Linear(1600→512) → ReLU → Linear(512→10)
    """

    def __init__(self) -> None:
        super().__init__()
        self.conv1 = nn.Conv2d(3, 32, kernel_size=5, padding=1)
        self.conv2 = nn.Conv2d(32, 64, kernel_size=5, padding=1)
        self.pool = nn.MaxPool2d(2, 2)
        self.fc1 = nn.Linear(64 * 5 * 5, 512)
        self.fc2 = nn.Linear(512, 10)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = self.pool(F.relu(self.conv1(x)))
        x = self.pool(F.relu(self.conv2(x)))
        x = x.view(x.size(0), -1)
        x = F.relu(self.fc1(x))
        x = self.fc2(x)
        return x


def get_weights(net: nn.Module) -> list[list[float]]:
    """Extract model parameters as a list of NumPy arrays."""
    return [val.cpu().numpy() for _, val in net.state_dict().items()]


def set_weights(net: nn.Module, parameters: list) -> None:
    """Load parameters into a model."""
    params_dict = zip(net.state_dict().keys(), parameters)
    state_dict = OrderedDict({k: torch.tensor(v) for k, v in params_dict})
    net.load_state_dict(state_dict, strict=True)


def apply_transforms(batch: dict) -> dict:
    """Convert PIL images to tensors and normalize for CIFAR-10."""
    from torchvision.transforms import Compose, Normalize, ToTensor

    transform = Compose([ToTensor(), Normalize((0.5, 0.5, 0.5), (0.5, 0.5, 0.5))])
    batch["img"] = [transform(img) for img in batch["img"]]
    return batch


def train(
    net: nn.Module, trainloader: DataLoader, epochs: int, device: torch.device
) -> None:
    """Train the model on local data."""
    net.to(device)
    net.train()
    criterion = nn.CrossEntropyLoss()
    optimizer = torch.optim.SGD(net.parameters(), lr=0.01, momentum=0.9)
    for _ in range(epochs):
        for batch in trainloader:
            images = batch["img"].to(device)
            labels = batch["label"].to(device)
            optimizer.zero_grad()
            loss = criterion(net(images), labels)
            loss.backward()
            optimizer.step()


def test(
    net: nn.Module, testloader: DataLoader, device: torch.device
) -> tuple[float, float]:
    """Evaluate the model. Returns (loss, accuracy)."""
    net.to(device)
    net.eval()
    criterion = nn.CrossEntropyLoss()
    correct, total, total_loss = 0, 0, 0.0
    with torch.no_grad():
        for batch in testloader:
            images = batch["img"].to(device)
            labels = batch["label"].to(device)
            outputs = net(images)
            total_loss += criterion(outputs, labels).item() * labels.size(0)
            _, predicted = torch.max(outputs, 1)
            total += labels.size(0)
            correct += (predicted == labels).sum().item()
    return total_loss / total, correct / total
