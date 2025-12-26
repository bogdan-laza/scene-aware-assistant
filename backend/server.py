from fastapi import FastAPI, UploadFile, File, Form, HTTPException
from fastapi.responses import JSONResponse
import uvicorn

app = FastAPI(title="Scene Assistant Backend")

ALLOWED_IMAGE_TYPES = {"image/jpeg", "image/png", "image/jpg"}


@app.get("/health")
def health_check():
    return {"status": "OK", "message": "Server is running smoothly"}


def validate_image(file: UploadFile):
    if file is None:
        raise HTTPException(status_code=400, detail="Missing file")
    if file.content_type not in ALLOWED_IMAGE_TYPES:
        raise HTTPException(status_code=400, detail="File must be an image")


@app.post("/obstacles")
async def obstacles(file: UploadFile = File(...)):
    validate_image(file)

    # TODO: Replace with real AI call
    return JSONResponse(
        content={
            "type": "obstacle_detection",
            "result": "Obstacle detection not connected to AI yet."
        }
    )


@app.post("/crosswalk")
async def crosswalk(file: UploadFile = File(...)):
    validate_image(file)

    # TODO: Replace with real AI call
    return JSONResponse(
        content={
            "type": "crosswalk_analysis",
            "result": "Crosswalk detection not connected to AI yet."
        }
    )


@app.post("/custom")
async def custom(file: UploadFile = File(...), prompt: str = Form(...)):
    validate_image(file)

    if not prompt or not prompt.strip():
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
