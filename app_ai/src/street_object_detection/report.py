import csv
import textwrap
from datetime import datetime
from pathlib import Path
from typing import Self
import numpy as np
import matplotlib.pyplot as plt
import seaborn as sns
from sklearn.metrics import confusion_matrix

from .paths import get_path_to_evals

class EvalReport:
    def __init__(self):
        self.records = []

    def add_record(self, image, ground_truth: str, predicted: str):
        gt_clean = ground_truth.strip().lower()
        pred_clean = predicted.strip().lower()
        
        is_correct = gt_clean == pred_clean
        if pred_clean == 'unknown':
            is_correct = False

        self.records.append({
            "ground_truth": gt_clean,
            "predicted": pred_clean,
            "correct": is_correct,
        })

    def to_csv(self) -> str:
        path = Path(get_path_to_evals())
        
        if not path.exists():
            path.mkdir(parents=True, exist_ok=True)
            
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        csv_file_path = str(path / f"predictions_{timestamp}.csv")
        
        with open(csv_file_path, "w", newline="", encoding="utf-8") as csvfile:
            writer = csv.DictWriter(csvfile, fieldnames=["ground_truth", "predicted", "correct"])
            writer.writeheader()
            writer.writerows(self.records)
            
        print(f"📄 Predictions saved locally to: {csv_file_path}")
        return csv_file_path

    def _get_safety_category(self, text: str) -> str:
        t = text.lower()
        if "green" in t: return "GO (Safe)"
        if "zebra" in t or "crosswalk" in t: return "STOP/ALERT (Pedestrian)"
        if "red" in t or "yellow" in t: return "STOP (Traffic Light)"
        if "none" in t or "clear" in t: return "GO (Clear Road)"
        return "UNKNOWN"

    def _get_object_type(self, text: str) -> str:
        t = text.lower()
        if "red" in t or "green" in t or "yellow" in t: return "Traffic Light"
        if "zebra" in t or "crosswalk" in t: return "Crosswalk"
        if "none" in t: return "Background/None"
        return "Unknown"

    def plot_matrix(self, mode="detailed"):
        if not self.records: return None

        if mode == "safety":
            gt = [self._get_safety_category(r["ground_truth"]) for r in self.records]
            pred = [self._get_safety_category(r["predicted"]) for r in self.records]
            title = "Safety Decision Matrix"
        elif mode == "type":
            gt = [self._get_object_type(r["ground_truth"]) for r in self.records]
            pred = [self._get_object_type(r["predicted"]) for r in self.records]
            title = "Object Detection Matrix"
        else:
            gt = [r["ground_truth"] for r in self.records]
            pred = [r["predicted"] for r in self.records]
            title = "Detailed Confusion Matrix"

        classes = sorted(list(set(gt + pred)))
        if not classes: return None

        try:
            cm = confusion_matrix(gt, pred, labels=classes)
        except ValueError: return None

        fig, ax = plt.subplots(figsize=(10, 8))
        sns.heatmap(cm, annot=True, fmt="d", cmap="Blues", xticklabels=classes, yticklabels=classes)
        plt.title(title, fontsize=14, fontweight="bold", pad=20)
        plt.xlabel("Predicted", fontsize=12)
        plt.ylabel("Ground Truth", fontsize=12)
        plt.xticks(rotation=45, ha="right")
        plt.yticks(rotation=0)
        plt.tight_layout()
        return fig

    def get_accuracy(self) -> float:
        if not self.records: return 0.0
        return sum(1 for r in self.records if r["correct"]) / len(self.records)