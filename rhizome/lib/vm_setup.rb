#!/bin/env ruby
# frozen_string_literal: true

require_relative "common"

require "fileutils"
require "netaddr"
require_relative "vm_path"

class VmSetup
  def initialize(vm_name)
    @vm_name = vm_name
  end

  def q_vm
    @q_vm ||= @vm_name.shellescape
  end

  # YAML quoting
  def yq(s)
    require "yaml"
    # I don't see a better way to quote a string meant for embedding
    # in literal YAML other than to generate a full YAML document and
    # then stripping out headers and footers.  Consider the special
    # string "NO" (parses as boolean, unless quoted):
    #
    # > YAML.dump('NO')
    # => "--- 'NO'\n"
    #
    # > YAML.dump('NO')[4..-2]
    # => "'NO'"
    YAML.dump(s)[4..-2]
  end

  def vp
    @vp ||= VmPath.new(@vm_name)
  end

  def prep(unix_user, public_key, gua, boot_image)
    add_vm_user
    interfaces
    routes(gua)
    cloudinit(unix_user, public_key)
    boot_disk(boot_image)
    install_systemd_unit
    forwarding
  end

  def network(unix_user, public_key, gua)
    interfaces
    routes(gua)
    cloudinit(unix_user, public_key)
    forwarding
  end

  # Delete all traces of the VM.
  def purge
    r "ip netns del #{q_vm}"
    FileUtils.rm_f(vp.systemd_service)
    r "systemctl daemon-reload"
    r "deluser --remove-home #{q_vm}"
  end

  def add_vm_user
    r "adduser --disabled-password --gecos '' #{q_vm}"
    r "usermod -a -G kvm #{q_vm}"
  end

  def interfaces
    r "ip netns add #{q_vm}"

    # Generate MAC addresses rather than letting Linux do it to avoid
    # a vexing bug whereby a freshly created link will, at least once,
    # spontaneously change its MAC address sometime soon after
    # creation, as caught by instrumenting reads of
    # /sys/class/net/vethi#{q_vm}/address at two points in time.  The
    # result is a race condition that *sometimes* worked.
    r "ip link add vetho#{q_vm} addr #{gen_mac.shellescape} type veth peer name vethi#{q_vm} addr #{gen_mac.shellescape} netns #{q_vm}"

    r "ip -n #{q_vm} tuntap add dev tap#{q_vm} mode tap user #{q_vm}"
  end

  def subdivide_network(net)
    prefix = net.netmask.prefix_len + 1
    halved = net.resize(prefix)
    [halved, halved.next_sib]
  end

  def routes(gua)
    # Routing: from host to subordinate.
    vethi_ll = mac_to_ipv6_link_local(r("ip netns exec #{q_vm} cat /sys/class/net/vethi#{q_vm}/address").chomp)
    r "ip link set dev vetho#{q_vm} up"
    r "ip route add #{gua.shellescape} via #{vethi_ll.shellescape} dev vetho#{q_vm}"

    # Write out guest-delegated and clover infrastructure address
    # ranges, designed around non-floating IPv6 networks bound to the
    # host.
    guest_ephemeral, clover_ephemeral = subdivide_network(NetAddr.parse_net(gua))

    # Accept clover traffic within the namespace (don't just let it
    # enter a default routing loop via forwarding)
    r "ip -n #{q_vm} addr add #{clover_ephemeral.to_s.shellescape} dev vethi#{q_vm}"

    # Routing: from subordinate to host.
    vetho_ll = mac_to_ipv6_link_local(File.read("/sys/class/net/vetho#{q_vm}/address").chomp)
    r "ip -n #{q_vm} link set dev vethi#{q_vm} up"
    r "ip -n #{q_vm} route add default via #{vetho_ll.shellescape} dev vethi#{q_vm}"

    vp.write_guest_ephemeral(guest_ephemeral.to_s)
    vp.write_clover_ephemeral(clover_ephemeral.to_s)

    # Route ephemeral address to tap.
    r "ip -n #{q_vm} link set dev tap#{q_vm} up"
    r "ip -n #{q_vm} route add #{guest_ephemeral.to_s.shellescape} via #{mac_to_ipv6_link_local(guest_mac)} dev tap#{q_vm}"
  end

  def cloudinit(unix_user, public_key)
    require "yaml"

    vp.write_meta_data(<<EOS)
