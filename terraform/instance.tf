# 1. IAM Role & Permissions for the Worker
resource "aws_iam_role" "worker_role" {
  name = "ephemeral-worker-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "worker_policy" {
  name = "ephemeral-worker-policy"
  role = aws_iam_role.worker_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Effect = "Allow"
        Resource = aws_sqs_queue.task_queue.arn
      },
      {
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Effect = "Allow"
        Resource = [
          aws_s3_bucket.task_workspace.arn,
          "${aws_s3_bucket.task_workspace.arn}/*"
        ]
      }
    ]
  })
}

# Attach SSM policy so you can terminal into the box securely without SSH
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.worker_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "worker_profile" {
  name = "ephemeral-worker-profile"
  role = aws_iam_role.worker_role.name
}

# 2. Security Group (Egress only, no inbound attack surface)
resource "aws_security_group" "worker_sg" {
  name        = "ephemeral-worker-sg"
  description = "Allow outbound traffic for SQS polling and Docker pulls"

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 3. Amazon Linux 2023 AMI Lookup
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

# 4. Free Tier EC2 Instance
resource "aws_instance" "worker_node" {
  ami                  = data.aws_ami.amazon_linux_2023.id
  instance_type        = "t2.micro"
  iam_instance_profile = aws_iam_instance_profile.worker_profile.name
  vpc_security_group_ids = [aws_security_group.worker_sg.id]

  # Cloud-init script to automatically build the environment on launch
  user_data = <<-EOF
    #!/bin/bash
    # Install dependencies
    dnf update -y
    dnf install -y docker python3 python3-pip

    # Start Docker
    systemctl enable --now docker
    usermod -aG docker ec2-user

    # Install Python SDKs
    pip3 install boto3 docker

    # Setup Workspace
    mkdir -p /opt/worker/workspace
    cd /opt/worker

    # Write worker.py (Terraform dynamically injects the SQS URL and S3 Bucket)
    cat << 'PYEOF' > worker.py
    import boto3, json, time, docker, os

    SQS_QUEUE_URL = "${aws_sqs_queue.task_queue.id}"
    S3_BUCKET = "${aws_s3_bucket.task_workspace.bucket}"
    REGION = "ap-south-1"

    sqs = boto3.client('sqs', region_name=REGION)
    s3 = boto3.client('s3', region_name=REGION)
    docker_client = docker.from_env()

    WORKSPACE_DIR = os.path.abspath("workspace")

    def poll_queue():
        print(f"Listening for tasks on {SQS_QUEUE_URL}...", flush=True)
        while True:
            try:
                response = sqs.receive_message(QueueUrl=SQS_QUEUE_URL, MaxNumberOfMessages=1, WaitTimeSeconds=10)
                if 'Messages' in response:
                    for message in response['Messages']:
                        receipt_handle = message['ReceiptHandle']
                        body = json.loads(message['Body'])
                        
                        task_id = body.get('task_id', 'unknown')
                        script_key = body.get('script_key')
                        
                        if not script_key:
                            sqs.delete_message(QueueUrl=SQS_QUEUE_URL, ReceiptHandle=receipt_handle)
                            continue

                        local_script_path = os.path.join(WORKSPACE_DIR, script_key)
                        s3.download_file(S3_BUCKET, script_key, local_script_path)

                        try:
                            logs = docker_client.containers.run(
                                "python:3.9-alpine",
                                command=f"python /workspace/{script_key}",
                                volumes={WORKSPACE_DIR: {'bind': '/workspace', 'mode': 'rw'}},
                                working_dir="/workspace",
                                mem_limit="512m",
                                nano_cpus=500000000,
                                detach=False,
                                remove=True
                            )
                            print(logs.decode('utf-8').strip(), flush=True)
                            
                            result_file = os.path.join(WORKSPACE_DIR, "output.txt")
                            if os.path.exists(result_file):
                                result_key = f"results/{task_id}_output.txt"
                                s3.upload_file(result_file, S3_BUCKET, result_key)
                                os.remove(result_file)
                                
                        except Exception as docker_err:
                            print(f"[!] Docker execution failed: {docker_err}", flush=True)

                        if os.path.exists(local_script_path):
                            os.remove(local_script_path)

                        sqs.delete_message(QueueUrl=SQS_QUEUE_URL, ReceiptHandle=receipt_handle)
            except Exception as e:
                print(f"[!] Error: {e}", flush=True)
                time.sleep(5)

    if __name__ == "__main__":
        poll_queue()
    PYEOF

    # Create systemd service for 24/7 operation
    cat << 'SYSEOF' > /etc/systemd/system/worker.service
    [Unit]
    Description=Ephemeral Task Worker
    After=network.target docker.service
    Requires=docker.service

    [Service]
    Type=simple
    User=root
    WorkingDirectory=/opt/worker
    ExecStart=/usr/bin/python3 /opt/worker/worker.py
    Restart=always
    RestartSec=5
    StandardOutput=journal
    StandardError=journal

    [Install]
    WantedBy=multi-user.target
    SYSEOF

    # Start the daemon
    systemctl daemon-reload
    systemctl enable --now worker.service
  EOF
}