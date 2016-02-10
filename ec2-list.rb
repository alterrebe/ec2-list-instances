require 'aws-sdk'
require 'colorize'
require 'io/console'
require 'ipaddr'
require 'optparse'

# Don't print esc-sequences when output to file 
unless $stdout.tty?
  String.disable_colorization = true
end

# Lookup "Name" tag and return its value
def getName(tags)
  name_tag = tags.find { |tag| tag.key == "Name" }
  name_tag ? name_tag.value : nil
end

# Print a text into a field of specified size
def echo(text, fill, default='')
  text = default unless text
  (text.length > fill) ? text[0, fill] : text.ljust(fill, ' ')
end

# Utility functions to print IP addresses and VPC/Subnet names:
def echo_ip(ip) echo(ip ? ip.to_s : nil, 16, '-- dynamic --') end
def echo_name(name, fill = 24) echo(name, fill, '-- Unnamed --') end

# IP address factory
def make_ip(ip) ip ? IPAddr.new(ip) : nil end

# Instance dictionary factory
def make_instance(i)
  { id: i.instance_id, name: getName(i.tags), state: i.state.name, arch: i.architecture, launched: i.launch_time,
    reason: (i.state_transition_reason and i.state_transition_reason.length > 0 ? i.state_transition_reason : nil), 
    ec2_class: i.instance_type, private_ip: make_ip(i.private_ip_address), public_ip: make_ip(i.public_ip_address), 
    windows: i.platform == 'windows', spot: i.instance_lifecycle == 'spot', monitoring: i.monitoring.state == 'enabled',
    sec_groups: i.security_groups.map {|g| g.group_name} .join(', '), key_pair: i.key_name, ami: i.image_id,
    virtualization_type: i.virtualization_type     
  }
end

# Get details about a specific instance
def get_ec2_details(instance_id)
  # Get the data
  ec2 = Aws::EC2::Client.new()
  begin
    res = ec2.describe_instances({instance_ids:[instance_id]})
  rescue
    puts "Can't found an EC2 instance with given ID: #{instance_id}"
    exit
  end
  i =  res.reservations[0].instances[0]
  instance = make_instance( i )

  begin
    res = ec2.describe_image_attribute({image_id: i.image_id, attribute: "description"})
    instance[:ami_desc] = res.description.value
  rescue
    instance[:ami_desc] = '-- unavailable as of now --'
  end

  if i.vpc_id
    instance[:vpc] = getName( ec2.describe_vpcs({vpc_ids:[i.vpc_id]}).vpcs[0].tags )
    instance[:subnet] = getName( ec2.describe_subnets({subnet_ids:[i.subnet_id]}).subnets[0].tags )
  end

  instance
end

# Print details about a specific instance
def print_details(inst)
  print "ID: ".bold, inst[:id], "   Name: ".bold, inst[:name], "   State: ".bold, inst[:state]
  if inst[:state] == 'running'
    print ", launched at #{inst[:launched]}"
  elsif inst[:reason]
    print " via #{inst[:reason]}"
  end
  puts

  if inst[:vpc]
    print "VPC: ".bold, inst[:vpc], "   Subnet: ".bold, inst[:subnet]
  else
    print "EC2 Classic".bold
  end
  print "   Private IP: ".bold, echo_ip( inst[:private_ip] )
  if inst[:vpc] and not inst[:private_ip]
    print "   Public IP is not allocated".bold
  else
    print "   Public IP: ".bold, echo_ip( inst[:public_ip] )
  end
  puts

  print "EC2 Class: ".bold, inst[:ec2_class], " [#{inst[:virtualization_type]}]", "   Arch: ".bold, inst[:arch]
  print "   [Spot]".bold if inst[:spot]
  print "   [Monitoring]".bold if inst[:monitoring]
  if inst[:windows]
    print "   [Windows]".bold
  else
    print "   Keypair: ".bold, inst[:key_pair]
  end
  puts

  print "AMI: ".bold, inst[:ami], "  (#{inst[:ami_desc]})"
  puts

  print "Security Groups: ".bold, inst[:sec_groups]
  puts
end

options = { }
OptionParser.new do |opts|
  opts.banner = "Usage:".bold + " ec2-list.rb [options]\n\n" + 
    "When no options given the script prints information about all the instances.\n" +
    "Flags meaning: " + "W".bold + " - Windows, " + "S".bold + " - spot instance, " + "I".bold + 
    " - internal (i.e. having no public IP), " + "M".bold + " - monitoring enabled\n\n"
    "Options:".bold
  opts.on("-s NAME", "--search NAME", "Limit the list by instances with names matching the given regexp (case-insensitive)") { |v| options[:name_regex] = Regexp.new(v, true) }
  opts.on("-i ID",   "--instance ID", "Print details about instance with given ID") { |v| options[:instance_id] = v }
  opts.on("-A ACCESS_KEY", "--access-key ACCESS_KEY", "Specify AWS access key (or define AWS_ACCESS_KEY environment variable)") { |v| ENV['AWS_ACCESS_KEY'] = v } 
  opts.on("-S SECRET_KEY", "--secret-key SECRET_KEY", "Specify AWS secret key (or define AWS_SECRET_ACCESS_KEY environment variable)") { |v| ENV['AWS_SECRET_ACCESS_KEY'] = v } 
  opts.on("-R REGION", "--region REGION", "Specify AWS region to use (or define AWS_REGION environment variable)") { |v| ENV['AWS_REGION'] = v }
