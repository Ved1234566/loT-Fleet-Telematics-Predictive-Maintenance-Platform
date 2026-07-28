import os
from pathlib import Path
import requests
import zipfile
import boto3
from botocore.exceptions import ClientError

# -------- SETTINGS --------
BTS_WEBSITE = "https://transtats.bts.gov/PREZIP/"   # link where the data files are
SAVE_FOLDER = "./downloaded_files"                  # local folder to save files
YEARS = [2010]                                      # years to download
MONTHS = [1,2,3,4]                                  # months to download

Path(SAVE_FOLDER).mkdir(parents=True, exist_ok=True)  # make folder if it doesn't exist , parents=True allows creation of parent directories if they don't exist, exist_ok=True prevents error if folder already exists


# -------- STEP 1: DOWNLOAD FILES --------
for year in YEARS:
    for month in MONTHS:

        zip_name = f"On_Time_Reporting_Carrier_On_Time_Performance_1987_present_{year}_{month}.zip"
        csv_name = zip_name.replace(".zip", ".csv")

        zip_path = os.path.join(SAVE_FOLDER, zip_name)
        csv_path = os.path.join(SAVE_FOLDER, csv_name)

        # skip if already downloaded
        if os.path.exists(csv_path):
            print(f"Already have {year}-{month}, skipping")
            continue

        link = BTS_WEBSITE + zip_name   # full download link
        print(f"Downloading {link}")

        # download the zip file
        response = requests.get(link)
        with open(zip_path, "wb") as f:
            f.write(response.content)

        # unzip it
        with zipfile.ZipFile(zip_path, "r") as z: # open the zip file
            names = z.namelist() # get the list of files in the zip
            csv_inside = names[0]     # first file in the zip
            z.extract(csv_inside, SAVE_FOLDER) # extract the csv to the save folder 

        # rename extracted csv to clean name
        os.rename(os.path.join(SAVE_FOLDER, csv_inside), csv_path)

        # delete the zip, we don't need it anymore
        os.remove(zip_path)

        print(f"Saved {csv_path}")


# -------- STEP 2: CHECK / CREATE S3 BUCKET --------
bucket_name = input("Enter your bucket name: ")
region = input("Enter your region (example: us-east-1): ")

s3 = boto3.client("s3", region_name=region)

bucket_found = True
try:
    s3.head_bucket(Bucket=bucket_name)   # check if bucket exists
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


# -------- STEP 3: UPLOAD FILES TO S3 --------
files = os.listdir(SAVE_FOLDER)

for file_name in files:
    file_path = os.path.join(SAVE_FOLDER, file_name)

    if not os.path.isfile(file_path):
        continue

    print(f"Uploading {file_name}")
    s3.upload_file(file_path, bucket_name, file_name)
    print(f"Uploaded {file_name}")

print("All done!")