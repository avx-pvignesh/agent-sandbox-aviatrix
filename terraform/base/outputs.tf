output "region" {
  value = var.region
}

output "egress_mode" {
  value = var.egress_mode
}

output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}

output "host_subnet_cidr" {
  value = aws_subnet.host.cidr_block
}

output "public_subnet_cidr" {
  value = aws_subnet.public.cidr_block
}

output "public_ha_subnet_cidr" {
  value = local.aviatrix ? aws_subnet.public_ha[0].cidr_block : null
}

output "host_instance_id" {
  value = aws_instance.host.id
}

output "host_private_ip" {
  value = aws_instance.host.private_ip
}

output "nat_public_ip" {
  value = local.aviatrix ? null : aws_eip.nat[0].public_ip
}

output "ssm_connect" {
  value = "aws ssm start-session --region ${var.region} --target ${aws_instance.host.id}"
}
