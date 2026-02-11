packer {
  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = ">= 1.1.0"
    }
  }
}

# --------------------------------------------------------------------------
# Build 1: Generate cloud-init seed ISO for Packer SSH access
# --------------------------------------------------------------------------
source "null" "context" {
  communicator = "none"
}

build {
  name = "context"

  sources = ["source.null.context"]

  provisioner "shell-local" {
    inline = [
      "cloud-localds ${var.appliance_name}-cloud-init.iso cloud-init.yml",
    ]
  }
}

# --------------------------------------------------------------------------
# Build 2: Provision the SuperLink QCOW2 image
# --------------------------------------------------------------------------
source "qemu" "superlink" {
  accelerator = "kvm"

  cpus      = 2
  memory    = 4096
  disk_size = "10G"

  iso_url      = "${var.input_dir}/ubuntu2404.qcow2"
  iso_checksum = "none"
  disk_image   = true

  output_directory = "${var.output_dir}"
  vm_name          = "${var.appliance_name}.qcow2"
  format           = "qcow2"

  headless = var.headless

  net_device     = "virtio-net"
  disk_interface = "virtio"

  qemuargs = [
    ["-cdrom", "${var.appliance_name}-cloud-init.iso"],
    ["-serial", "mon:stdio"],
  ]

  boot_wait = "30s"

  communicator = "ssh"
  ssh_username = "root"
  ssh_password = "opennebula"
  ssh_timeout  = "10m"
}

build {
  name = "superlink"

  sources = ["source.qemu.superlink"]

  # Step 1: SSH hardening (revert insecure build-time settings)
  provisioner "shell" {
    script = "../scripts/81-configure-ssh.sh"
  }

  # Step 2: Install one-context package (OpenNebula contextualization)
  provisioner "shell" {
    inline = ["mkdir -p /context"]
  }

  provisioner "file" {
    source      = "${var.one_apps_dir}/context-linux/out/"
    destination = "/context"
  }

  provisioner "shell" {
    script = "../scripts/80-install-context.sh"
  }

  # Step 3: Create one-appliance directory structure
  provisioner "shell" {
    inline = [
      "mkdir -p /etc/one-appliance/service.d",
      "mkdir -p /etc/one-appliance/lib",
      "mkdir -p /opt/one-appliance/bin",
    ]
  }

  # Step 4: Install one-apps framework files
  provisioner "file" {
    sources = [
      "${var.one_apps_dir}/appliances/scripts/net-90-service-appliance",
      "${var.one_apps_dir}/appliances/scripts/net-99-report-ready",
    ]
    destination = "/tmp/"
  }

  provisioner "file" {
    source      = "${var.one_apps_dir}/appliances/service.sh"
    destination = "/etc/one-appliance/service"
  }

  provisioner "shell" {
    inline = ["chmod 0755 /etc/one-appliance/service"]
  }

  provisioner "file" {
    source      = "${var.one_apps_dir}/appliances/lib/common.sh"
    destination = "/etc/one-appliance/lib/common.sh"
  }

  provisioner "file" {
    source      = "${var.one_apps_dir}/appliances/lib/functions.sh"
    destination = "/etc/one-appliance/lib/functions.sh"
  }

  # Step 5: Install Flower SuperLink appliance script
  provisioner "file" {
    source      = "../../superlink/appliance.sh"
    destination = "/etc/one-appliance/service.d/appliance.sh"
  }

  # Step 6: Move context hooks into place
  provisioner "shell" {
    script = "../scripts/82-configure-context.sh"
  }

  # Step 7: Run service install (downloads Docker, pulls images)
  provisioner "shell" {
    inline = ["/etc/one-appliance/service install"]
  }

  # Step 8: Clean up for cloud reuse
  provisioner "shell" {
    inline = [
      "export DEBIAN_FRONTEND=noninteractive",
      "apt-get purge -y cloud-init snapd fwupd || true",
      "apt-get autoremove -y --purge || true",
      "apt-get clean -y",
      "rm -rf /var/lib/apt/lists/*",
      "rm -f /etc/sysctl.d/99-cloudimg-ipv6.conf",
      "rm -rf /context/",
      "truncate -s 0 /etc/machine-id",
      "rm -f /var/lib/dbus/machine-id",
      "rm -rf /tmp/* /var/tmp/*",
      "sync",
    ]
  }
}
