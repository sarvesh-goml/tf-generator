data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  mode = var.create_vpc ? "new" : (var.existing_vpc_id == null ? "default" : "existing")
}

# Used when create_vpc = false: the given VPC, or the account's default VPC.
data "aws_vpc" "selected" {
  count   = var.create_vpc ? 0 : 1
  id      = var.existing_vpc_id
  default = local.mode == "default" ? true : null
}

# Default VPCs have one public subnet per AZ, flagged default-for-az.
data "aws_subnets" "default" {
  count = local.mode == "default" ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected[0].id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # Public subnets take the first az_count blocks, private subnets the next az_count.
  public_subnet_cidrs  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, var.subnet_newbits, i)]
  private_subnet_cidrs = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, var.subnet_newbits, i + var.az_count)]

  subnet_count      = var.create_vpc ? var.az_count : 0
  nat_enabled       = var.create_vpc && var.enable_nat_gateway
  nat_gateway_count = local.nat_enabled ? (var.single_nat_gateway ? 1 : var.az_count) : 0
}

# ---------------------------------------------------------------------------
# VPC + internet gateway
# ---------------------------------------------------------------------------
resource "aws_vpc" "this" {
  count = var.create_vpc ? 1 : 0

  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpc" })
}

# Lock down the default security group so nothing uses it by accident.
resource "aws_default_security_group" "this" {
  count  = var.create_vpc ? 1 : 0
  vpc_id = aws_vpc.this[0].id

  tags = merge(var.tags, { Name = "${var.name_prefix}-default-sg-locked" })
}

resource "aws_internet_gateway" "this" {
  count  = var.create_vpc ? 1 : 0
  vpc_id = aws_vpc.this[0].id

  tags = merge(var.tags, { Name = "${var.name_prefix}-igw" })
}

# ---------------------------------------------------------------------------
# Subnets
# ---------------------------------------------------------------------------
resource "aws_subnet" "public" {
  count = local.subnet_count

  vpc_id                  = aws_vpc.this[0].id
  cidr_block              = local.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-public-${local.azs[count.index]}"
    Tier = "public"
  })
}

resource "aws_subnet" "private" {
  count = local.subnet_count

  vpc_id            = aws_vpc.this[0].id
  cidr_block        = local.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-private-${local.azs[count.index]}"
    Tier = "private"
  })
}

# ---------------------------------------------------------------------------
# Public routing
# ---------------------------------------------------------------------------
resource "aws_route_table" "public" {
  count  = var.create_vpc ? 1 : 0
  vpc_id = aws_vpc.this[0].id

  tags = merge(var.tags, { Name = "${var.name_prefix}-public-rt" })
}

resource "aws_route" "public_internet" {
  count = var.create_vpc ? 1 : 0

  route_table_id         = aws_route_table.public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this[0].id
}

resource "aws_route_table_association" "public" {
  count = local.subnet_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

# ---------------------------------------------------------------------------
# NAT + private routing
# ---------------------------------------------------------------------------
resource "aws_eip" "nat" {
  count  = local.nat_gateway_count
  domain = "vpc"

  tags = merge(var.tags, { Name = "${var.name_prefix}-nat-eip-${count.index + 1}" })
}

resource "aws_nat_gateway" "this" {
  count = local.nat_gateway_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(var.tags, { Name = "${var.name_prefix}-nat-${count.index + 1}" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "private" {
  count  = local.subnet_count
  vpc_id = aws_vpc.this[0].id

  tags = merge(var.tags, { Name = "${var.name_prefix}-private-rt-${local.azs[count.index]}" })
}

resource "aws_route" "private_nat" {
  count = local.nat_enabled ? local.subnet_count : 0

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[var.single_nat_gateway ? 0 : count.index].id
}

resource "aws_route_table_association" "private" {
  count = local.subnet_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}
