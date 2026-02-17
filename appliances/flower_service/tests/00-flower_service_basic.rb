require_relative '../../../lib/community/app_handler' # Loads the library to handle VM creation and destruction

describe 'Flower SuperLink Appliance Certification' do
    # This is a library that takes care of creating and destroying the VM for you
    # The VM is instantiated with your APP_CONTEXT_PARAMS passed
    include_context('vm_handler')

    # Verify Docker is installed inside the appliance
    it 'docker is installed' do
        cmd = 'which docker'
        start_time = Time.now
        timeout = 120

        loop do
            result = @info[:vm].ssh(cmd)
            break if result.success?

            if Time.now - start_time > timeout
                raise "Docker was not found within #{timeout} seconds"
            end

            sleep 5
        end
    end

    # Verify Docker daemon is running
    it 'docker service is running' do
        cmd = 'systemctl is-active docker'
        start_time = Time.now
        timeout = 60

        loop do
            result = @info[:vm].ssh(cmd)
            break if result.success?

            if Time.now - start_time > timeout
                raise "Docker service did not become active within #{timeout} seconds"
            end

            sleep 5
        end
    end

    # Verify the SuperLink container image was pulled during install
    it 'superlink container image is present' do
        cmd = 'docker images --format "{{.Repository}}" | grep -q superlink'

        @info[:vm].ssh(cmd).expect_success
    end

    # Verify the Flower appliance directory exists
    it 'flower directory exists' do
        cmd = 'test -d /opt/flower'

        @info[:vm].ssh(cmd).expect_success
    end

    # Verify the appliance lifecycle script is in place
    it 'appliance script is present' do
        cmd = 'test -f /etc/one-appliance/service.d/appliance.sh'

        @info[:vm].ssh(cmd).expect_success
    end

    # Check if the service framework from one-apps reports that the app is ready
    it 'check oneapps motd' do
        cmd = 'cat /etc/motd'

        max_retries = 24
        sleep_time = 10
        expected_motd = 'All set and ready to serve'

        execution = nil
        max_retries.times do |attempt|
            execution = @info[:vm].ssh(cmd)

            if execution.stdout.include?(expected_motd)
                break
            end

            puts "Attempt #{attempt + 1}/#{max_retries}: Waiting for MOTD to update..."
            sleep sleep_time
        end

        expect(execution.exitstatus).to eq(0)
        expect(execution.stdout).to include(expected_motd)
    end
end
