#VARIABLES
variable "region_name" {
  description = "AWS Region where the cluster is deployed"
  type = string
  default = "eu-west-1"
}

variable "domain_name" {
  description = "Public DNS domain name" 
  type = string
  default = "tale"
}

variable "cluster_name" {
  description = "Cluster name, used to define Clusterid tag and as part of other component names"
  type = string
  default = "ocp"
}

variable "vpc_name" {
  description = "Name assigned to the VPC"
  type = string
  default = "volatil"
}

variable "subnet_count" {
  description = "Number of private and public subnets to a maximum of 3, there will be the same number of private and public subnets"
  type = number
  default = 1
}

variable "ssh-keyfile" {
  description = "Name of the file with public part of the SSH key to transfer to the EC2 instances"
  type = string
  default = "ocp-ssh.pub"
}

variable "dns_domain_ID" {
  description = "Zone ID for the route 53 DNS domain that will be used for this cluster"
  type = string
  default = "Z1UPG9G4YY4YK6"
}

variable "rhel7-ami" {
  description = "AMI on which the EC2 instances are based on, depends on the region"
  type = map
  default = {
    eu-central-1   = "ami-0b5edb134b768706c"
    eu-west-1      = "ami-0404b890c57861c2d"
    eu-west-2      = "ami-0fb2dd0b481d4dc1a"
    eu-west-3      = "ami-0dc7b4dac85c15019"
    eu-north-1     = "ami-030b10a31b2b6df19"
    us-east-1      = "ami-0e9678b77e3f7cc96"
    us-east-2      = "ami-0170fc126935d44c3"
    us-west-1      = "ami-0d821453063a3c9b1"
    us-west-2      = "ami-0c2dfd42fa1fbb52c"
    sa-east-1      = "ami-09de00221562b0155"
    ap-south-1     = "ami-0ec8900bf6d32e0a8"
    ap-northeast-1 = "ami-0b355f24363d9f357"
    ap-northeast-2 = "ami-0bd7fd9221135c533"
    ap-southeast-1 = "ami-097e78d10c4722996"
    ap-southeast-2 = "ami-0f7bc77e719f87581"
    ca-central-1   = "ami-056db5ae05fa26d11"
  }
}

variable "vpc_cidr" {
  description = "Network segment for the VPC"
  type = string
  default = "172.20.0.0/16"
}

variable "enable_proxy" {
  description = "If set to true, disables nat gateways and adds sg-squid security group to bastion in preparation for the use of a proxy"
  type  = bool
  default = false
}

#LOCALS
locals {
#If enable_proxy is true, the security group sg-squid is added to the list, and later applied to bastion
bastion_security_groups = var.enable_proxy ? concat([aws_security_group.sg-ssh-in.id, aws_security_group.sg-all-out.id], aws_security_group.sg-squid[*].id) : [aws_security_group.sg-ssh-in.id, aws_security_group.sg-all-out.id]

#The number of private subnets must be between 1 and 3, default is 1
private_subnet_count = var.subnet_count > 0 && var.subnet_count <= 3 ? var.subnet_count : 1

#If the proxy is enable, only 1 public subnet is created for the bastion, otherwise the same number as for the private subnets
public_subnet_count = var.enable_proxy ? 1 : local.private_subnet_count
}
