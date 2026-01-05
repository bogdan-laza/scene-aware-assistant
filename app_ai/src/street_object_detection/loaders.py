import os
import datasets
from datasets import concatenate_datasets
from transformers import AutoModelForImageTextToText, AutoProcessor
from huggingface_hub import login
from pathlib import Path


def fix_model_type_in_config_json(model_id: str):
    import json
    config_path = Path(model_id) / "config.json"
    if not config_path.exists(): return
    with open(config_path, "r") as f:
        config = json.load(f)
    if config.get("model_type") == "lfm2-vl":
        config["model_type"] = "lfm2_vl"
        with open(config_path, "w") as f:
            json.dump(config, f, indent=2)

def load_model_and_processor(model_id: str, cache_dir: str = "/models") -> tuple:
    direct_path = Path(cache_dir) / model_id
    if direct_path.exists():
        fix_model_type_in_config_json(str(direct_path))
        processor = AutoProcessor.from_pretrained(str(direct_path), max_image_tokens=256, local_files_only=True)
        model = AutoModelForImageTextToText.from_pretrained(
            str(direct_path), torch_dtype="bfloat16", device_map="auto", local_files_only=True
        )
        return model, processor

    hf_token = os.getenv("HF_TOKEN")
    if hf_token: login(token=hf_token)
    processor = AutoProcessor.from_pretrained(model_id, max_image_tokens=256, token=hf_token)
    model = AutoModelForImageTextToText.from_pretrained(model_id, torch_dtype="bfloat16", device_map="auto", token=hf_token)
    return model, processor

def load_dataset(dataset_name, splits, n_samples=None, seed=42, cache_dir="/datasets"):
    
    if dataset_name == "crosswalk-test-only":
        print("🔍 Loading Recaptcha Validation Set as Test...")
        try:
            ds = datasets.load_dataset("nobodyPerfecZ/recaptchav2-29k", split="validation", cache_dir=cache_dir)
        except:
            print(" Validation split empty, taking from end of Train...")
            ds = datasets.load_dataset("nobodyPerfecZ/recaptchav2-29k", split="train", cache_dir=cache_dir)
            ds = ds.select(range(len(ds) - 1000, len(ds))) 

        def format_test(batch):
            texts = []
            for i in range(len(batch['image'])):
                is_crosswalk = False
                if 'labels' in batch and len(batch['labels']) > i:
                    lbl = batch['labels'][i]
                    if isinstance(lbl, list) and len(lbl) > 3:
                        is_crosswalk = lbl[3] == 1
                
                texts.append("zebra" if is_crosswalk else "none")
            return {'image': batch['image'], 'text_label': texts}

        valid_cols = [c for c in ds.column_names if c != 'image']
        ds = ds.map(format_test, batched=True, remove_columns=valid_cols)
        
        if n_samples:
            ds = ds.shuffle(seed=seed).select(range(min(len(ds), n_samples)))
            
        print(f"Loaded {len(ds)} images for testing.")
        return ds

    print("🚶 Loading Crosswalk Dataset (Mixed)...")
    try:
        ds_cross = datasets.load_dataset("nobodyPerfecZ/recaptchav2-29k", split="train", cache_dir=cache_dir)
    except:
        ds_cross = datasets.load_dataset("keremberke/pedestrian-crossing-detection", "full", split="train", cache_dir=cache_dir)

    def format_cross(batch):
        texts = []
        for i in range(len(batch['image'])):
            is_crosswalk = False
            if 'labels' in batch and len(batch['labels']) > i:
                if isinstance(batch['labels'][i], list) and len(batch['labels'][i]) > 3:
                    is_crosswalk = batch['labels'][i][3] == 1
            elif 'objects' in batch and len(batch['objects']) > i:
                if len(batch['objects'][i]['category']) > 0:
                    is_crosswalk = True
            
            texts.append("zebra" if is_crosswalk else "none")
        return {'image': batch['image'], 'text_label': texts}

    valid_cols = [c for c in ds_cross.column_names if c != 'image']
    ds_cross = ds_cross.map(format_cross, batched=True, remove_columns=valid_cols)

    print("🚦 Loading Traffic Light Dataset...")
    ds_lights = None
    light_mapping = {0: "red", 1: "yellow", 2: "green"}

    try:
        ds_lights = datasets.load_dataset("mehmetkeremturkcan/traffic-lights-of-new-york", split="train", cache_dir=cache_dir)
    except Exception as e:
        print(f"Main traffic dataset failed. Trying fallback...")
        try:
            ds_lights = datasets.load_dataset("lucasvandroux/traffic-lights-classification", split="train", cache_dir=cache_dir)
        except Exception as e2:
            print(f"Fallback dataset failed.")

    def format_lights(batch):
        texts = []
        for i in range(len(batch['image'])):
            text = "UNK"
            if 'objects' in batch and len(batch['objects']) > i:
                cats = batch['objects'][i].get('category', [])
                if len(cats) > 0:
                    text = light_mapping.get(cats[0], "UNK")
            elif 'label' in batch:
                text = light_mapping.get(batch['label'][i], "UNK")
            elif 'labels' in batch:
                lbl = batch['labels'][i]
                if isinstance(lbl, int): text = light_mapping.get(lbl, "UNK")
            texts.append(text)
        return {'image': batch['image'], 'text_label': texts}

    if ds_lights is not None:
        cols_to_remove = [c for c in ds_lights.column_names if c != 'image']
        try:
            ds_lights = ds_lights.map(format_lights, batched=True, remove_columns=cols_to_remove)
            ds_lights = ds_lights.filter(lambda x: x['text_label'] != "UNK")
        except Exception as e:
            ds_lights = None

    if ds_lights is None or 'text_label' not in ds_lights.column_names or len(ds_lights) == 0:
        print("TRAFFIC LIGHT DATA MISSING OR BROKEN. Generating dummy samples.")
        ds_lights = ds_cross.select(range(min(50, len(ds_cross))))
        def force_none(batch):
            return {'text_label': ["none"] * len(batch['image'])}
        ds_lights = ds_lights.map(force_none, batched=True)

    ds_cross = ds_cross.select_columns(['image', 'text_label'])
    ds_lights = ds_lights.select_columns(['image', 'text_label'])

    if n_samples:
        num_lights = min(len(ds_lights), n_samples // 2)
        num_cross = min(len(ds_cross), n_samples - num_lights)
        print(f"Final Balance: {num_cross} crosswalks and {num_lights} traffic lights/dummies.")
        ds_cross_sub = ds_cross.shuffle(seed=seed).select(range(num_cross))
        ds_lights_sub = ds_lights.shuffle(seed=seed).select(range(num_lights))
        mixed_ds = concatenate_datasets([ds_cross_sub, ds_lights_sub])
    else:
        mixed_ds = concatenate_datasets([ds_cross, ds_lights])

    return mixed_ds.shuffle(seed=seed)