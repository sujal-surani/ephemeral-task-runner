import boto3
import json
import time
import docker
import os

# Replace with your terraform outputs
SQS_QUEUE_URL = "https://sqs.ap-south-1.amazonaws.com/187157282695/ephemeral-task-queue"
S3_BUCKET = "ephemeral-workspace-bd782855"
REGION = "ap-south-1"

sqs = boto3.client('sqs', region_name=REGION)
s3 = boto3.client('s3', region_name=REGION)
docker_client = docker.from_env()

# Create a local staging directory for the file mounting
WORKSPACE_DIR = os.path.abspath("workspace")
os.makedirs(WORKSPACE_DIR, exist_ok=True)

def poll_queue():
    print(f"Listening for tasks on {SQS_QUEUE_URL}...")
    while True:
        try:
            response = sqs.receive_message(
                QueueUrl=SQS_QUEUE_URL, MaxNumberOfMessages=1, WaitTimeSeconds=10
            )

            if 'Messages' in response:
                for message in response['Messages']:
                    receipt_handle = message['ReceiptHandle']
                    body = json.loads(message['Body'])
                    
                    task_id = body.get('task_id', 'unknown')
                    script_key = body.get('script_key')
                    
                    print(f"\n[+] Received task: {task_id}")
                    
                    if not script_key:
                        print("[!] No script_key provided. Skipping task.")
                        sqs.delete_message(QueueUrl=SQS_QUEUE_URL, ReceiptHandle=receipt_handle)
                        continue

                    # 1. Download script from S3 to local workspace
                    local_script_path = os.path.join(WORKSPACE_DIR, script_key)
                    print(f"[-] Downloading {script_key} from S3...")
                    s3.download_file(S3_BUCKET, script_key, local_script_path)

                    # 2. Execute in Docker with a mounted volume
                    print("[-] Spinning up hermetic sandbox...")
                    try:
                        logs = docker_client.containers.run(
                            "python:3.9-alpine",
                            command=f"python /workspace/{script_key}",
                            # Mount the local workspace dir into the container
                            volumes={WORKSPACE_DIR: {'bind': '/workspace', 'mode': 'rw'}},
                            working_dir="/workspace",
                            mem_limit="512m",
                            nano_cpus=500000000,
                            detach=False,
                            remove=True
                        )
                        print("[+] Execution Output:")
                        print(logs.decode('utf-8').strip())
                        
                        # 3. Check for generated files and push back to S3
                        result_file = os.path.join(WORKSPACE_DIR, "output.txt")
                        if os.path.exists(result_file):
                            result_key = f"results/{task_id}_output.txt"
                            print(f"[-] Uploading results to S3 as {result_key}...")
                            s3.upload_file(result_file, S3_BUCKET, result_key)
                            os.remove(result_file) # Clean up local result file
                            
                    except Exception as docker_err:
                        print(f"[!] Docker execution failed: {docker_err}")

                    # 4. Final Cleanup
                    if os.path.exists(local_script_path):
                        os.remove(local_script_path)

                    sqs.delete_message(QueueUrl=SQS_QUEUE_URL, ReceiptHandle=receipt_handle)
                    print("[-] Task complete, environment sanitized.")

        except Exception as e:
            print(f"[!] Error polling queue: {e}")
            time.sleep(5)

if __name__ == "__main__":
    poll_queue()