from pathlib import Path


def get_path_to_configs() -> str:
    path = str(Path(__file__).parent.parent.parent / "configs")

    Path(path).mkdir(parents=True, exist_ok=True)

    return path


def get_path_to_evals() -> str:
    path = str(Path(__file__).parent.parent.parent / "evals")

    Path(path).mkdir(parents=True, exist_ok=True)

    return path


from pathlib import Path

def get_path_model_checkpoints_in_modal_volume(experiment_name: str) -> Path:
    """
    Returns the path where checkpoints should be stored within the Modal Volume.
    """
    base_path = Path("/model_checkpoints")
    return base_path / experiment_name


def get_path_model_checkpoints() -> str:
    """Returns path to the local model checkpoints."""
    path = str(Path(__file__).parent.parent.parent / "model_checkpoints")

    Path(path).mkdir(parents=True, exist_ok=True)

    return path