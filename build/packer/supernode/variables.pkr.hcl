variable "appliance_name" {
  type    = string
  default = "flower-supernode"
}

variable "input_dir" {
  type        = string
  description = "Directory containing base OS image (ubuntu2204.qcow2)"
}

variable "output_dir" {
  type        = string
  description = "Directory for output QCOW2 image"
}

variable "headless" {
  type    = bool
  default = true
}

variable "version" {
  type    = string
  default = ""
}

variable "one_apps_dir" {
  type        = string
  description = "Path to one-apps repository checkout"
  default     = "../one-apps"
}
