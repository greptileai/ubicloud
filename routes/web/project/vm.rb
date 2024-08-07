# frozen_string_literal: true

class CloverWeb
  hash_branch(:project_prefix, "vm") do |r|
    r.get true do
      @vms = Serializers::Vm.serialize(@project.vms_dataset.authorized(@current_user.id, "Vm:view").eager(:semaphores, :assigned_vm_address, :vm_storage_volumes).order(Sequel.desc(:created_at)).all, {include_path: true})

      view "vm/index"
    end

    r.post true do
      Authorization.authorize(@current_user.id, "Vm:create", @project.id)
      fail Validation::ValidationFailed.new({billing_info: "Project doesn't have valid billing information"}) unless @project.has_valid_payment_method?

      ps_id = r.params["private-subnet-id"].empty? ? nil : UBID.parse(r.params["private-subnet-id"]).to_uuid
      Authorization.authorize(@current_user.id, "PrivateSubnet:view", ps_id)

      Validation.validate_boot_image(r.params["boot-image"])
      Validation.validate_vm_size(r.params["size"], only_visible: true)
      location = LocationNameConverter.to_internal_name(r.params["location"])
      storage_size = Validation.validate_vm_storage_size(r.params["size"], r.params["storage_size"])
      st = Prog::Vm::Nexus.assemble(
        r.params["public-key"],
        @project.id,
        name: r.params["name"],
        unix_user: r.params["user"],
        size: r.params["size"],
        storage_volumes: [{size_gib: storage_size, encrypted: true}],
        location: location,
        boot_image: r.params["boot-image"],
        private_subnet_id: ps_id,
        enable_ip4: r.params.key?("enable-ip4")
      )

      flash["notice"] = "'#{r.params["name"]}' will be ready in a few minutes"

      r.redirect "#{@project.path}#{st.subject.path}"
    end

    r.on "create" do
      r.get true do
        Authorization.authorize(@current_user.id, "Vm:create", @project.id)
        @subnets = Serializers::PrivateSubnet.serialize(@project.private_subnets_dataset.authorized(@current_user.id, "PrivateSubnet:view").all)
        @prices = fetch_location_based_prices("VmCores", "VmStorage", "IPAddress")
        @has_valid_payment_method = @project.has_valid_payment_method?
        @default_location = @project.default_location

        view "vm/create"
      end
    end
  end
end