instance-id: #{yq(@vm_name)}
local-hostname: #{yq(@vm_name)}
EOS

    tap_mac = r("ip netns exec #{q_vm} cat /sys/class/net/tap#{q_vm}/address")

    vp.write_network_config(<<EOS)
version: 2
ethernets:
  id0:
    match:
      macaddress: #{yq(guest_mac)}
    addresses: [#{yq(vp.read_guest_ephemeral)}]
    gateway6: #{yq(mac_to_ipv6_link_local(tap_mac))}
    nameservers:
      addresses: [2a01:4ff:ff00::add:1, 2a01:4ff:ff00::add:2]
EOS

    write_user_data(unix_user, public_key)

    r "mkdosfs -n CIDATA -C #{vp.q_cloudinit_img} 8192"
    r "mcopy -oi #{vp.q_cloudinit_img} -s #{vp.q_user_data} ::"
    r "mcopy -oi #{vp.q_cloudinit_img} -s #{vp.q_meta_data} ::"
    r "mcopy -oi #{vp.q_cloudinit_img} -s #{vp.q_network_config} ::"
    FileUtils.chown @vm_name, @vm_name, vp.cloudinit_img
  end

  def write_user_data(unix_user, public_key)
    vp.write_user_data(<<EOS)
#cloud-config
users:
  - name: cloud
    passwd: $6$7125787751a8d18a$sHwGySomUA1PawiNFWVCKYQN.Ec.Wzz0JtPPL1MvzFrkwmop2dq7.4CYf03A5oemPQ4pOFCCrtCelvFBEle/K.
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: False
    inactive: False
    shell: /bin/bash
  - name: #{yq(unix_user)}
    sudo: ALL=(ALL) NOPASSWD:ALL
    inactive: False
    shell: /bin/bash
    ssh_authorized_keys:
      - #{yq(public_key)}

ssh_pwauth: False

runcmd:
  - [ systemctl, daemon-reload]
  - [ systemctl, enable, notify-booted.service]
  - [ systemctl, start, --no-block, notify-booted.service ]
EOS
  end

  def boot_disk(boot_image)
    urls = {
      "ubuntu-jammy" => "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img",
      "almalinux-9.1" => "https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-9.1-20221118.x86_64.qcow2"
    }

    download = urls.fetch(boot_image)
    image_path = "/opt/" + boot_image + ".qcow2"
    unless File.exist?(image_path)
      # Use of File::EXCL provokes a crash rather than a race
      # condition if two VMs are lazily getting their images at the
      # same time.
      #
      # YYY: Need to replace this with something that can handle
      # customer images.  As-is, it does not have all the
      # synchronization features we might want if we were to keep this
      # code longer term, but, that's not the plan.
      temp_path = image_path + ".tmp"
      File.open(temp_path, File::RDWR | File::CREAT | File::EXCL, 0o644) do
        r "curl -o #{temp_path.shellescape} #{download.shellescape}"
      end
      FileUtils.mv(temp_path, image_path)
    end

    # Images are presumed to be atomically renamed into the path,
    # i.e. no partial images will be passed to qemu-image.
    r "qemu-img convert -p -f qcow2 -O raw #{image_path.shellescape} #{vp.q_boot_raw}"
    FileUtils.chown @vm_name, @vm_name, vp.boot_raw
  end

  # Unnecessary if host has this set before creating the netns, but
  # harmless and fast enough to double up.
  def forwarding
    r("ip netns exec #{q_vm} sysctl -w net.ipv6.conf.all.forwarding=1")
  end

  def install_systemd_unit
    # YYY: Do something about systemd escaping, i.e. research the
    # rules and write a routine for it.  Banning suspicious strings
    # from VmPath is also a good idea.

    # YYY: Write helpers to select ch-remote and cloud-hypervisor
    # binaries.  The `/opt/cloud-hypervisor/#{version}` paths are
    # strewn around, and unmanable once there are multiple versions.
    vp.write_systemd_service <<SERVICE
[Unit]
Description=#{@vm_name}
After=network.target

[Service]
NetworkNamespacePath=/var/run/netns/#{@vm_name}
ExecStartPre=/usr/bin/rm -f #{vp.ch_api_sock}
ExecStart=/opt/cloud-hypervisor/v30.0/cloud-hypervisor \
      --api-socket path=#{vp.ch_api_sock}              \
      --kernel /opt/fw/v0.4.2/hypervisor-fw            \
      --disk path=#{vp.boot_raw}                       \
      --disk path=#{vp.cloudinit_img}                  \
      --console off --serial file=#{vp.serial_log}     \
      --cpus boot=4                                    \
      --memory size=1024M                              \
      --net "mac=#{guest_mac},tap=tap#{@vm_name},ip=,mask="
ExecStop=/opt/cloud-hypervisor/v30.0/ch-remote --api-socket #{vp.ch_api_sock} shutdown-vmm
Restart=no
User=#{@vm_name}
Group=#{@vm_name}
SERVICE
    r "systemctl daemon-reload"
  end

  # Does not return, replaces process with cloud-hypervisor running the guest.
  def exec_cloud_hypervisor
    require "etc"
    serial_device = if $stdout.tty?
      "tty"
    else
      "file=#{vp.serial_log}"
    end
    u = Etc.getpwnam(@vm_name)
    Dir.chdir(u.dir)
    exec(
      "/usr/sbin/ip", "netns", "exec", @vm_name,
      "/usr/bin/setpriv", "--reuid=#{u.uid}", "--regid=#{u.gid}", "--init-groups", "--reset-env",
      "--",
      "/opt/cloud-hypervisor/v30.0/cloud-hypervisor",
      "--api-socket", "path=#{vp.ch_api_sock}",
      "--kernel", "/opt/fw/v0.4.2/hypervisor-fw",
      "--disk", "path=#{vp.boot_raw}",
      "--disk", "path=#{vp.cloudinit_img}",
      "--console", "off", "--serial", serial_device,
      "--cpus", "boot=4",
      "--memory", "size=1024M",
      "--net", "mac=#{guest_mac},tap=tap#{@vm_name},ip=,mask=",
      close_others: true
    )
  end

  # Generate a MAC with the "local" (generated, non-manufacturer) bit
  # set and the multicast bit cleared in the first octet.
  #
  # Accuracy here are is not a formality: otherwise assigning a ipv6
  # link local address errors out.
  def gen_mac
    ([rand(256) & 0xFE | 0x02] + 5.times.map { rand(256) }).map {
      "%0.2X" % _1
    }.join(":").downcase
  end

  def guest_mac
    # YYY: Should make this static and saved by control plane, it's
    # not that hard to do, can spare licensed software users some
    # issues:
    # https://stackoverflow.com/questions/55686021/static-mac-addresses-for-ec2-instance
    # https://techcommunity.microsoft.com/t5/itops-talk-blog/understanding-static-mac-address-licensing-in-azure/ba-p/1386187
    @guest_mac ||= begin
      vp.read_guest_mac
    rescue Errno::ENOENT
      gen_mac.tap { vp.write_guest_mac(_1) }
    end
  end

  # By reading the mac address from an interface, compute its ipv6
  # link local address that it would have if its device state were set
  # to up.
  def mac_to_ipv6_link_local(mac)
    eui = mac.split(":").map(&:hex)
    eui.insert(3, 0xff, 0xfe)
    eui[0] ^= 0x02

    "fe80::" + eui.each_slice(2).map { |pair|
      pair.map { format("%02x", _1) }.join
    }.join(":")
  end
end