provider "aws" {
  region = "ap-south-1"  # Change to your desired region
}

# Create an S3 bucket for kOps state store
resource "aws_s3_bucket" "kops_state_store" {
  bucket = "eshwar20-kops-state-store"  # Change to a unique bucket name
}

resource "aws_s3_bucket_ownership_controls" "example" {
  bucket = aws_s3_bucket.kops_state_store.id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_acl" "example" {
  depends_on = [aws_s3_bucket_ownership_controls.example]

  bucket = aws_s3_bucket.kops_state_store.id
  acl    = "private"
}

# Create a security group for the Kubernetes cluster
resource "aws_security_group" "k8s_sg" {
  name        = "k8s_security_group"
  description = "Allow inbound traffic for Kubernetes"

  vpc_id = data.aws_vpc.default.id

  ingress {
    from_port   = 22           # Allow SSH
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  # Change to your IP for better security
  }

  ingress {
    from_port   = 80           # Allow HTTP
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443          # Allow HTTPS
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 10250         # Allow Kubelet API
    to_port     = 10250
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"  # All traffic
    cidr_blocks = ["0.0.0.0/0"]
  }
}

data "aws_vpc" "default" {
  default = true
}

# Create an IAM role with Administrator Access
resource "aws_iam_role" "admin_role" {
  name = "admin-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "admin_policy_attachment" {
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
  role       = aws_iam_role.admin_role.name
}

# Create an EC2 instance and attach the IAM role
resource "aws_instance" "k8s_instance" {
  ami           = "ami-0a4408457f9a03be3"  # Change to a valid AMI ID for your region
  instance_type = "t2.medium"               # Change to your desired instance type
  key_name      = "eshwar"                   # Change to your key pair name

  vpc_security_group_ids = [aws_security_group.k8s_sg.id]

  # Attach the IAM role to the instance
  iam_instance_profile = aws_iam_role.admin_role.name

  tags = {
    Name = "K8s-Instance"
  }
}

resource "null_resource" "kops_cluster" {
  provisioner "remote-exec" {
    inline = [
      # Update the package manager
      "sudo yum update -y",

      # Install necessary packages
      "sudo yum install -y golang curl jq",  # Install Go, curl, and jq

      # Download and install kOps
      "curl -LO https://github.com/kubernetes/kops/releases/latest/download/kops-linux-amd64",
      "chmod +x kops-linux-amd64",
      "sudo mv kops-linux-amd64 /usr/local/bin/kops",

      # Download and install kubectl
      "curl -LO https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl",
      "chmod +x kubectl",
      "sudo mv kubectl /usr/local/bin/",

      # Set the KOPS_STATE_STORE environment variable
      "export KOPS_STATE_STORE=s3://${aws_s3_bucket.kops_state_store.bucket}",

      # Create the Kubernetes cluster
      "kops create cluster --name example.k8s.local --state=s3://${aws_s3_bucket.kops_state_store.bucket} --zones ap-south-1a --node-count 3 --node-size t3.small --control-plane-size t3.medium --dns-zone example.k8s.local",

      # Update the cluster
      "kops update cluster --name example.k8s.local --yes",

      # Validate the cluster
      "kops validate cluster --name example.k8s.local"
    ]

    connection {
      type        = "ssh"
      user        = "ec2-user"  # Change this based on your AMI
      private_key = file("/root/.ssh/eshwar.pem")  # Path to your private key
      host        = aws_instance.k8s_instance.public_ip  # Use the public IP of the instance
    }
  }

  depends_on = [
    aws_s3_bucket.kops_state_store,
    aws_s3_bucket_ownership_controls.example,
    aws_s3_bucket_acl.example,
    aws_security_group.k8s_sg,
    aws_instance.k8s_instance,
    aws_iam_role.admin_role  # Ensure the IAM role is created before the instance
  ]
}