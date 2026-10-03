output "public_ip" {
  description = "Public IPv4 of the instance."
  value       = aws_instance.openclaw.public_ip
}

output "ssh_command" {
  description = "SSH in as the admin user. After setup.sh hardens sshd, use the openclaw user."
  value       = "ssh ubuntu@${aws_instance.openclaw.public_ip}"
}

output "bootstrap_log" {
  description = "Where to watch the bootstrap on the instance."
  value       = "ssh ubuntu@${aws_instance.openclaw.public_ip} 'sudo tail -f /var/log/openclaw-bootstrap.log'"
}

output "security_group_id" {
  description = "Security group guarding the instance."
  value       = aws_security_group.openclaw.id
}
