require 'yaml'

# Structural certification for the Flower FL OneFlow service WRAPPER.
#
# This appliance directory carries only the marketplace SERVICE_TEMPLATE +
# VMTEMPLATE definitions; it boots NO VM of its own (the testable images are
# appliances/flower_superlink and appliances/flower_supernode). So this spec
# deliberately does NOT use the vm_handler/app_handler harness (which would
# need a metadata.yaml + a single bootable image). It is self-contained and
# only validates the wrapper YAMLs, so that `app_readiness.rb flower_service`
# finds a test and PASSES instead of erroring with "Missing test file
# tests.yaml" / "0 examples" when the CI is pointed at the wrapper.
describe 'Flower FL service template (wrapper structure)' do
    def wrapper_docs
        Dir[File.join(__dir__, '..', '*.yaml')].map do |f|
            begin
                YAML.safe_load(File.read(f), permitted_classes: [], aliases: true)
            rescue StandardError
                nil
            end
        end.compact.select { |d| d.is_a?(Hash) }
    end

    def service_template
        wrapper_docs.find { |d| d['type'].to_s.include?('SERVICE_TEMPLATE') }
    end

    it 'contains a SERVICE_TEMPLATE definition with roles' do
        st = service_template
        expect(st).not_to be_nil
        expect(st['roles']).to be_a(Hash)
        expect(st.dig('opennebula_template', 'roles')).to be_a(Array)
    end

    it 'defines the superlink and supernode roles' do
        st = service_template
        expect(st['roles'].keys.map(&:to_s)).to include('superlink', 'supernode')
    end

    it 'has the SuperLink and SuperNode VMTEMPLATEs the roles reference' do
        names = wrapper_docs.select { |d| d['type'].to_s == 'VMTEMPLATE' }.map { |d| d['name'].to_s }
        expect(names.any? { |n| n.include?('SuperLink') }).to be true
        expect(names.any? { |n| n.include?('SuperNode') }).to be true
    end
end
