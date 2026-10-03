variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "key_pair_name" {
  description = "Name of an existing EC2 key pair. Its private key is how you SSH in before the openclaw user is hardened."
  type        = string
}

variable "my_ip" {
  description = "Your public IP in CIDR form, e.g. \"203.0.113.9/32\". The only source allowed to reach SSH."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.my_ip))
    error_message = "my_ip must be a CIDR block such as 203.0.113.9/32."
  }
}

variable "instance_type" {
  description = "EC2 instance type. t3.medium (2 vCPU / 4 GB) is the smallest size that runs a headless Chrome comfortably."
  type        = string
  default     = "t3.medium"
}

variable "name" {
  description = "Name tag / hostname prefix for the instance and its security group."
  type        = string
  default     = "openclaw"
}

variable "root_volume_size" {
  description = "Root EBS volume size in GB. Chrome, Node and the agent workspace need room."
  type        = number
  default     = 30
}

variable "repo_url" {
  description = "Git URL of this repository. user_data clones it on the instance and runs setup.sh from it."
  type        = string
}

variable "repo_ref" {
  description = "Git ref to check out."
  type        = string
  default     = "main"
}

variable "gemini_api_key" {
  description = "Gemini API key from aistudio.google.com. Written to the instance's .env by user_data."
  type        = string
  sensitive   = true
}

variable "telegram_bot_token" {
  description = "Telegram bot token from @BotFather."
  type        = string
  sensitive   = true
}

variable "telegram_user_id" {
  description = "Your numeric Telegram user ID. When set, the bot is locked to you via dmPolicy=allowlist. Leave empty to use the pairing flow."
  type        = string
  default     = ""
}

variable "tailscale_authkey" {
  description = "Tailscale auth key. Leave empty to install Tailscale without connecting."
  type        = string
  sensitive   = true
  default     = ""
}

variable "openclaw_model" {
  description = "Model id for agents.defaults.model.primary. Bare ids are prefixed with google/."
  type        = string
  default     = "gemini-3.8-flash"
}

variable "allow_ssh" {
  description = "Open port 22 to var.my_ip. Set false once Tailscale SSH or the tailnet is your only access path."
  type        = bool
  default     = true
}
