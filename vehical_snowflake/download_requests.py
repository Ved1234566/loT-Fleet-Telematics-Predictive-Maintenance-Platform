import os
from pathlib import Path
import requests
import boto3
from botocore.exceptions import ClientError

# -------- SETTINGS --------
SAVE_FOLDER = "./downloaded_files"
GOOGLE_API_KEY = os.environ.get("GOOGLE_API_KEY")   
if not GOOGLE_API_KEY:
    raise SystemExit("GOOGLE_API_KEY not set. Run: export GOOGLE_API_KEY=your_key_here")

# file_id : name_to_save_as
FILES = {
    "FILE_ID_1": "file1.csv",
    "FILE_ID_2": "file2.csv",
}

Path(SAVE_FOLDER).mkdir(parents=True, exist_ok=True)


# -------- DOWNLOAD FILES FROM GOOGLE DRIVE --------
for file_id, file_name in FILES.items():
    file_path = os.path.join(SAVE_FOLDER, file_name)

    if os.path.exists(file_path):
        print(f"Already have {file_name}, skipping")
        continue

    url = f"https://www.googleapis.com/drive/v3/files/{file_id}?alt=media&key={GOOGLE_API_KEY}"
    print(f"Downloading {file_name}")

    response = requests.get(url)
    with open(file_path, "wb") as f:
        f.write(response.content)

    print(f"Saved {file_path}")


# --------  CHECK / CREATE S3 BUCKET --------
bucket_name = input("Enter your bucket name: ")
region = input("Enter your region (example: us-east-1): ")

s3 = boto3.client("s3", region_name=region)

bucket_found = True
try:
    s3.head_bucket(Bucket=bucket_name)
except ClientError:
    bucket_found = False

if bucket_found:
    print(f"Bucket '{bucket_name}' already exists")
else:
    print(f"Bucket '{bucket_name}' does not exist, creating it")
    if region == "us-east-1":
        s3.create_bucket(Bucket=bucket_name)
    else:
        s3.create_bucket(
            Bucket=bucket_name,
            CreateBucketConfiguration={"LocationConstraint": region}
        )


# --------  UPLOAD FILES TO S3 (into folders by file type) --------
files = os.listdir(SAVE_FOLDER)

for file_name in files:
    file_path = os.path.join(SAVE_FOLDER, file_name)

    if not os.path.isfile(file_path):
        continue

    # pick folder based on extension, e.g. "data.csv" -> "csv/data.csv"
    extension = file_name.split(".")[-1].lower()
    s3_key = f"{extension}/{file_name}"

    print(f"Uploading {file_name} -> {s3_key}")
    s3.upload_file(file_path, bucket_name, s3_key)
    print(f"Uploaded {s3_key}")

print("All done!")
