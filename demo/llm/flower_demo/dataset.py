"""Alpaca-GPT4 dataset loading and tokenization for federated LLM training."""

from flwr_datasets import FederatedDataset
from flwr_datasets.partitioner import IidPartitioner
from transformers import AutoTokenizer
from trl import DataCollatorForCompletionOnlyLM

from flower_demo.model import MODEL_NAME

ALPACA_TEMPLATE = """Below is an instruction that describes a task, paired with an input that provides further context. Write a response that appropriately completes the request.

### Instruction:
{instruction}

### Input:
{input}

### Response:
{output}"""


def formatting_prompts_func(examples):
    """Format Alpaca-GPT4 examples into instruction-following prompts."""
    output_texts = []
    for i in range(len(examples["instruction"])):
        text = ALPACA_TEMPLATE.format(
            instruction=examples["instruction"][i],
            input=examples["input"][i],
            output=examples["output"][i],
        )
        output_texts.append(text)
    return output_texts


def get_tokenizer_and_collator(model_name: str = MODEL_NAME):
    """Return tokenizer and data collator for completion-only LM training."""
    tokenizer = AutoTokenizer.from_pretrained(model_name)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token
    response_template = "\n### Response:"
    collator = DataCollatorForCompletionOnlyLM(
        response_template=response_template,
        tokenizer=tokenizer,
    )
    return tokenizer, collator


def load_data(partition_id: int, num_partitions: int):
    """Load an IID partition of the Alpaca-GPT4 dataset."""
    fds = FederatedDataset(
        dataset="vicgalle/alpaca-gpt4",
        partitioners={"train": IidPartitioner(num_partitions=num_partitions)},
    )
    return fds.load_partition(partition_id, "train")
