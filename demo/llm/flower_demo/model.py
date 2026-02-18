"""Qwen2-0.5B-Instruct with LoRA and helper functions."""

import math
from collections import OrderedDict

import torch
from peft import LoraConfig, get_peft_model, get_peft_model_state_dict, set_peft_model_state_dict
from transformers import AutoModelForCausalLM

MODEL_NAME = "Qwen/Qwen2-0.5B-Instruct"


def get_model(lora_r: int = 16, lora_alpha: int = 32):
    """Load base model with LoRA adapters (CPU, float32)."""
    base = AutoModelForCausalLM.from_pretrained(
        MODEL_NAME, torch_dtype=torch.float32, device_map="cpu",
    )
    lora_config = LoraConfig(
        r=lora_r,
        lora_alpha=lora_alpha,
        target_modules=["q_proj", "v_proj"],
        lora_dropout=0.05,
        bias="none",
        task_type="CAUSAL_LM",
    )
    return get_peft_model(base, lora_config)


def get_parameters(model) -> list:
    """Extract LoRA-only weights as a list of NumPy arrays."""
    state_dict = get_peft_model_state_dict(model)
    return [val.cpu().numpy() for val in state_dict.values()]


def set_parameters(model, params: list) -> None:
    """Load LoRA weights into the model."""
    keys = list(get_peft_model_state_dict(model).keys())
    state_dict = OrderedDict({k: torch.tensor(v) for k, v in zip(keys, params)})
    set_peft_model_state_dict(model, state_dict)


def cosine_annealing(current_round: int, total_rounds: int, lr_max: float, lr_min: float = 0.0) -> float:
    """Cosine annealing learning rate schedule."""
    return lr_min + 0.5 * (lr_max - lr_min) * (1 + math.cos(math.pi * current_round / total_rounds))
