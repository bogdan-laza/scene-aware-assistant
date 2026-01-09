import os
import torch
import io
from contextlib import asynccontextmanager
from fastapi import FastAPI, UploadFile, File, Form, HTTPException
from fastapi.responses import JSONResponse
from typing import Optional
from PIL import Image
from transformers import AutoModelForImageTextToText, AutoProcessor, BitsAndBytesConfig
import uvicorn

MODEL_ID = "LiquidAI/LFM2-VL-3B"

# Global model and processor variables
model = None
processor = None
device = None  # Will be set to "cuda" or "cpu" based on availability

ALLOWED_IMAGE_TYPES = {"image/jpeg", "image/png"}
MAX_IMAGE_BYTES = 10 * 1024 * 1024  # 10MB


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Load and unload the AI model on server startup/shutdown."""
    global model, processor, device
    
    # Check if CUDA is available
    use_cuda = torch.cuda.is_available()
    device = "cuda" if use_cuda else "cpu"
    
    print(f"Server starting... Loading model: {MODEL_ID}")
    print(f"Using device: {device}")

    try:
        if use_cuda:
            # Use quantization on GPU to save memory
            bnb_config = BitsAndBytesConfig(
                load_in_4bit=True,
                bnb_4bit_quant_type="nf4",
                bnb_4bit_compute_dtype=torch.float16,
                bnb_4bit_use_double_quant=True
            )

            model = AutoModelForImageTextToText.from_pretrained(
                MODEL_ID,
                quantization_config=bnb_config,
                device_map={"": 0},
                torch_dtype=torch.float16
            )
        else:
            # CPU mode: no quantization (bitsandbytes requires CUDA)
            print("Warning: Running on CPU. This will be slower. Consider using a GPU for better performance.")
            model = AutoModelForImageTextToText.from_pretrained(
                MODEL_ID,
                device_map="cpu",
                torch_dtype=torch.float32  # Use float32 on CPU for better compatibility
            )

        processor = AutoProcessor.from_pretrained(MODEL_ID)
        print("Model loaded successfully")
    except Exception as e:
        print(f"Critical error loading model: {e}")
        raise e
    
    yield
    print("Server shutting down")


app = FastAPI(title="Scene Assistant Backend", lifespan=lifespan)


def run_inference(image: Image.Image, prompt_text: str) -> str:
    """
    Run inference on an image with a text prompt using the loaded model.
    
    Args:
        image: PIL Image object
        prompt_text: Text prompt for the model
        
    Returns:
        Generated text response from the model
    """
    global model, processor, device

    conversation = [
        {
            "role": "user",
            "content": [
                {"type": "image", "image": image},
                {"type": "text", "text": prompt_text},
            ],
        },
    ]

    text_prompt = processor.apply_chat_template(conversation, add_generation_prompt=True)

    inputs = processor(images=[image], text=text_prompt, return_tensors="pt").to(device)

    with torch.no_grad():
        output_ids = model.generate(
            **inputs,
            max_new_tokens=200,
            do_sample=False,
            temperature=None,
            top_p=None
        )

    generated_text = processor.decode(output_ids[0], skip_special_tokens=True)

    if "assistant" in generated_text:
        return generated_text.split("assistant")[-1].strip()
    return generated_text


@app.get("/health")
def health_check():
    """Health check endpoint to verify server and model are running."""
    model_status = "loaded" if model is not None and processor is not None else "not loaded"
    return {
        "status": "OK",
        "message": "Server is running smoothly",
        "model_status": model_status
    }


async def validate_image(file: Optional[UploadFile]) -> None:
    # NOTE: Accepting File(None) lets us return 400 (contract) instead of 422.
    if file is None:
        raise HTTPException(status_code=400, detail="Missing file")

    if file.content_type not in ALLOWED_IMAGE_TYPES:
        raise HTTPException(status_code=400, detail="File must be an image")

    # Basic size guardrail (prevents accidental huge uploads).
    data = await file.read()
    if not data:
        raise HTTPException(status_code=400, detail="Missing file")
    if len(data) > MAX_IMAGE_BYTES:
        raise HTTPException(status_code=400, detail="Image too large")

    # Reset for downstream consumers that may need to read again.
    await file.seek(0)


@app.post("/obstacles")
async def obstacles(file: Optional[UploadFile] = File(None)):
    await validate_image(file)

    if model is None or processor is None:
        raise HTTPException(status_code=503, detail="AI model not loaded")

    contents = await file.read()
    image = Image.open(io.BytesIO(contents)).convert("RGB")

    # MODIFIED PROMPT: Safety-focused, explicit warnings, no apologies.
    prompt = (
        "You are a safety assistant for a blind pedestrian. "
        "Analyze this image for immediate dangers. "
        "If there is a car approaching or a blocking obstacle, warn the user loudly starting with 'Be aware!'. "
        "Otherwise, briefly describe the path ahead. "
        "Do not apologize or say 'I might be wrong'."
    )

    try:
        response = run_inference(image, prompt)
        return JSONResponse(
            content={
                "type": "obstacle_detection",
                "result": response,
                "confidence": 0.65,  # Default confidence value
            }
        )
    except Exception as e:
        print(f"Error in obstacle detection: {e}")
        raise HTTPException(status_code=500, detail=f"AI processing failed: {str(e)}")


@app.post("/crosswalk")
async def crosswalk(file: Optional[UploadFile] = File(None)):
    await validate_image(file)

    if model is None or processor is None:
        raise HTTPException(status_code=503, detail="AI model not loaded")

    contents = await file.read()
    image = Image.open(io.BytesIO(contents)).convert("RGB")

    # MODIFIED PROMPT: Focus on blocking vehicles and safety confirmation.
    prompt = (
        "Check this image for a pedestrian crosswalk. "
        "If there is a car blocking it or approaching dangerously, say 'Be aware: Vehicle on crosswalk!'. "
        "Otherwise, confirm if it is safe to cross."
    )

    try:
        response = run_inference(image, prompt)
        return JSONResponse(
            content={
                "type": "crosswalk_analysis",
                "result": response,
                "confidence": 0.65,  # Default confidence value
            }
        )
    except Exception as e:
        print(f"Error in crosswalk detection: {e}")
        raise HTTPException(status_code=500, detail=f"AI processing failed: {str(e)}")


@app.post("/custom")
async def custom(file: Optional[UploadFile] = File(None), prompt: Optional[str] = Form(None)):
    await validate_image(file)

    if prompt is None or not prompt.strip():
        raise HTTPException(status_code=400, detail="Missing prompt")

    if model is None or processor is None:
        raise HTTPException(status_code=503, detail="AI model not loaded")

    clean_prompt = prompt.strip()
    contents = await file.read()
    image = Image.open(io.BytesIO(contents)).convert("RGB")

    try:
        response = run_inference(image, clean_prompt)
        return JSONResponse(
            content={
                "type": "custom_query",
                "prompt": clean_prompt,
                "result": response,
                "confidence": 0.65,  # Default confidence value
            }
        )
    except Exception as e:
        print(f"Error in custom query: {e}")
        raise HTTPException(status_code=500, detail=f"AI processing failed: {str(e)}")


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)