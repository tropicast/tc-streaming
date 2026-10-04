variable "name" {
  description = "Server name and label prefix."
  type        = string
  default     = "tc-stream-1"
}

variable "location" {
  description = "Hetzner location. EU locations keep egress inside the included quota."
  type        = string
  default     = "fsn1"
}

variable "server_type" {
  description = "Hetzner server type. CX33: 4 vCPU, 8 GB RAM, 20 TB egress included."
  type        = string
  default     = "cx33"
}

variable "image" {
  description = "Base OS image."
  type        = string
  default     = "debian-12"
}

variable "ssh_public_keys" {
  description = "Admin SSH public keys, keyed by name."
  type        = map(string)

  validation {
    condition     = length(var.ssh_public_keys) > 0
    error_message = "Provide at least one SSH public key."
  }
}

variable "admin_cidrs" {
  description = "CIDRs allowed to reach SSH (port 22)."
  type        = list(string)

  validation {
    condition = length(var.admin_cidrs) > 0 && alltrue([
      for cidr in var.admin_cidrs : !contains(["0.0.0.0/0", "::/0"], cidr)
    ])
    error_message = "List at least one admin CIDR, and do not open SSH to the whole internet."
  }
}

variable "dns_zone" {
  description = "Existing Hetzner DNS zone (e.g. example.com). Null skips DNS records."
  type        = string
  default     = null
}

variable "listen_hostname" {
  description = "Record name for listener traffic inside dns_zone."
  type        = string
  default     = "listen"
}

variable "ingest_hostname" {
  description = "Record name for broadcaster uploads inside dns_zone."
  type        = string
  default     = "ingest"
}

variable "dns_ttl" {
  description = "TTL in seconds for the streaming records."
  type        = number
  default     = 300
}
