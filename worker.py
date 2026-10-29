import boto3
import json
import time
import os

# Replace with your actual Terraform outputs
SQS_QUEUE_URL = "YOUR_SQS_QUEUE_URL"
REGION = "ap-south-1"

sqs = boto3.client('sqs', region_name=REGION)

def poll_queue():
    print(f"Listening for tasks on {SQS_QUEUE_URL}...")
    while True:
        try:
            # Long polling: waits up to 10 seconds for a message
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
                    print(f"Payload: {json.dumps(body, indent=2)}")
                    
                    # TODO: Trigger Docker container execution here
                    
                    # Delete message after successful execution
                    sqs.delete_message(
                        QueueUrl=SQS_QUEUE_URL,
                        ReceiptHandle=receipt_handle
                    )
                    print("[-] Task completed and removed from queue.")
            else:
                # No messages, loop continues
                pass

        except Exception as e:
            print(f"Error polling queue: {e}")
            time.sleep(5)

if __name__ == "__main__":
    poll_queue()