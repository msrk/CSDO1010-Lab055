/**** **** **** **** **** **** **** **** **** **** **** ****
Pins the AWS provider to ~> 5.x for stable plans. Keeps
upgrades within the major version to avoid breaking APIs.
**** **** **** **** **** **** **** **** **** **** **** ****/
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  backend "s3" {}
}

/**** **** **** **** **** **** **** **** **** **** **** ****
Sets the active region for all resources in this config.
Keeps deployments consistent across runs of the lab.
**** **** **** **** **** **** **** **** **** **** **** ****/
variable "region" {
  default = "us-east-1"
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project = "lab055"
    }
  }
}

/**** **** **** **** **** **** **** **** **** **** **** ****
Creates the network boundary. All subnets and routing live
inside this VPC. Tags aid search and cost attribution.
**** **** **** **** **** **** **** **** **** **** **** ****/
resource "aws_vpc" "lab_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Project = "lab055"
    Name    = "lab055-vpc"
  }
}

/**** **** **** **** **** **** **** **** **** **** **** ****
Discovers AZ names for this region. Used to spread subnets
for resilience and to meet service requirements later.
**** **** **** **** **** **** **** **** **** **** **** ****/
data "aws_availability_zones" "available" {
  state = "available"
}

/**** **** **** **** **** **** **** **** **** **** **** ****
Builds subnet across one AZ. Auto-assign public IPs to ease 
internet access for lab instances and testing.
**** **** **** **** **** **** **** **** **** **** **** ****/
resource "aws_subnet" "lab_subnet" {
  vpc_id     = aws_vpc.lab_vpc.id
  cidr_block = "10.0.1.0/24"
  availability_zone = "us-east-1a"
  //map_public_ip_on_launch = true

  tags = {
    Project = "lab055"
    Name    = "lab055-subnet"
  }
}

/**** **** **** **** **** **** **** **** **** **** **** ****
Attaches an Internet Gateway to the VPC. Enables traffic to
and from the public internet for routed resources.
**** **** **** **** **** **** **** **** **** **** **** ****/
resource "aws_internet_gateway" "lab_igw" {
  vpc_id = aws_vpc.lab_vpc.id

  tags = {
    Project = "lab055"
    Name    = "lab055-igw"
  }
}

/**** **** **** **** **** **** **** **** **** **** **** ****
Creates a route table with a 0.0.0.0/0 default route via the
IGW. Public subnets will inherit internet egress.
**** **** **** **** **** **** **** **** **** **** **** ****/
resource "aws_route_table" "lab_rt" {
  vpc_id = aws_vpc.lab_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab_igw.id
  }

  tags = {
    Project = "lab055"
    Name    = "lab055-rt"
  }
}

/**** **** **** **** **** **** **** **** **** **** **** ****
Associates each public subnet to the internet route table.
Makes those subnets internet-routable for lab access.
**** **** **** **** **** **** **** **** **** **** **** ****/
resource "aws_route_table_association" "lab_assoc" {
  subnet_id      = aws_subnet.lab_subnet.id
  route_table_id = aws_route_table.lab_rt.id
}

/**** **** **** **** **** **** **** **** **** **** **** ****
Creates a security group container. Inbound and outbound
rules are defined separately for clarity and reuse.
**** **** **** **** **** **** **** **** **** **** **** ****/
resource "aws_security_group" "lab_sg" {
  vpc_id = aws_vpc.lab_vpc.id
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Project = "lab055"
    Name    = "lab055-sg"
  }
}

/**** **** **** **** **** **** **** **** **** **** **** ****
  Create a new instance of the latest Ubuntu on an EC2 instance,
  t2.micro node. We can find more options using the AWS command line:
 
  aws ec2 describe-images --owners 099720109477 \
    --filters "Name=name,Values=*hvm-ssd*focal*20.04-amd64*" \
    --query 'sort_by(Images, &CreationDate)[].Name'
 *** **** **** **** **** **** **** **** **** **** **** ****/
data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical
}

/**** **** **** **** **** **** **** **** **** **** **** ****
Creates a t2.micro Ubuntu instance for app or DB tasks.
Ties in SGs, key pair, user-data, and IAM profile.
**** **** **** **** **** **** **** **** **** **** **** ****/
resource "aws_instance" "ansible" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.lab_subnet.id
  vpc_security_group_ids = [aws_security_group.lab_sg.id]
  user_data              = file("${path.module}/templates/ansible.bash")

  tags = {
    Project = "lab055"
    Name    = "Lab055-EC2"
  }

  associate_public_ip_address = true

  lifecycle {
    create_before_destroy = true
  }
}

/**** **** **** **** **** **** **** **** **** **** **** ****
Expose our working URL
**** **** **** **** **** **** **** **** **** **** **** ****/

output "http_access" {
  value = "http://${aws_instance.ansible.public_ip}"
}