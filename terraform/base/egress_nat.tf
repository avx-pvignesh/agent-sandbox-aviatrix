# nat mode only. Gives the host a plain internet path through a NAT gateway.
# There is no network-layer egress filtering in this mode: the only egress control is
# the in-host egress proxy and credential proxy. Use it as the single-lock baseline.

resource "aws_eip" "nat" {
  count  = local.aviatrix ? 0 : 1
  domain = "vpc"
  tags   = merge(local.tags, { Name = "${var.name_prefix}-nat-eip" })
}

resource "aws_nat_gateway" "this" {
  count         = local.aviatrix ? 0 : 1
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public.id
  tags          = merge(local.tags, { Name = "${var.name_prefix}-nat" })
  depends_on    = [aws_internet_gateway.this]
}

resource "aws_route" "host_default_via_nat" {
  count                  = local.aviatrix ? 0 : 1
  route_table_id         = aws_route_table.host.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[0].id
}
