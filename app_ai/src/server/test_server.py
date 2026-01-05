import requests

#URL = "http://localhost:8000/custom"
#URL = "http://localhost:8000/obstacles"
URL = "http://localhost:8000/crosswalk" 

IMAGE_PATH = "poza1.png"

with open(IMAGE_PATH, "rb") as img:
    files = {"file": (IMAGE_PATH, img, "image/jpeg")}    
    data = {"prompt": "Is there a car near me?"}

    response = requests.post(URL, files=files, data=data)

print(response.json())