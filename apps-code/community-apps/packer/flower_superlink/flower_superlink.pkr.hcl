source "null" "null" { communicator = "none" }

# Generate the cloud-init ISO for Packer provisioning
build {
  sources = ["source.null.null"]

  provisioner "shell-local" {
    inline = [
      "cloud-localds ${var.input_dir}/${var.appliance_name}-cloud-init.iso ${var.input_dir}/cloud-init.yml",
    ]
  }
}

# QEMU VM build from Ubuntu 24.04 minimal base image
source "qemu" "flower_superlink" {
  cpus        = 2
  memory      = 4096
  accelerator = "kvm"

  iso_url      = "../one-apps/export/ubuntu2404min.qcow2"
  iso_checksum = "none"

  headless = var.headless

  disk_image       = true
  disk_cache       = "unsafe"
  disk_interface   = "virtio"
  net_device       = "virtio-net"
  format           = "qcow2"
  disk_compression = false
  disk_size        = "10000"

  output_directory = var.output_dir

  qemuargs = [["-serial", "stdio"],
    ["-cpu", "host"],
    ["-cdrom", "${var.input_dir}/${var.appliance_name}-cloud-init.iso"],
    ["-netdev", "user,id=net0,hostfwd=tcp::{{ .SSHHostPort }}-:22"],
    ["-device", "virtio-net-pci,netdev=net0"]
  ]
  ssh_username     = "root"
  ssh_password     = "opennebula"
  ssh_wait_timeout = "900s"
  shutdown_command = "poweroff"
  vm_name          = "${var.appliance_name}"
}

# Provision the SuperLink appliance inside the VM
build {
  sources = ["source.qemu.flower_superlink"]

  # revert insecure ssh options done by cloud-init start_script
  provisioner "shell" {
    scripts = ["${var.input_dir}/81-configure-ssh.sh"]
  }

  # Install one-context package (creates /etc/one-context.d/, purges cloud-init)
  provisioner "shell" { inline = ["mkdir -p /context"] }

  provisioner "file" {
    source      = "../one-apps/context-linux/out/"
    destination = "/context"
  }

  provisioner "shell" {
    inline_shebang = "/bin/bash -e"
    inline = [
      "export DEBIAN_FRONTEND=noninteractive",
      "apt-get update",
      "echo 'exit 101' >/usr/sbin/policy-rc.d && chmod a+x /usr/sbin/policy-rc.d",
      "LATEST=$(find /context/ -type f -name 'one-context*.deb' | sort -V | tail -n1)",
      "dpkg -i --auto-deconfigure \"$LATEST\" || apt-get install -y -f",
      "dpkg -i --auto-deconfigure \"$LATEST\"",
      "apt-get install -y --no-install-recommends --no-install-suggests netplan.io network-manager",
      "echo 'exit 0' >/usr/sbin/policy-rc.d && chmod a+x /usr/sbin/policy-rc.d",
      "rm -rf /context",
      "sync",
    ]
  }

  ##############################################
  # BEGIN placing script logic inside Guest OS #
  ##############################################

  provisioner "shell" {
    inline_shebang = "/bin/bash -e"
    inline = [
      "install -o 0 -g 0 -m u=rwx,g=rx,o=   -d /etc/one-appliance/{,service.d/,lib/}",
      "install -o 0 -g 0 -m u=rwx,g=rx,o=rx -d /opt/one-appliance/{,bin/}",
    ]
  }

  provisioner "file" {
    sources = [
      "../one-apps/appliances/scripts/net-90-service-appliance",
      "../one-apps/appliances/scripts/net-99-report-ready",
    ]
    destination = "/etc/one-appliance/"
  }

  # Bash libraries for the one-appliance framework
  provisioner "file" {
    sources = [
      "../../lib/common.sh",
      "../../lib/functions.sh",
    ]
    destination = "/etc/one-appliance/lib/"
  }

  # Contains the appliance service management tool
  # https://github.com/OpenNebula/one-apps/wiki/apps_intro#appliance-life-cycle
  provisioner "file" {
    source      = "../one-apps/appliances/service.sh"
    destination = "/etc/one-appliance/service"
  }

  # Flower SuperLink appliance lifecycle script
  provisioner "file" {
    source      = "../../appliances/flower_service/appliance-superlink.sh"
    destination = "/etc/one-appliance/service.d/appliance.sh"
  }

  provisioner "shell" {
    scripts = ["${var.input_dir}/82-configure-context.sh"]
  }

  #######################################################################
  # Setup appliance: Execute install step                               #
  # https://github.com/OpenNebula/one-apps/wiki/apps_intro#installation #
  #######################################################################
  provisioner "shell" {
    inline_shebang = "/bin/bash -e"
    inline         = ["/etc/one-appliance/service install && sync"]
  }

  # Remove machine ID from the VM and get it ready for continuous cloud use
  # https://github.com/OpenNebula/one-apps/wiki/tool_dev#appliance-build-process
  post-processor "shell-local" {
    execute_command = ["bash", "-c", "{{.Vars}} {{.Script}}"]
    environment_vars = [
      "OUTPUT_DIR=${var.output_dir}",
      "APPLIANCE_NAME=${var.appliance_name}",
    ]
    scripts = ["packer/postprocess.sh"]
  }
}
