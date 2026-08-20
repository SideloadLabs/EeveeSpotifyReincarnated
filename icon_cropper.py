import requests
from PIL import Image
from io import BytesIO

# The image URL you provided
image_url = ""

# Download the image
print("Downloading image...")
response = requests.get(image_url)
img = Image.open(BytesIO(response.content)).convert("RGBA")

# Crop the image to only show the icon (removes transparent/empty borders)
# getbbox() automatically finds the non-transparent bounding box
bbox = img.getbbox()
if bbox:
    # Adding a slight padding so it's not too tight, optional but recommended for icons
    padding = 10
    bbox = (max(0, bbox[0]-padding), max(0, bbox[1]-padding), bbox[2]+padding, bbox[3]+padding)
    cropped_img = img.crop(bbox)
else:
    cropped_img = img

# Force the image into a perfect 1:1 square (required for iOS app icons)
width, height = cropped_img.size
side = min(width, height)
left = (width - side) / 2
top = (height - side) / 2
right = (width + side) / 2
bottom = (height + side) / 2
cropped_img = cropped_img.crop((left, top, right, bottom))

# Define the iOS file versions and their standard pixel sizes
# Note: You can change the sizes if these are for in-app icons rather than Home Screen icons
versions = {
    "@2x.png": (120, 120),
    "@3x.png": (180, 180),
    "~ipad.png": (76, 76),
    "@2x~ipad.png": (152, 152)
}

# Generate, resize, and save each version
base_name = "Spotify_App_Logo"
for suffix, size in versions.items():
    resized = cropped_img.resize(size, Image.Resampling.LANCZOS)
    filename = f"{base_name}{suffix}"
    resized.save(filename, "PNG")
    print(f"Saved: {filename} ({size[0]}x{size[1]})")

print("All versions cropped and generated successfully!")
