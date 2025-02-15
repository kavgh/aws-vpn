locals {
  isg = { ssh = { port = 22, proto = "tcp" }, wg = { port = 51820, proto = "udp" } }
}

provider "aws" {
  shared_config_files      = ["~/.aws/config"]
  shared_credentials_files = ["~/.aws/credentials"]
  profile                  = "default"
}

data "aws_ami" "this" {
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-20240701.1"]
  }

  owners = ["099720109477"]
}

resource "aws_key_pair" "this" {
  key_name   = "aws_ec2.pub"
  public_key = file("~/.ssh/aws_ec2.pub")
}

resource "aws_security_group" "this" {
  name   = "vpn-sg"
  vpc_id = data.aws_vpc.this.id
}

resource "aws_vpc_security_group_egress_rule" "this" {
  security_group_id = aws_security_group.this.id
  description       = "Allow outbound traffic"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = -1
}

resource "aws_vpc_security_group_ingress_rule" "this" {
  for_each = local.isg

  security_group_id = aws_security_group.this.id
  description       = "Allow ${each.key} traffic"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = each.value.proto
  from_port   = each.value.port
  to_port     = each.value.port
}

data "aws_vpc" "this" {
  default = true
}

data "aws_subnets" "this" {
  filter {
    name = "vpc-id"
    values = [ data.aws_vpc.this.id ]
  }
}

module "ec2" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "~> 5.7.1"

  name                        = "wireguard"
  ami                         = data.aws_ami.this.id
  associate_public_ip_address = true
  instance_type               = "t2.micro"

  subnet_id              = data.aws_subnets.this.ids[0]
  tenancy                = "default"
  vpc_security_group_ids = [aws_security_group.this.id]
  key_name               = aws_key_pair.this.id

  user_data = templatefile("./resources/user_data.tftpl", { port = local.isg.wg.port })
}