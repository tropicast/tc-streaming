variable "name" {
  description = "Server name and label prefix."
  type        = string
  default     = "tc-loadgen-1"
}

variable "location" {
  description = "Hetzner location: the streaming node's, so the path between them stays inside one site."
  type        = string
  default     = "fsn1"
}

variable "server_type" {
  description = "Hetzner server type. CX33 (4 vCPU, 8 GB) ran 1,400 listeners and two sources in #12."
  type        = string
  default     = "cx33"
}

variable "image" {
  description = "Base OS image. Debian 13 packages Go 1.24; tools/loadtest needs 1.23."
  type        = string
  default     = "debian-13"
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

variable "repository" {
  description = "Git repository cloned on the server for tools/loadtest and tests/load."
  type        = string
  default     = "https://github.com/tropicast/tc-streaming.git"
}

variable "ref" {
  description = "Branch or tag of the repository to build from."
  type        = string
  default     = "main"
}
