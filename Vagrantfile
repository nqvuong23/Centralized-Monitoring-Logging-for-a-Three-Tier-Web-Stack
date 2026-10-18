# -*- mode: ruby -*-
# vi: set ft=ruby :

require "yaml"

BOX         = "bento/ubuntu-24.04"
BOX_VERSION = "202510.26.0"
PROVIDER    = "vmware_desktop"

LAB_NETMASK = "255.255.255.0"
LAB_CIDR    = 24
MAC_PREFIX = "00:50:56:0a:0a"

# Only this node gets the repository mounted, because it runs the k6 scripts.
CONTROL_NAME     = "mgmt01"
REPO_MOUNT_POINT = "/lab"

NODES = [
  { name: "lb01",   mem: 1024, cpus: 2, ip: "192.168.10.10"  },
  { name: "web01",  mem: 1024, cpus: 2, ip: "192.168.10.20"  },
  { name: "web02",  mem: 1024, cpus: 2, ip: "192.168.10.30"  },
  { name: "db01",   mem: 1536, cpus: 2, ip: "192.168.10.40"  },
  { name: "mon01",  mem: 4096, cpus: 2, ip: "192.168.10.100" },
  { name: "mgmt01", mem: 1024, cpus: 2, ip: "192.168.10.111" },
]

def lab_mac(ip)
  last_octet = ip.split(".").last.to_i
  format("%s:%02x", MAC_PREFIX, last_octet)
end

def lab_netplan(ip)
  lab_nic = {
    "match"     => { "macaddress" => lab_mac(ip) },
    "dhcp4"     => false,
    "dhcp6"     => false,
    "addresses" => ["#{ip}/#{LAB_CIDR}"],
  }

  # "lab_nic" is only a label. Without "set-name" netplan does not rename the
  # device, so inside the guest it stays eth1 (or ens34).
  netplan = {
    "network" => {
      "version"   => 2,
      "ethernets" => { "lab_nic" => lab_nic },
    },
  }

  netplan.to_yaml
end

# A marked block for /etc/hosts, so every node can use short names such as
# "db01" in a config file or in an ssh command instead of the full IP address.
def lab_hosts_block
  lines = ["# BEGIN lab hosts"]
  NODES.each do |node|
    lines << "#{node[:ip]} #{node[:name]}"
  end
  lines << "# END lab hosts"
  lines.join("\n") + "\n"
end

def to_base64(text)
  [text].pack("m0")
end

Vagrant.configure("2") do |config|
  config.vm.box         = BOX
  config.vm.box_version = BOX_VERSION
  config.vm.synced_folder ".", "/vagrant", disabled: true

  NODES.each do |node|
    config.vm.define node[:name] do |machine|
      machine.vm.hostname = node[:name]

      # auto_config is false because netplan below owns the lab NIC.
      machine.vm.network "private_network",
        ip:          node[:ip],
        netmask:     LAB_NETMASK,
        adapter:     2,
        mac:         lab_mac(node[:ip]).delete(":"),
        auto_config: false

      machine.vm.provider PROVIDER do |vmware|
        vmware.vmx["displayName"]          = node[:name]
        vmware.vmx["memsize"]              = node[:mem].to_s
        vmware.vmx["numvcpus"]             = node[:cpus].to_s
        vmware.vmx["cpuid.coresPerSocket"] = "1"
        vmware.gui          = false
        vmware.linked_clone = true
      end

      # The k6 scripts live in the repository, and k6 writes its summary back
      # into runs/, so only mgmt01 needs the shared folder.
      if node[:name] == CONTROL_NAME
        machine.vm.synced_folder ".", REPO_MOUNT_POINT, id: "lab-repo"
      end

      netplan_base64 = to_base64(lab_netplan(node[:ip]))
      hosts_base64   = to_base64(lab_hosts_block)
      node_mac       = lab_mac(node[:ip])

      machine.vm.provision "shell", name: "netplan", inline: <<~SHELL
        set -eu

        rm -f /etc/netplan/50-vagrant.yaml
        echo '#{netplan_base64}' | base64 -d > /etc/netplan/60-lab.yaml
        chmod 600 /etc/netplan/60-lab.yaml

        # Bring the lab NIC down first, so "netplan apply" configures it from
        # a clean state. This also makes "vagrant provision" safe to re-run.
        for device_path in /sys/class/net/*; do
          device_name=$(basename "$device_path")
          device_mac=$(cat "$device_path/address")
          if [ "$device_mac" = "#{node_mac}" ]; then
            ip link set "$device_name" down
          fi
        done

        netplan apply
        sleep 2

        echo "[netplan] interfaces after apply:"
        ip -4 -brief address show
      SHELL

      machine.vm.provision "shell", name: "sudo-nopasswd", inline: <<~SHELL
        set -eu

        echo 'vagrant ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/99-vagrant
        chmod 440 /etc/sudoers.d/99-vagrant
        visudo -cf /etc/sudoers.d/99-vagrant
      SHELL

      machine.vm.provision "shell", name: "lab-hosts", inline: <<~SHELL
        set -eu

        # Remove the old block first, so the result is the same on every run.
        sed -i '/^# BEGIN lab hosts$/,/^# END lab hosts$/d' /etc/hosts
        echo '#{hosts_base64}' | base64 -d >> /etc/hosts
      SHELL
    end
  end
end
