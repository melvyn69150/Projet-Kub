# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# Cluster k3s HA sur VMware Workstation (provider vagrant-vmware-desktop).
# `vagrant up` cree 6 VMs et forme automatiquement un cluster HA :
#   - 3 control planes (etcd embarque, quorum) + VIP kube-vip
#   - 3 workers
#
# Reseau : hostonly VMware 192.168.60.0/24
#   VIP (API server)   -> 192.168.60.10   (portee par kube-vip, aucune VM dediee)
#   cp1/cp2/cp3        -> .11 / .12 / .13
#   w1/w2/w3           -> .21 / .22 / .23

# ---- Parametres modifiables -------------------------------------------------
VIP        = "192.168.60.10"
# Secret partage du cluster. A traiter comme un mot de passe (ne pas commit en vrai).
K3S_TOKEN  = "MrZf2Ojh3MoGEuPjcb62"
BOX        = "bento/ubuntu-24.04"

NODES = [
  { name: "cp1", ip: "192.168.60.11", role: "server-init", mem: 3000, cpu: 2 },
  { name: "cp2", ip: "192.168.60.12", role: "server",      mem: 3000, cpu: 2 },
  { name: "cp3", ip: "192.168.60.13", role: "server",      mem: 3000, cpu: 2 },
  { name: "w1",  ip: "192.168.60.21", role: "agent",       mem: 3000, cpu: 2 },
  { name: "w2",  ip: "192.168.60.22", role: "agent",       mem: 3000, cpu: 2 },
  { name: "w3",  ip: "192.168.60.23", role: "agent",       mem: 3000, cpu: 2 },
]
# -----------------------------------------------------------------------------

Vagrant.configure("2") do |config|
  config.vm.box = BOX
  # Cle SSH inseree par Vagrant : suffisant pour un lab.
  config.ssh.insert_key = true

  NODES.each do |node|
    config.vm.define node[:name] do |m|
      m.vm.hostname = node[:name]
      m.vm.network "private_network", ip: node[:ip]

      m.vm.provider "vmware_desktop" do |v|
        v.gui              = false
        v.vmx["memsize"]   = node[:mem].to_s
        v.vmx["numvcpus"]  = node[:cpu].to_s
        v.vmx["vhv.enable"] = "TRUE"
      end

      script = case node[:role]
               when "server-init" then "scripts/install-server-init.sh"
               when "server"      then "scripts/install-server.sh"
               else                    "scripts/install-agent.sh"
               end

      m.vm.provision "shell",
        path: script,
        args: [node[:ip], VIP, K3S_TOKEN]
    end
  end
end
