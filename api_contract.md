# Mobile <-> Backend Integration Guide

This document defines the communication contract between the Flutter Mobile App (Client) and the FastAPI Python Backend (Server).

## Base Configuration

### Base URLs

    Android Emulator: http://10.0.2.2:8000 (which is the alias for the host's computer)

    Physical Android Device: http://<YOUR_PC_LOCAL_IP>:8000

**Requirement:** Phone and PC must be on the same WiFi network.

## Endpoints

**1. Obstacle Detection**

Analyzes the image for general navigation hazards.

URL: /obstacles

Method: POST

Content-Type: multipart/form-data

Request Body:

file: The image file (binary). Supported: JPG, PNG.

Response (JSON):

{
  "type": "obstacle_detection",
  "result": "There is a potted plant directly in front of you and a chair to the left.",
  "confidence": 0.65
}


**2. Crosswalk Detection**

Uses the specialized (fine-tuned) model to identify safe crossing zones.

URL: /crosswalk

Method: POST

Content-Type: multipart/form-data

Request Body:

file: The image file (binary).

Response (JSON):

{
  "type": "crosswalk_analysis",
  "result": "Yes, there is a pedestrian crosswalk visible. It looks safe to cross.",
  "confidence": 0.65
}


**3. Custom Query**

Allows the user to ask a specific question via voice-to-text.

URL: /custom

Method: POST

Content-Type: multipart/form-data

Request Body:

file: The image file (binary).

prompt: (String) The user's specific question (e.g., "What color is the car?").

Response (JSON):

{
  "type": "custom_query",
  "prompt": "What color is the car?",
  "result": "The car is red.",
  "confidence": 0.65
}


## Error Handling

If the backend fails or the request is invalid, the API will return standard HTTP error codes.

400 Bad Request: Missing file or invalid image format.

{ "detail": "File must be an image" }


500 Internal Server Error: The AI model failed to process the request.
