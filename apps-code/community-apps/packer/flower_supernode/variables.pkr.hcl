variable "appliance_name" {
  type    = string
  default = "flower_supernode"
}

variable "input_dir" {
  type = string
}

variable "output_dir" {
  type = string
}

variable "headless" {
  type    = bool
  default = true
}

variable "version" {
  type    = string
  default = ""
}

variable "distro" {
  type    = string
  default = ""
}
