# scene_aware_assistant_app

Scene-aware assistant (Flutter + FastAPI).

## Prerequisites

- Flutter SDK installed and on PATH
- Android Studio installed (for Android SDK + emulator)
- Python 3.9+ installed (for backend)

## Backend (FastAPI)

From the project root:

1. Install backend dependencies:
	- `python -m pip install -r backend/requirements.txt`
	  - Includes `python-multipart` (required for `multipart/form-data` uploads)
2. Run the backend:
	- `python backend/server.py`

Health check:
- `GET http://127.0.0.1:8000/health`

## Mobile App (Flutter)

From the project root:

1. Install dependencies:
	- `flutter pub get`

2. Run on Android emulator:
	- Start an emulator in Android Studio (Device Manager)
	- Run:
	  - `flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000`

3. Run on a physical Android phone (same WiFi as your PC):
	- Find your PC's LAN IP (example: `192.168.1.50`)
	- Run:
	  - `flutter run --dart-define=API_BASE_URL=http://192.168.1.50:8000`

Note: iOS builds require a Mac + Xcode.

## Voice Commands (MVP)

While in the camera screen:

- "close camera" → exits camera
- "pause scanning" / "stop scanning" → pauses auto scanning
- "resume scanning" / "start scanning" → resumes auto scanning
- "crosswalk" → runs crosswalk analysis on the next capture

Custom questions:
- Ask a question starting with words like "what", "where", "how", "describe", "tell me" to trigger the `/custom` endpoint.
