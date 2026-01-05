from typing import Any, List, Tuple

def create_batches(dataset, config) -> List[Tuple[List[Any], List[Any]]]:
    """
    Creates batches from the dataset based on the configuration.
    Handles both mapped labels and raw text labels.
    """
    batches = []
    current_batch_images = []
    current_batch_labels = []

    for sample in dataset:
        image = sample[config.image_column]
        raw_label = sample[config.label_column]

        if config.label_mapping and len(config.label_mapping) > 0:
            try:
                label = config.label_mapping[raw_label]
            except KeyError:
                label = raw_label
        else:
            label = raw_label

        current_batch_images.append(image)
        current_batch_labels.append(label)

        if len(current_batch_images) == config.batch_size:
            batches.append((current_batch_images, current_batch_labels))
            current_batch_images = []
            current_batch_labels = []

    if current_batch_images:
        batches.append((current_batch_images, current_batch_labels))

    return batches