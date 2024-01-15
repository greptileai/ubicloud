# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Minio::MinioServerNexus do
  subject(:nx) { described_class.new(described_class.assemble(minio_pool.id, 0)) }

  let(:minio_pool) {
    mc = MinioCluster.create_with_id(
      location: "hetzner-hel1",
      name: "minio-cluster-name",
      admin_user: "minio-admin",
      admin_password: "dummy-password",
      private_subnet_id: ps.id
    )

    MinioPool.create_with_id(
      start_index: 0,
      cluster_id: mc.id,
      server_count: 1,
      drive_count: 1,
      storage_size_gib: 100,
      vm_size: "standard-2"
    )
  }
  let(:ps) {
    Prog::Vnet::SubnetNexus.assemble(
      minio_project.id, name: "minio-cluster-name"
    )
  }

  let(:minio_project) { Project.create_with_id(name: "default", provider: "hetzner").tap { _1.associate_with_project(_1) } }

  before do
    allow(Config).to receive(:minio_service_project_id).and_return(minio_project.id)
  end

  describe ".cluster" do
    it "returns minio cluster" do
      expect(nx.cluster).to eq minio_pool.cluster
    end
  end

  describe ".assemble" do
    it "creates a vm and minio server" do
      st = described_class.assemble(minio_pool.id, 0)
      expect(MinioServer.count).to eq 1
      expect(st.label).to eq "start"
      expect(MinioServer.first.pool).to eq minio_pool
      expect(Vm.count).to eq 1
      expect(Vm.first.unix_user).to eq "minio-user"
      expect(Vm.first.sshable.host).to eq "temp_#{Vm.first.id}"
      expect(Vm.first.private_subnets.first.id).to eq ps.id
    end

    it "fails if pool is not valid" do
      expect {
        described_class.assemble(SecureRandom.uuid, 0)
      }.to raise_error RuntimeError, "No existing pool"
    end
  end

  describe "#start" do
    it "nap 5 sec until VM is up and running" do
      expect { nx.start }.to nap(5)
    end

    it "updates sshable and hops to bootstrap_rhizome if dnszone doesn't exist" do
      vm = nx.minio_server.vm
      vm.strand.update(label: "wait")
      expect(nx).to receive(:register_deadline)
      expect(nx).to receive(:bud).with(Prog::BootstrapRhizome, {"target_folder" => "minio", "subject_id" => vm.id, "user" => "minio-user"})
      expect { nx.start }.to hop("wait_bootstrap_rhizome")
    end

    it "updates sshable, inserts dns record and hops to bootstrap_rhizome if dnszone exists" do
      DnsZone.create_with_id(project_id: minio_project.id, name: Config.minio_host_name)
      vm = nx.minio_server.vm
      vm.strand.update(label: "wait")
      expect(nx.minio_server.dns_zone).to receive(:insert_record).with(record_name: nx.cluster.hostname, type: "A", ttl: 10, data: vm.ephemeral_net4.to_s)
      expect(nx).to receive(:register_deadline)
      expect(nx).to receive(:bud).with(Prog::BootstrapRhizome, {"target_folder" => "minio", "subject_id" => vm.id, "user" => "minio-user"})
      expect { nx.start }.to hop("wait_bootstrap_rhizome")
    end
  end

  describe "#wait_bootstrap_rhizome" do
    before { expect(nx).to receive(:reap) }

    it "donates if bootstrap rhizome continues" do
      expect(nx).to receive(:leaf?).and_return(false)
      expect(nx).to receive(:donate).and_call_original
      expect { nx.wait_bootstrap_rhizome }.to nap(0)
    end

    it "hops to setup if bootstrap rhizome is done" do
      expect(nx).to receive(:leaf?).and_return(true)
      expect { nx.wait_bootstrap_rhizome }.to hop("setup")
    end
  end

  describe "#setup" do
    it "buds minio setup and hops to wait_setup" do
      expect(nx).to receive(:bud).with(Prog::Minio::SetupMinio, {}, :mount_data_disks)
      expect(nx).to receive(:bud).with(Prog::Minio::SetupMinio, {}, :install_minio)
      expect(nx).to receive(:bud).with(Prog::Minio::SetupMinio, {}, :configure_minio)
      expect { nx.setup }.to hop("wait_setup")
    end
  end

  describe "#wait_setup" do
    before { expect(nx).to receive(:reap) }

    it "donates if setup continues" do
      expect(nx).to receive(:leaf?).and_return(false)
      expect(nx).to receive(:donate).and_call_original
      expect { nx.wait_setup }.to nap(0)
    end

    it "hops to wait if setup is done" do
      expect(nx).to receive(:leaf?).and_return(true)
      expect { nx.wait_setup }.to hop("wait")
    end
  end

  describe "#minio_restart" do
    it "hops to wait if succeeded" do
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check restart_minio").and_return("Succeeded")
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --clean restart_minio")
      expect { nx.minio_restart }.to exit({"msg" => "minio server is restarted"})
    end

    it "naps if minio is not started" do
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check restart_minio").and_return("NotStarted")
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer 'systemctl restart minio' restart_minio")
      expect { nx.minio_restart }.to nap(1)
    end

    it "naps if minio is failed" do
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check restart_minio").and_return("Failed")
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer 'systemctl restart minio' restart_minio")
      expect { nx.minio_restart }.to nap(1)
    end

    it "naps if the status is unknown" do
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check restart_minio").and_return("Unknown")
      expect { nx.minio_restart }.to nap(1)
    end
  end

  describe "#wait" do
    it "naps" do
      expect { nx.wait }.to nap(10)
    end

    it "hops to unavailable if checkup is set and the server is not available" do
      expect(nx).to receive(:when_checkup_set?).and_yield
      expect(nx).to receive(:available?).and_return(false)
      expect { nx.wait }.to hop("unavailable")
    end

    it "naps if checkup is set but the server is available" do
      expect(nx).to receive(:when_checkup_set?).and_yield
      expect(nx).to receive(:available?).and_return(true)
      expect { nx.wait }.to nap(10)
    end

    it "hops to wait_reconfigure if reconfigure is set" do
      expect(nx).to receive(:when_reconfigure_set?).and_yield
      expect(nx).to receive(:bud).with(Prog::Minio::SetupMinio, {}, :configure_minio)
      expect { nx.wait }.to hop("wait_reconfigure")
    end

    it "pushes minio_restart if restart is set" do
      expect(nx).to receive(:when_restart_set?).and_yield
      expect(nx).to receive(:push).with(described_class, {}, "minio_restart").and_call_original
      expect { nx.wait }.to hop("minio_restart")
    end
  end

  describe "#wait_reconfigure" do
    before { expect(nx).to receive(:reap) }

    it "donates if reconfigure continues" do
      expect(nx).to receive(:leaf?).and_return(false)
      expect(nx).to receive(:donate).and_call_original
      expect { nx.wait_reconfigure }.to nap(0)
    end

    it "hops to wait if reconfigure is done" do
      expect(nx).to receive(:leaf?).and_return(true)
      expect { nx.wait_reconfigure }.to hop("wait")
    end
  end

  describe "#unavailable" do
    it "hops to wait if the server is available" do
      expect(nx).to receive(:available?).and_return(true)
      expect { nx.unavailable }.to hop("wait")
    end

    it "buds minio_restart if the server is not available" do
      expect(nx).to receive(:available?).and_return(false)
      expect(nx).to receive(:bud).with(described_class, {}, :minio_restart)
      expect { nx.unavailable }.to nap(5)
    end

    it "does not bud minio_restart if there is already one restart going on" do
      expect(nx).to receive(:available?).and_return(false).twice
      expect { nx.unavailable }.to nap(5)
      expect(nx).not_to receive(:bud).with(described_class, {}, :minio_restart)
      expect { nx.unavailable }.to nap(5)
    end
  end

  describe "#destroy" do
    it "triggers vm destroy, nic, sshable and minio server destroy" do
      expect(nx).to receive(:register_deadline).with(nil, 10 * 60)
      expect(nx).to receive(:decr_destroy)
      expect(nx.minio_server.vm.sshable).to receive(:destroy)
      expect(nx.minio_server.vm.nics.first).to receive(:incr_destroy)
      expect(nx.minio_server.vm).to receive(:incr_destroy)
      expect(nx.minio_server).to receive(:destroy)
      expect { nx.destroy }.to exit({"msg" => "minio server destroyed"})
    end

    it "triggers vm destroy, nic, sshable, dnszone delete record and minio server destroy if dnszone exits" do
      DnsZone.create_with_id(project_id: minio_project.id, name: Config.minio_host_name)
      expect(nx).to receive(:register_deadline).with(nil, 10 * 60)
      expect(nx).to receive(:decr_destroy)
      expect(nx.minio_server.vm.sshable).to receive(:destroy)
      expect(nx.minio_server.vm.nics.first).to receive(:incr_destroy)
      expect(nx.minio_server.vm).to receive(:incr_destroy)
      expect(nx.minio_server).to receive(:destroy)
      expect(nx.minio_server.dns_zone).to receive(:delete_record).with(record_name: nx.cluster.hostname)
      expect { nx.destroy }.to exit({"msg" => "minio server destroyed"})
    end
  end

  describe "#before_run" do
    it "hops to destroy if strand is not destroy" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect { nx.before_run }.to hop("destroy")
    end

    it "does not hop to destroy if strand is destroy" do
      nx.strand.update(label: "destroy")
      expect { nx.before_run }.not_to hop("destroy")
    end

    it "does not hop to destroy if destroy is not set" do
      expect(nx).to receive(:when_destroy_set?).and_return(false)
      expect { nx.before_run }.not_to hop("destroy")
    end

    it "does not hop to destroy if strand label is destroy" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx.strand).to receive(:label).and_return("destroy")
      expect { nx.before_run }.not_to hop("destroy")
    end
  end

  describe "#available?" do
    it "returns true if health check is successful" do
      expect(nx.minio_server.vm).to receive(:ephemeral_net4).and_return("1.2.3.4").twice
      stub_request(:get, "http://1.2.3.4:9000/minio/admin/v3/info").to_return(status: 200, body: JSON.generate({servers: [{state: "online", endpoint: "1.2.3.4:9000", drives: [{state: "ok"}]}]}))
      expect(nx.available?).to be(true)
    end

    it "returns false if health check is unsuccessful" do
      expect(nx.minio_server.vm).to receive(:ephemeral_net4).and_return("1.2.3.4").twice
      stub_request(:get, "http://1.2.3.4:9000/minio/admin/v3/info").to_return(status: 200, body: JSON.generate({servers: [{state: "offline", endpoint: "1.2.3.4:9000"}]}))
      expect(nx.available?).to be(false)
    end

    it "returns false if health check raises an exception" do
      expect(Minio::Client).to receive(:new).and_raise(RuntimeError)
      expect(nx.available?).to be(false)
    end
  end
end
