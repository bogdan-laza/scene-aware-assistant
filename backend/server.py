from fastapi import FastAPI, UploadFile, File, Form, HTTPException
from fastapi.responses import JSONResponse
from typing import Optional
import uvicorn

app = FastAPI(title="Scene Assistant Backend")

ALLOWED_IMAGE_TYPES = {"image/jpeg", "image/png"}
MAX_IMAGE_BYTES = 10 * 1024 * 1024  # 10MB


@app.get("/health")
def health_check():
    return {"status": "OK", "message": "Server is running smoothly"}


async def validate_image(file: Optional[UploadFile]) -> None:
    # NOTE: Accepting File(None) lets us return 400 (contract) instead of 422.
    if file is None:
        raise HTTPException(status_code=400, detail="Missing file")

    if file.content_type not in ALLOWED_IMAGE_TYPES:
        raise HTTPException(status_code=400, detail="File must be an image")

    # Basic size guardrail (prevents accidental huge uploads).
    # Reads the file into memory for MVP; replace with streaming if needed later.
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

    # TODO: Replace with real AI call
    return JSONResponse(
        content={
            "type": "obstacle_detection",
            "result": "Obstacle detection not connected to AI yet."
        }
    )


@app.post("/crosswalk")
async def crosswalk(file: Optional[UploadFile] = File(None)):
    await validate_image(file)

    # TODO: Replace with real AI call
    return JSONResponse(
        content={
            "type": "crosswalk_analysis",
            "result": "Crosswalk detection not connected to AI yet."
        }
    )


@app.post("/custom")
async def custom(file: Optional[UploadFile] = File(None), prompt: Optional[str] = Form(None)):
    await validate_image(file)

    if prompt is None or not prompt.strip():
        raise HTTPException(status_code=400, detail="Missing prompt")

    clean_prompt = prompt.strip()

    # TODO: Replace with real AI call
    return JSONResponse(
        content={
            "type": "custom_query",
            "prompt": clean_prompt,
            "result": f'Custom query not connected to AI yet. You asked: "{clean_prompt}"'
        }
    )


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)
