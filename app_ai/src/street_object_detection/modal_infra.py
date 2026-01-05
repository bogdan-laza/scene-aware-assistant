import modal
import os
from .paths import get_path_model_checkpoints_in_modal_volume

def get_image() -> modal.Image:
    """
    Defines the Docker image for the Modal app.
    Includes all dependencies for fine-tuning.
    """
    return (
        modal.Image.debian_slim(python_version="3.11")
        .pip_install(
            "torch",
            "torchvision",
            "transformers",
            "datasets",
            "peft",
            "trl",
            "wandb",
            "accelerate",
            "bitsandbytes",
            "scikit-learn",
            "pydantic-settings",
            "huggingface_hub",
            "hf_transfer",
            "pillow",
            "numpy",
            "matplotlib",
            "outlines",
            "seaborn"
        )
        .env({"HF_HUB_ENABLE_HF_TRANSFER": "1"})
    )

def get_app(name: str) -> modal.App:
    return modal.App(name)

def get_volume(name: str) -> modal.Volume:
    """Retrieves or creates a Modal Volume."""
    return modal.Volume.from_name(name, create_if_missing=True)

def get_secrets() -> list[modal.Secret]:
    """
    Returns the list of secrets required.
    Acum atașăm ambele secrete esențiale (HuggingFace și WandB) necondiționat.
    """
    secrets = [modal.Secret.from_name("huggingface-secret")]
    
    secrets.append(modal.Secret.from_name("wandb-secret"))
         
    return secrets

def get_retries(max_retries: int = 1):
    return modal.Retries(
        max_retries=max_retries,
        backoff_coefficient=2.0,
        initial_delay=1.0,
    )

get_docker_image = get_image
get_modal_app = get_app