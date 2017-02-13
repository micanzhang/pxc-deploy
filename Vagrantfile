#
# vim: ft=ruby
#

require "securerandom"
require "optparse"

options = {}
options[:num] = 3

if ENV.key?("PXC_CLUSTER_NUM")
  options[:num] = ENV["PXC_CLUSTER_NUM"].to_i
  num_choices = [1,3,5,7,9]
  if not num_choices.include? options[:num] then
    puts "ERROR: num should be one of %s, not %s" % [num_choices, options[:num]]
    exit 1
  end
end
puts "cluster num: %s" % [options[:num]]

Vagrant.configure('2') do |config|
  config.vm.box = "ubuntu/trusty64"
  config.vm.box_url = "http://7xi4st.com1.z0.glb.clouddn.com/trusty-server-cloudimg-amd64-vagrant-disk1.box"
  config.vm.box_check_update = false

  config.vm.provision :shell, :path => "./provision/common.sh"

  config.vm.define :ha do |ha|
    ha.vm.hostname = "ha.local.dev"
    # And this will let you hit 127.0.0.1:3306 with your favorite mysql client -- each time going to a new node
    ha.vm.network "forwarded_port", guest: 3306, host: 3306
    # This will let you hit http://127.0.0.1:8080/haproxy/stats in your browser
    ha.vm.network "forwarded_port", guest: 4306, host: 4306
    ha.vm.network :private_network, ip: "192.168.10.10"
    ha.vm.provider :virtualbox do |vb|
      vb.customize ["modifyvm", :id, "--memory", "512"]
    end
    ha.vm.provision :shell, :path => "./provision/ha.sh"
  end

  # Setup MySQL nodes. (Max: 9)
  password = SecureRandom.uuid.upcase
  sst_password = SecureRandom.uuid.upcase
  (1..options[:num]).each do |i|
    config.vm.define "m#{i}" do |node|
      node.vm.hostname = "m#{i}.local.dev"
      ip = "192.168.10.2#{i}"
      node.vm.network :private_network, ip: ip
      node.vm.provider :virtualbox do |vb|
        vb.customize ["modifyvm", :id, "--memory", "512"]
      end
      node.vm.provision :shell, :path => "./provision/node.sh", :args => ["#{i}", ip, password, sst_password]
    end
  end
end
