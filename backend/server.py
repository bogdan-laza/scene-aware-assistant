from fastapi import FastAPI

app = FastAPI(title="Scene Assistant Backend")

@app.get("/health")
def health_check():
    return {"status": "OK", "message": "Server is running smoothly"}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)