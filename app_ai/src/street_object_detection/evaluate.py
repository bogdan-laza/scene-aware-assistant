import time
import tempfile
from tqdm import tqdm
import wandb
import matplotlib.pyplot as plt
from .config import EvaluationConfig
from .inference import get_model_output
from .loaders import load_dataset, load_model_and_processor
from .modal_infra import get_docker_image, get_modal_app, get_secrets, get_volume
from .report import EvalReport
from .batching import create_batches

app = get_modal_app("pedestrian-assistant")
image = get_docker_image()
datasets_volume = get_volume("datasets")
models_volume = get_volume("models")

def parse_prediction(text):
    text = text.lower().strip()
    
    if "cannot" in text or "pictured" in text or "provide" in text or "sorry" in text:
        return "unknown"

    if "no zebra" in text or "no traffic" in text or "clear" in text or "safe" in text or "none" in text:
        return "none"

    if "red" in text: return "red"
    if "green" in text: return "green"
    if "zebra" in text or "crosswalk" in text or "crossing" in text: return "zebra"
        
    return "unknown"

def parse_label(text):
    return text.lower().strip()

@app.function(
    image=image, gpu="L40S",
    volumes={"/datasets": datasets_volume, "/models": models_volume},
    secrets=get_secrets(), timeout=3600
)
def evaluate(config: EvaluationConfig) -> EvalReport:
    wandb.init(project=config.wandb_project_name, config=config.model_dump())
    
    dataset = load_dataset(dataset_name=config.dataset, splits=[config.split], n_samples=config.n_samples, cache_dir="/datasets")
    model, processor = load_model_and_processor(model_id=config.model, cache_dir="/models")
    eval_report = EvalReport()
    batches = create_batches(dataset, config)

    print("🚀 Începere Evaluare...")
    
    for batch_images, batch_labels in tqdm(batches, desc="Evaluare"):
        for image, raw_label in zip(batch_images, batch_labels):
            conversation = [
                {"role": "system", "content": [{"type": "text", "text": config.system_prompt}]},
                {"role": "user", "content": [{"type": "image", "image": image}, {"type": "text", "text": config.user_prompt}]}
            ]
            
            raw_pred = get_model_output(model, processor, conversation, max_new_tokens=30)
            
            clean_pred = parse_prediction(raw_pred)
            clean_label = parse_label(raw_label)
            
            eval_report.add_record(image, clean_label, clean_pred)

    for m_type in ["safety", "type", "detailed"]:
        fig = eval_report.plot_matrix(mode=m_type)
        if fig:
            with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as tmp:
                fig.savefig(tmp.name, dpi=200, bbox_inches='tight')
                wandb.log({f"confusion_matrix_{m_type}": wandb.Image(tmp.name)})
                plt.close(fig)

    acc = eval_report.get_accuracy()
    wandb.log({"final_accuracy": acc})
    wandb.finish()
    return eval_report

@app.local_entrypoint()
def main(config_file_name: str):
    config = EvaluationConfig.from_yaml(config_file_name)
    report = evaluate.remote(config)
    print(f"✅ Evaluare terminată. Acuratețe: {report.get_accuracy():.2f}")
    report.to_csv()