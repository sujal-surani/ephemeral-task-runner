import boto3
import json
import time
import docker

# Replace with your terraform output
SQS_QUEUE_URL = "https://sqs.ap-south-1.amazonaws.com/187157282695/ephemeral-task-queue"
REGION = "ap-south-1"

sqs = boto3.client('sqs', region_name=REGION)
# Initialize the local Docker client
docker_client = docker.from_env()

def poll_queue():
    print(f"Listening for tasks on {SQS_QUEUE_URL}...")
    while True:
        try:
            response = sqs.receive_message(
                QueueUrl=SQS_QUEUE_URL,
                MaxNumberOfMessages=1,
                WaitTimeSeconds=10
            )

            if 'Messages' in response:
                for message in response['Messages']:
                    receipt_handle = message['ReceiptHandle']
                    body = json.loads(message['Body'])
                    
                    print(f"\n[+] Received task: {body.get('task_id', 'unknown')}")
                    
                    try:
                        print("[-] Spinning up isolated Docker container...")
                        # Run a secure, ephemeral container with hard resource limits
                        logs = docker_client.containers.run(
                            "python:3.9-alpine",
                            command='python -c "print(\'Success! Code executed inside the hermetic sandbox.\')"',
                            mem_limit="512m",        # Hard memory limit
                            nano_cpus=500000000,     # Limit to 0.5 CPU core
                            detach=False,            # Block until execution finishes
                            remove=True              # Automatically destroy container after running
                        )
                        
                        print("[+] Execution Output:")
                        print(logs.decode('utf-8').strip())
                        
                    except Exception as docker_err:
                        print(f"[!] Docker execution failed: {docker_err}")

                    # Delete message from SQS only after execution completes
                    sqs.delete_message(
                        QueueUrl=SQS_QUEUE_URL,
                        ReceiptHandle=receipt_handle
                    )
                    print("[-] Task completed, environment destroyed, and message removed.")

        except Exception as e:
            print(f"[!] Error polling queue: {e}")
            time.sleep(5)

if __name__ == "__main__":
    poll_queue()