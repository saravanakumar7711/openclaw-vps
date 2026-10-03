# Canonical's official Ubuntu 24.04 LTS image for the chosen region/arch.
data "aws_ami" "ubuntu_2404" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name = "name"
    # Matches both of Canonical's naming schemes (hvm-ssd and hvm-ssd-gp3);
    # most_recent picks the newest build either way.
    values = ["ubuntu/images/hvm-ssd*/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_vpc" "default" {
  default = true
}

resource "aws_security_group" "openclaw" {
  name_prefix = "${var.name}-"
  description = "OpenClaw VPS: SSH from one address only, nothing else inbound."
  vpc_id      = data.aws_vpc.default.id

  tags = { Name = "${var.name}-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

# The Gateway (18789) and browser control service (18791) are deliberately
# absent: they bind to loopback and are reached over the tailnet, so no
# ingress rule should ever exist for them.
resource "aws_vpc_security_group_ingress_rule" "ssh" {
  count = var.allow_ssh ? 1 : 0

  security_group_id = aws_security_group.openclaw.id
  description       = "SSH from the operator's address only"
  cidr_ipv4         = var.my_ip
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

# Tailscale is UDP-outbound and NAT-traverses, so no inbound rule is needed.
resource "aws_vpc_security_group_egress_rule" "all_ipv4" {
  security_group_id = aws_security_group.openclaw.id
  description       = "Outbound: apt, npm, Tailscale, Gemini API, Telegram API, the web"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_instance" "openclaw" {
  ami                    = data.aws_ami.ubuntu_2404.id
  instance_type          = var.instance_type
  key_name               = var.key_pair_name
  vpc_security_group_ids = [aws_security_group.openclaw.id]

  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    repo_url           = var.repo_url
    repo_ref           = var.repo_ref
    gemini_api_key     = var.gemini_api_key
    telegram_bot_token = var.telegram_bot_token
    telegram_user_id   = var.telegram_user_id
    tailscale_authkey  = var.tailscale_authkey
    openclaw_model     = var.openclaw_model
    tailscale_hostname = var.name
  })

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
    encrypted   = true
  }

  # IMDSv2 only: a token-less metadata read is a classic SSRF escalation path,
  # and this box runs a browser that fetches arbitrary URLs.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tags = { Name = var.name }
}
