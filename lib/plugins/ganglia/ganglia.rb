=begin rdoc

== Overview
Install Ganglia cloud monitoring system

== Requirements
You'll need apache and php enabled in your clouds.rb. For example:

    apache do
      has_php do
        extras :gd
      end
    end

Because the configs need to know about every node in the cloud *after* it has
launched, you must setup an after_all_loaded block in your clouds.rb that calls
ganglia.perform_after_all_loaded_for_master. For example:

  after_all_loaded do
    clouds['hadoop_master'].run_in_context do
      ganglia.perform_after_all_loaded_for_master
    end
  end

Currently the tasks only need to be run for master, so simply call this on your
"master" cloud. Note: replace hadoop_master with the name of your cloud above.

== EC2 Firewall

ec2-authorize -P udp -p 8649 nmurray-hadoop
ec2-authorize -P tcp -p 8649 nmurray-hadoop

== References
* http://www.ibm.com/developerworks/wikis/display/WikiPtype/ganglia?decorator=printable
* http://docs.google.com/Doc?id=dgmmft5s_45hr7hmggr
* http://www.hps.com/~tpg/notebook/ganglia.php
* http://www.cultofgary.com/2008/10/16/ec2-and-ganglia/
=end

PoolParty::Resources::FileResource.searchable_paths << File.dirname(__FILE__)+'/templates/'

