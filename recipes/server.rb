#
# Cookbook Name:: zabbix_lwrp
# Recipe:: server
#
# Copyright (C) LLC 2015-2017 Express 42
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of
# this software and associated documentation files (the "Software"), to deal in
# the Software without restriction, including without limitation the rights to
# use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
# of the Software, and to permit persons to whom the Software is furnished to do
# so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

server_type = node['zabbix']['server']['config']['server_type']
if server_type.nil? || server_type.empty? || server_type == 'server' ? false : server_type == 'proxy' ? false : true
  Chef::Application.fatal!("node['zabbix']['server']['config']['server_type'] must be 'server' or 'proxy'")
end
db_vendor = node['zabbix']['server']['database']['vendor']
unless db_vendor == 'postgresql' || db_vendor == 'mysql'
  raise "You should specify correct database vendor attribute node['zabbix']['server']['database']['vendor'] (now: #{node['zabbix']['server']['database']['vendor']})"
end

def configuration_hacks(configuration, server_version, server_type)
  configuration['cache'].delete('HistoryTextCacheSize') if server_version.to_f >= 3.0
  configuration.delete('SenderFrequency') if server_version.to_f >= 3.4

  case server_type
    when 'proxy'
      configuration['cache'].delete('TrendCacheSize') if server_version.to_f >= 3.4
      configuration['cache'].delete('ValueCacheSize') if server_version.to_f >= 3.4
      configuration['cache'].delete('CacheUpdateFrequency') if server_version.to_f >= 3.4
      configuration['cache'].delete('HistoryCacheSize') if server_version.to_f >= 3.4
      configuration['cache'].delete('HistoryIndexCacheSize') if server_version.to_f >= 3.4
      configuration['workers'].delete('StartProxyPollers') if server_version.to_f >= 3.4
      configuration['hk'].delete('MaxHousekeeperDelete') if server_version.to_f >= 3.4
  end
end

sql_attr = node['zabbix']['server']['database'][db_vendor]
db_name = 'zabbix'

db_host = sql_attr['configuration']['listen_addresses']
db_port = sql_attr['configuration']['port']

# Get user and database information from data bag

if sql_attr['databag'].nil? ||
   sql_attr['databag'].empty? ||
   get_data_bag(sql_attr['databag']).empty?
  raise "You should specify databag name for zabbix db user in node['zabbix']['server']['database'][db_vendor]['databag'] attibute (now: #{sql_attr['databag']}) and databag should exist"
end

db_user_data = get_data_bag_item(sql_attr['databag'], 'users')['users']
db_user = db_vendor == 'postgresql' ? db_user_data.keys.first : 'zabbix'
db_pass = db_user_data[db_user]['options']['password']

# Generate DB config

db_config = {
  db: {
    DBName: db_name,
    DBPassword: db_pass,
    DBUser: db_user,
    DBHost: db_host,
    DBPort: db_port,
  },
}

# Install packages

case node['platform_family']
when 'debian'
  package db_vendor == 'postgresql' ? "zabbix-#{server_type}-pgsql" : "zabbix-#{server_type}-mysql" do
    response_file 'zabbix-server-withoutdb.seed'
    action [:install, :reconfig]
  end

  package 'snmp-mibs-downloader'

when 'rhel'
  package db_vendor == 'postgresql' ? "zabbix-#{server_type}-pgsql" : "zabbix-#{server_type}-mysql" do
    action [:install, :reconfig]
  end
end

if server_type == 'proxy'
  mysql_attr = node['zabbix']['server']['database']['mysql']
  db_name = mysql_attr['database_name']
  db_connect_string = "mysql -h #{mysql_attr['configuration']['listen_addresses']} \
                       -P #{mysql_attr['configuration']['port']} -u root \
                       -p#{get_data_bag_item(mysql_attr['databag'], 'users')['users']['root']['options']['password']}"

  execute 'Create Zabbix MySQL database' do
    command "#{db_connect_string} -e \"create database if not exists #{db_name} \
             character set #{mysql_attr['configuration']['character_set']} \
             collate #{mysql_attr['configuration']['collate']}\" "
    sensitive true
    action :run
  end

  # create users
  get_data_bag_item(mysql_attr['databag'], 'users')['users'].each_pair do |name, options|
    execute "Create MySQL database user #{name}" do
      only_if { name != 'root' }
      command "#{db_connect_string} -e \"grant all privileges on #{db_name}.* to '#{name}'@'%' identified by '#{options['options']['password']}'; \""
      action :run
      sensitive true
    end
  end
end

zabbix_database db_name do
  db_vendor db_vendor
  db_user   db_user
  db_pass   db_pass
  db_host   db_host
  db_port   db_port
  server_type server_type
  action :create
end

directory node['zabbix']['server']['templates'] do
  recursive true
  owner 'root'
  group 'root'
end

service node['zabbix']['server']['service'] do
  supports restart: true, status: true, reload: true
  action [:enable]
end

configuration = Chef::Mixin::DeepMerge.merge(node['zabbix']['server']['config'].to_hash, db_config)

configuration_hacks(configuration, node['zabbix']['version'], server_type)

template "/etc/zabbix/zabbix_#{server_type}.conf" do
  source 'zabbix-server.conf.erb'
  owner 'root'
  group 'root'
  mode '0640'
  sensitive true
  variables(configuration)
  notifies :restart, "service[#{node['zabbix']['server']['service']}]", :immediately
end
