import os
import torch
import io
from contextlib import asynccontextmanager
from fastapi import FastAPI, UploadFile, File, Form, HTTPException
from fastapi.responses import JSONResponse
from PIL import Image
from transformers import AutoModelForImageTextToText, AutoProcessor, BitsAndBytesConfig

MODEL_ID = "LiquidAI/LFM2-VL-3B"

os.environ["CUDA_VISSIBLE_DEVICES"] = "0"

model = None
processor = None

@asynccontextmanager
async def lifespan(app: FastAPI):
    global model, processor
    print("Server starting... Loading model: {MODEL_ID}")

    try:
        bnb_config = BitsAndBytesConfig(
            load_in_4bit=True,
            bnb_4bit_quant_type="nf4",
            bnb_4bit_compute_dtype=torch.float16,
            bnb_4bit_use_double_quant=True
        )

        model = AutoModelForImageTextToText.from_pretrained(
            MODEL_ID,
            quantization_config=bnb_config,
            device_map={"":0},
            torch_dtype=torch.float16
        )

        processor = AutoProcessor.from_pretrained(MODEL_ID)
        print("Model loaded succesfully")
    except Exception as e:
        print("Critical error: {e}")
        raise e 
    
    yield
    print("Server shutting down")


app = FastAPI(title="FPV Base Model", lifespan=lifespan)

def run_inference(image, prompt_text):
    global model, processor

    conversation = [
        {
            "role" : "user",
            "content" : [
                {"type": "image", "image": image},
                {"type": "text", "text": prompt_text},
            ],
        },
    ]

    text_prompt = processor.apply_chat_template(conversation, add_generation_prompt=True)

    inputs = processor(images=[image], text=text_prompt, return_tensors="pt").to("cuda")

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

@app.post("/obstacles")
async def detect_obstacles(file: UploadFile = File(...)):
    if file.content_type and not file.content_type.startswith("image/"):
        raise HTTPException(400, "File must be an image")
    
    contents = await file.read()
    image = Image.open(io.BytesIO(contents)).convert("RGB")

    prompt = (
        "Analyze this image from a navigation perspective. "
        "Are there any obstacles directly in front that would block movement? "
        "Describe them briefly."     
    )

    response = run_inference(image, prompt)
    return JSONResponse({"type": "obstacle_detection", "result": response})

@app.post("/crosswalk")
async def detect_crosswalk(file: UploadFile = File(...)):
    if file.content_type and not file.content_type.startswith("image/"):
        raise HTTPException(400, "File must be an image")

    contents = await file.read()
    image = Image.open(io.BytesIO(contents)).convert("RGB")

    prompt = (
        "Identify if there is a pedestrian crosswalk (zebra crossing) in this image."
    )    

    response = run_inference(image, prompt)
    return JSONResponse({"type": "crosswalk_analysis", "result": response})

@app.post("/custom")
async def custom_analysis(
    file: UploadFile = File(...),
    prompt: str = Form("Describe this image.")
):
    if file.content_type and not file.content_type.startswith("image/"):
        raise HTTPException(400, "File must be an image")
    
    contents = await file.read()
    image = Image.open(io.BytesIO(contents)).convert("RGB")

    response = run_inference(image, prompt)
    return JSONResponse({"type": "custom_query", "prompt": prompt, "result" : response})

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)