module PoolParty
  module Resources
    class Ganglia < Resource
      def before_load(o={}, &block)
        @monitored_features ||= {}
        do_once do
          install_dependencies
          download
        end
      end

      def install_dependencies
        has_package :name => "rrdtool"
        has_package :name => "build-essential"
        has_package :name => "librrd-dev" 
        has_package :name => "libapr1-dev"
        has_package :name => "libconfuse-dev"
        has_package :name => "libexpat1-dev"
        has_package :name => "python-dev"

        has_group "ganglia", :action => :create
        has_user "ganglia", :gid => "ganglia", :requires => get_group("ganglia")
 
        # libart-2.0-2 ?
      end

      def download
        has_exec "wget http://superb-west.dl.sourceforge.net/sourceforge/ganglia/ganglia-3.1.2.tar.gz -O /usr/local/src/ganglia-3.1.2.tar.gz",
          :not_if => "test -e /usr/local/src/ganglia-3.1.2.tar.gz"
        has_exec "cd /usr/local/src && tar -xvvf /usr/local/src/ganglia-3.1.2.tar.gz",
          :not_if => "test -e /usr/local/src/ganglia-3.1.2"
      end

      def master
        has_exec "cd /usr/local/src/ganglia-3.1.2 && ./configure --with-gmetad && make && make install",
          :not_if => "test -e /usr/lib/ganglia"
        has_exec "mv /usr/local/src/ganglia-3.1.2/web /var/www/ganglia",
          :not_if => "test -e /var/www/ganglia"
        has_file :name => "/var/www/ganglia/conf.php", :mode => "0644", :template => "ganglia-web-conf.php.erb"
        has_master_cloud cloud.name # our master is ourself
        has_variable "ganglia_gmond_is_master", true
        gmond
        gmetad
        
        # 
        perform_after_all_loaded_for_master
      end

      def slave
        has_exec "cd /usr/local/src/ganglia-3.1.2 && ./configure && make && make install",
          :not_if => "test -e /usr/lib/ganglia"
        has_variable "ganglia_gmond_is_master", false
        gmond
        # 
        perform_after_all_loaded_for_slave
      end

      def gmond
        has_directory "/etc/ganglia"
        has_exec({:name => "restart-gmond", :command => "/etc/init.d/gmond restart", :action => :nothing})

        has_file(:name => "/etc/init.d/gmond") do
          mode 0755
          template :bin/"gmond.erb"
          notifies get_exec("restart-gmond"), :run
        end

        install_extra_gmond_monitors
      end

      def gmetad
        has_directory "/var/lib/ganglia/rrds"
        has_exec "chmod 755 /var/lib/ganglia/rrds"
        has_exec "chown -R ganglia:ganglia /var/lib/ganglia/rrds"
        has_exec({:name => "restart-gmetad", :command => "/etc/init.d/gmetad restart", :action => :nothing})
        has_file(:name => "/etc/init.d/gmetad") do
          mode 0755
          template :bin/"gmetad.erb"
          notifies get_exec("restart-gmetad"), :run
        end
      end

      def monitor(*cloud_names)
        monitored_clouds << cloud_names
      end
      
      def monitored_clouds
        @monitored_clouds ||= []
      end

      def perform_after_all_loaded_for_slave
        gmond_after_all_loaded
      end

      def perform_after_all_loaded_for_master
        raise "No clouds to monitor with ganglia specified. Please use the 'monitor(*cloud_names)' directive within your ganglia block" unless @monitored_clouds
        gmond_after_all_loaded

        data_sources = ""
        @monitored_clouds.each do |cloud_name|
          line = "data_source \\\"#{cloud_name}\\\" "
          ips = []
          if clouds[cloud.name]
            clouds[cloud.name].nodes(:status => 'running').each_with_index do |n, i|
              ips << (n[:private_dns_name] || n[:ip]) + ":8649" # todo - what if we used master0, slave0 etc here?
            end
          end
          data_sources << (line + ips.join(" ") + "\n")
        end
        data_sources.gsub!(/\n/, '\n')

        has_variable "ganglia_gmetad_data_sources", data_sources

        # poolname = clouds.values.first.pool.name
        # has_variable "ganglia_pool_name", :value => (poolname && !poolname.empty? ? poolname : "pool")
        has_variable "ganglia_pool_name", "pool"

        has_exec(:name => "restart_gmetad2", :command => "/etc/init.d/gmetad restart", :action => :nothing) #  HACK this is already defined!, todo
        has_file "/etc/ganglia/gmetad.conf" do
          mode 644
          template "gmetad.conf.erb"
          notifies get_exec("restart_gmetad2"), :run
        end
        has_service "gmetad", :enabled => true, :running => true, :supports => [:restart]
      end

      def track(*features)
        @monitored_features ||= {}
        features.map {|f| @monitored_features[f] = true }
      end

      def gmond_after_all_loaded
        has_variable "ganglia_cloud_name", cloud.name
        has_variable "ganglia_this_nodes_private_ip", lambda{ %Q{%x[curl http://169.254.169.254/latest/meta-data/local-ipv4]}}

        master_cloud_node = clouds[@master_cloud_name].nodes(:status => 'running').first
        has_variable "ganglia_masters_ip", lambda { %Q{\`ping -c1 #{master_cloud_node[:private_dns_name]} | grep PING | awk -F '[()]' '{print $2 }'\`.strip}}

        first_node = clouds[cloud.name].nodes(:status => 'running').first
        if first_node
          has_variable "ganglia_first_node_in_clusters_ip", lambda { %Q{\`ping -c1  #{first_node[:private_dns_name]} | grep PING | awk -F '[()]' '{print $2 }'\`.strip}}

          has_file(:name => "/etc/ganglia/gmond.conf") do
            mode 0644
            template "gmond.conf.erb"
            # notifies get_exec("restart-gmond"), :run
          end

          enable_tracking_configs

        end
        has_service "gmond", :enabled => true, :running => true, :supports => [:restart]

      end

      def enable_tracking_configs
        if @monitored_features[:hadoop]
          has_variable "hadoop_ganglia_monitoring_enabled", true
          
          # hmm, should maybe be mvd to hadoop plugin?
          has_file(:name => "/usr/local/hadoop/conf/hadoop-metrics.properties") do
            mode 0644
            template "hadoop-metrics.properties.erb"
          end
        end
      end

      def install_extra_gmond_monitors
        has_directory(:name => "/etc/ganglia/bin/monitors")
        %w{sshd_ganglia}.each do |monitor|
          has_file(:name => "/etc/ganglia/bin/monitors/#{monitor}") do
            mode 0755
            template "bin/monitors/#{monitor}.sh"
          end
          has_cron( :name => "ganglia_monitor_#{monitor}",
                    :command => "bash -c /etc/ganglia/bin/monitors/#{monitor}",
                    :user => "root",
                    :minute => "*/5",
                    :hour => "*",
                    :month => "*",
                    :weekday => "*")
        end
      end

      def has_master_cloud(cloud_name)
        @master_cloud_name = cloud_name.to_s
      end

      # todo, add a verifier
      # telnet localhost 8649

      # a bit of a hack, only use if needed, eventually should read if needed
      def install_jaunty_sources
        has_exec("apt-get update", :action => :nothing)

        lines =<<-EOF
deb http://archive.ubuntu.com/ubuntu/ jaunty main restricted
deb http://archive.ubuntu.com/ubuntu/ jaunty universe
deb http://archive.ubuntu.com/ubuntu/ jaunty multiverse
deb-src http://archive.ubuntu.com/ubuntu/ jaunty main restricted
deb-src http://archive.ubuntu.com/ubuntu/ jaunty universe
deb-src http://archive.ubuntu.com/ubuntu/ jaunty multiverse
EOF
        lines.each_line do |l|
           has_line_in_file do 
             file "/etc/apt/sources.list"
             line l 
             notifies get_exec("apt-get update"), :run
           end
        end
      end


    end
  end
end


