"""Flower ClientApp: federated LLM fine-tuning with LoRA on each SuperNode."""

import torch
from flwr.client import ClientApp, NumPyClient
from flwr.common import Context
from transformers import TrainingArguments
from trl import SFTTrainer

from flower_demo.dataset import formatting_prompts_func, get_tokenizer_and_collator, load_data
from flower_demo.model import cosine_annealing, get_model, get_parameters, set_parameters

DEVICE = torch.device("cpu")


class FlowerClient(NumPyClient):
    """Flower client that fine-tunes a Qwen2-0.5B model with LoRA."""

    def __init__(self, model, train_dataset, tokenizer, collator, run_config):
        self.model = model
        self.train_dataset = train_dataset
        self.tokenizer = tokenizer
        self.collator = collator
        self.run_config = run_config

    def get_parameters(self, config):
        return get_parameters(self.model)

    def fit(self, parameters, config):
        set_parameters(self.model, parameters)

        # Cosine-annealed learning rate
        current_round = config.get("current_round", 1)
        total_rounds = config.get("total_rounds", 3)
        lr_max = float(self.run_config.get("learning-rate", 5e-5))
        lr = cosine_annealing(current_round, total_rounds, lr_max)

        max_steps = int(self.run_config.get("max-steps", 10))
        seq_length = int(self.run_config.get("seq-length", 512))
        batch_size = int(self.run_config.get("batch-size", 4))

        training_args = TrainingArguments(
            output_dir="./output",
            learning_rate=lr,
            per_device_train_batch_size=batch_size,
            max_steps=max_steps,
            logging_steps=1,
            save_strategy="no",
            gradient_accumulation_steps=1,
            no_cuda=True,
            report_to="none",
        )

        trainer = SFTTrainer(
            model=self.model,
            args=training_args,
            train_dataset=self.train_dataset,
            processing_class=self.tokenizer,
            data_collator=self.collator,
            formatting_func=formatting_prompts_func,
            max_seq_length=seq_length,
        )

        result = trainer.train()
        loss = result.training_loss

        return (
            get_parameters(self.model),
            len(self.train_dataset),
            {"train_loss": float(loss)},
        )


def client_fn(context: Context):
    """Create a FlowerClient for this SuperNode's data partition."""
    node_config = context.node_config
    num_partitions = int(node_config.get("num-partitions", 2))

    if "partition-id" in node_config:
        partition_id = int(node_config["partition-id"])
    else:
        partition_id = int(context.node_id) % num_partitions

    run_config = context.run_config
    lora_rank = int(run_config.get("lora-rank", 16))
    lora_alpha = int(run_config.get("lora-alpha", 32))

    model = get_model(lora_r=lora_rank, lora_alpha=lora_alpha)
    train_dataset = load_data(partition_id, num_partitions)
    tokenizer, collator = get_tokenizer_and_collator()

    return FlowerClient(model, train_dataset, tokenizer, collator, run_config).to_client()


# Flower ClientApp entry point
app = ClientApp(client_fn=client_fn)
