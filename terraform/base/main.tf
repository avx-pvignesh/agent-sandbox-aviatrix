data "aws_availability_zones" "az" {
  state = "available"
}

locals {
  az       = data.aws_availability_zones.az.names[0]
  az2      = data.aws_availability_zones.az.names[1]
  aviatrix = var.egress_mode == "aviatrix"
  tags     = merge({ Project = var.name_prefix }, var.tags)
}

# ------------------------------------------------------------------ VPC
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.tags, { Name = "${var.name_prefix}-vpc" })
}

# The IGW serves the public subnet(s) only: the spoke gateway's EIP, or the NAT gateway.
# The host subnet never gets a route to it.
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name_prefix}-igw" })
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.public_subnet_cidr
  availability_zone = local.az
  tags              = merge(local.tags, { Name = "${var.name_prefix}-public" })
}

resource "aws_subnet" "public_ha" {
  count             = local.aviatrix ? 1 : 0
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.public_ha_subnet_cidr
  availability_zone = local.az2
  tags              = merge(local.tags, { Name = "${var.name_prefix}-public-ha" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = merge(local.tags, { Name = "${var.name_prefix}-public-rt" })
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_ha" {
  count          = local.aviatrix ? 1 : 0
  subnet_id      = aws_subnet.public_ha[0].id
  route_table_id = aws_route_table.public.id
}

# ------------------------------------------------------------------ Host subnet (private)
resource "aws_subnet" "host" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.host_subnet_cidr
  availability_zone = local.az
  tags              = merge(local.tags, { Name = "${var.name_prefix}-host" })
}

# aviatrix mode: no default route here. The Aviatrix controller programs 0.0.0.0/0 to the
# spoke gateway once the gateway is created with SNAT, so Terraform must not fight it.
# nat mode: the default route is added in egress_nat.tf.
resource "aws_route_table" "host" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name_prefix}-host-rt" })
  lifecycle {
    ignore_changes = [route]
  }
}

resource "aws_route_table_association" "host" {
  subnet_id      = aws_subnet.host.id
  route_table_id = aws_route_table.host.id
}

# ------------------------------------------------------------------ SSM access
# Interface endpoints keep Session Manager traffic inside the VPC, so management
# does not depend on (and is not cut off by) the egress policy.
resource "aws_security_group" "endpoints" {
  name   = "${var.name_prefix}-endpoints"
  vpc_id = aws_vpc.this.id
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = local.tags
}

resource "aws_vpc_endpoint" "ssm" {
  for_each            = toset(["ssm", "ssmmessages", "ec2messages"])
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.host.id]
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
  tags                = merge(local.tags, { Name = "${var.name_prefix}-${each.key}" })
}

# ------------------------------------------------------------------ Host IAM: SSM only
resource "aws_iam_role" "host" {
  name = "${var.name_prefix}-host"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.host.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "host" {
  name = "${var.name_prefix}-host"
  role = aws_iam_role.host.name
}

# ------------------------------------------------------------------ Host SG: no inbound
resource "aws_security_group" "host" {
  name   = "${var.name_prefix}-host"
  vpc_id = aws_vpc.this.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = local.tags
}

# ------------------------------------------------------------------ Host instance
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = [var.ami_name_filter]
  }
}

resource "aws_instance" "host" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.host.id
  vpc_security_group_ids      = [aws_security_group.host.id]
  iam_instance_profile        = aws_iam_instance_profile.host.name
  associate_public_ip_address = false

  # IMDSv2 only, hop limit 1: nothing behind the host's bridge can reach the metadata service.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size = var.root_volume_gb
    volume_type = "gp3"
    encrypted   = true
  }

  # Dedicated volume for the containerd devmapper thin pool (see host/bootstrap.sh).
  ebs_block_device {
    device_name = "/dev/sdf"
    volume_size = var.thinpool_volume_gb
    volume_type = "gp3"
    encrypted   = true
  }

  tags = merge(local.tags, { Name = "${var.name_prefix}-host", Role = "agent-host" })
}
