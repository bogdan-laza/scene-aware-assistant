from datasets import Dataset

def split_dataset(
    dataset: Dataset,
    test_size: float = 0.1,
    seed: int = 42,
) -> tuple[Dataset, Dataset]:
    """Splits a dataset into training and testing sets."""
    if not 0 < test_size < 1:
        raise ValueError("test_size must be between 0 and 1")
    
    split = dataset.train_test_split(test_size=test_size, seed=seed)
    return split["train"], split["test"]

def format_dataset_as_conversation(
    dataset: Dataset,
    system_prompt: str,
    user_prompt: str,
    image_column: str,
    label_column: str,
    label_mapping: dict = None,
) -> Dataset:
    
    def format_sample(sample):
        answer = sample['text_label']

        return [
            {"role": "system", "content": [{"type": "text", "text": system_prompt}]},
            {
                "role": "user",
                "content": [
                    {"type": "image", "image": sample[image_column]},
                    {"type": "text", "text": user_prompt},
                ],
            },
            {
                "role": "assistant",
                "content": [{"type": "text", "text": answer}],
            },
        ]

    return [format_sample(s) for s in dataset]