end.parse!

ENV['AWS_REGION'] = 'us-east-1' unless ENV.has_key?('AWS_REGION')

if options.has_key? :instance_id
  puts
  print_details( get_ec2_details( options[:instance_id] ) ) 
  exit
end

# Collecting a list of instances:

ec2 = Aws::EC2::Client.new()

# Print fancy state indicator:
def echoState(state)
  if String.disable_colorization
    case state
      when 'running' then '+ ' 
      when 'stopped' then '- '
      when 'terminated' then 'X '
      when 'pending' then 'O '
      when 'shutting-down' then '\\_'
      when 'stopping' then '~-'
      else '??'
    end
  else
    case state
      when 'running' then '✅ ' 
      when 'stopped' then '❙❙'
      when 'terminated' then '⚫ '
      when 'pending' then '⚪ '
      when 'shutting-down' then '♺ '
      when 'stopping' then '⌛ '
      else '??'
    end
  end
end

AVAILABLE_STATE_FILTER={ name:"state", values: [ "available" ] }

vpcs={}
ec2.describe_vpcs( {filters:[AVAILABLE_STATE_FILTER]} ).vpcs.each do |vpc|
#  puts "VPC: #{getName(vpc.tags)} (#{vpc.vpc_id}) CIDR: #{vpc.cidr_block}"
  vpcs[ vpc.vpc_id ] = { name: getName(vpc.tags), cidr: vpc.cidr_block, subnets: {} }
end


ec2.describe_subnets( {filters:[AVAILABLE_STATE_FILTER]} ).subnets.each do |sn|
#  puts "Subnet: #{getName(sn.tags)} (#{sn.subnet_id})/#{sn.vpc_id}) #{sn.state} #{sn.availability_zone}"
  vpc = vpcs[ sn.vpc_id ]
  vpc[:subnets][ sn.subnet_id ] = { name: getName(sn.tags), zone: sn.availability_zone, cidr: sn.cidr_block, instances: [] }
end

ec2_classic = []

instances = ec2.describe_instances().reservations.map { |r| r.instances } .flatten
instances.each do |i|
  instance_name = getName(i.tags)
  next if options[:name_regex] and not options[:name_regex] =~ instance_name
  inst = { id: i.instance_id, state: i.state.name, ec2_class: i.instance_type, launched: i.launch_time, type: i.virtualization_type,
	   name: instance_name, private_ip: make_ip(i.private_ip_address), public_ip: make_ip(i.public_ip_address), arch: i.architecture, 
	   windows: i.platform == 'windows', spot: i.instance_lifecycle == 'spot', monitoring: i.monitoring.state == 'enabled' }
  if i.vpc_id
    vpc = vpcs[ i.vpc_id ]
    sn = vpc[:subnets][ i.subnet_id ]
    sn[:instances] << inst
  else
    ec2_classic << inst
  end
end

def echo_instance(i, is_vpc)
  ip_to_print = is_vpc ? i[:private_ip] : i[:public_ip]

          print "#{echoState(i[:state])} "
          print "#{echo_ip(ip_to_print)} "
          print "#{echo_name(i[:name], 40)} #{echo(i[:ec2_class],12)}"          

          flags = i[:windows] ? 'W'.bold : ' '
          flags << (i[:spot] ? 'S'.bold : ' ')
          flags << (i[:monitoring] ? 'M'.bold : ' ')
          if is_vpc and i[:state] == 'running' and i[:public_ip].nil?
            flags << 'I'.bold
          else
            flags << ' '
          end
          print " #{flags} "

          if is_vpc
            print echo_ip(i[:public_ip])
          else
            print echo(i[:arch], 6)
          end
          puts "  #{i[:id]}"
end

vpcs = vpcs.sort_by { |id, vpc| vpc[:cidr] }.each do |ve| 
  vpc = ve[1]
  if vpc[:subnets].map { |_,sn| sn[:instances].length } .reduce(:+) > 0
    vpc[:subnets].sort_by { |id, sn| sn[:cidr] }.each do |se|
      subnet = se[1]
      if subnet[:instances].length > 0
        print "\n----- VPC: ".bold, echo_name(vpc[:name]), "  Subnet: ".bold, echo_name(subnet[:name])
        print "   #{subnet[:cidr]} - #{subnet[:zone]} "
        puts "-----".bold
	      subnet[:instances].sort_by{ |i| i[:private_ip] } .each do |i|
          echo_instance(i, true)
        end
      end
    end
  end
end

if ec2_classic.length > 0
  puts "\n----- EC2 Classic --------------------------------------------------------------------------------------".bold
  ec2_classic.sort_by{ |i| i[:name] ? i[:name] : '' } .each do |i|
          echo_instance(i, false)
  end
end
