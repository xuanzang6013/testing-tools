# /bin/bash

# This script crate huge amount of tcp connections to test
# connection  tracking subsystem in linux kernel.
# The sigle iperf3 tcp stream can reflect conntrack hash matching speed.
# Print `conntrack -C` at intervals reflect the entry creating rate.
#
#
# Author: Chen Yi <yiche@redhat.com>
# License: GPLv2


cleanup()
{
	echo "========== do cleanup ==============="
	set -x
	ip netns pids S | xargs kill 2>/dev/null
	ip netns pids C | xargs kill 2>/dev/null
	ip netns del S
	ip netns del C
	ip netns del F

	sysctl fs.file-max=6485220 > /dev/null
	sysctl fs.nr_open=1048576 > /dev/null
	sysctl net.ipv4.tcp_syn_retries=6
	rmmodule nf_conntrack
}
trap cleanup EXIT

rmmodule()
{
        local module=$1
        modprobe -q -r $module && return 0
        test -e /sys/module/$module || { echo "Module $module not found.";return 1; }
        local holders=`ls /sys/module/$module/holders/`
        for item in $holders;do
                rmmodule $item
        done
        modprobe -q -r $module
}

create_topo()
{
	# Veth Setting
	ip netns add F # Forward
	ip netns add S # Server
	ip netns add C # Client

	ip link add name s_f netns S type veth peer name f_s netns F
	ip link add name c_f netns C type veth peer name f_c netns F
	ip -net S link set s_f up
	ip -net C link set c_f up
	ip -net F link set f_s up
	ip -net F link set f_c up

	ip netns exec S ethtool -K s_f tso off
	ip netns exec C ethtool -K c_f tso off

	ip -net S link set lo up
	ip -net C link set lo up
	ip -net F link set lo up

	ip -net S link set s_f mtu 1500
	ip -net C link set c_f mtu 1500
	ip -net F link set f_s mtu 1500
	ip -net F link set f_s mtu 1500

	# IPv4 Setting
	ip netns exec F sysctl net.ipv4.conf.all.forwarding=1

	ip -net F addr add 10.0.1.1/24 dev f_s
	ip -net F addr add 10.0.2.1/24 dev f_c

	ip -net S addr add 10.0.1.99/24 dev s_f
	ip -net C addr add 10.0.2.99/24 dev c_f
	ip -net S route add default via 10.0.1.1
	ip -net C route add default via 10.0.2.1

	ip netns exec C ping 10.0.1.99 -i 0.3 -c 3 || exit 1


	# IPv6 Setting
	ip netns exec F sysctl net.ipv6.conf.all.forwarding=1

	ip -net F addr add 2000::a/64 dev f_s nodad
	ip -net F addr add 2001::a/64 dev f_c nodad

	ip -net S addr add 2000::1/64 dev s_f nodad
	ip -net C addr add 2001::1/64 dev c_f nodad
	ip -net S route add default via 2000::a dev s_f
	ip -net C route add default via 2001::a dev c_f

	until ip netns exec C ping -6 2000::1 -c 1 -W 1
	do
		sleep 1
	done

	sysctl -w net.netfilter.nf_log_all_netns=1
}

add_ipaddrs()
{
	ip -net S addr add 10.0.1.100/24 dev s_f
	ip -net S addr add 10.0.1.101/24 dev s_f
	ip -net S addr add 10.0.1.102/24 dev s_f
	ip -net S addr add 10.0.1.103/24 dev s_f
	ip -net S addr add 10.0.1.104/24 dev s_f
	ip -net S addr add 10.0.1.105/24 dev s_f

	ip -net C addr add 10.0.2.100/24 dev c_f
	ip -net C addr add 10.0.2.101/24 dev c_f
	ip -net C addr add 10.0.2.102/24 dev c_f
	ip -net C addr add 10.0.2.103/24 dev c_f
	ip -net C addr add 10.0.2.104/24 dev c_f
	ip -net C addr add 10.0.2.105/24 dev c_f

	ip -net S addr add 2000::100/64 dev s_f nodad
	ip -net S addr add 2000::101/64 dev s_f nodad
	ip -net S addr add 2000::102/64 dev s_f nodad
	ip -net S addr add 2000::103/64 dev s_f nodad
	ip -net S addr add 2000::104/64 dev s_f nodad
	ip -net S addr add 2000::105/64 dev s_f nodad

	ip -net C addr add 2001::100/64 dev c_f nodad
	ip -net C addr add 2001::101/64 dev c_f nodad
	ip -net C addr add 2001::102/64 dev c_f nodad
	ip -net C addr add 2001::103/64 dev c_f nodad
	ip -net C addr add 2001::104/64 dev c_f nodad
	ip -net C addr add 2001::105/64 dev c_f nodad
}
enable_conntrack()
{
	# Active conntrack
	if modinfo nf_conntrack |grep -q enable_hooks
	then
		modprobe nf_conntrack enable_hooks=1
	else
		nft add table t
		nft add chain t c
		nft add t c ct state new
	fi

	#sysctl -w net.nf_conntrack_max=5001000
	sysctl -w net.nf_conntrack_max=10001000
	sysctl -w net.netfilter.nf_conntrack_buckets=$((`sysctl -n net.nf_conntrack_max`* 2))
	#sysctl -w net.netfilter.nf_conntrack_buckets=8000000

	for n in S C F
	do
		ip netns exec $n sysctl -w net.netfilter.nf_conntrack_tcp_timeout_time_wait=5
		ip netns exec $n sysctl -w net.netfilter.nf_conntrack_tcp_timeout_close_wait=5
		ip netns exec $n sysctl -w net.netfilter.nf_conntrack_tcp_timeout_fin_wait=5

	done
}


sys_setting()
{

	sysctl -w fs.file-max=64852200 || exit 1;
	sysctl -w fs.nr_open=$(sysctl -n fs.file-max) || exit 1;
	sysctl -w net.ipv4.tcp_syn_retries=1
	sysctl net.ipv4.ip_local_port_range

	echo "++++++++++++++++  System info  ++++++++++++++++++++++++++++++"
	echo "nf_conntrack"
	sysctl -a | grep conntrack
	echo "uname -a"
	uname -a
	echo "sysctl fs.nr_open"
	sysctl fs.nr_open
	echo "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"

	return 0;
}

install()
{
	rpm -q conntrack-tools || dnf -y install conntrack-tools
	rpm -q iperf3 || dnf -y install iperf3
	rpm -q gcc || dnf -y install gcc
	gcc server.c -o server -l pthread || exit 1
	gcc client.c -o client -l pthread || exit 1
}

watching()
{
	while true
	do
		ip netns exec F conntrack -C
		tail -5 server.log
		sleep 5
	done
}

run_test()
{
	# Prefer big "-p value".(client port is the Outermost Loop in code)

#	ip netns exec S iperf3 -s -B 10.0.1.99 -D
#	ip netns exec C iperf3 -c 10.0.1.99 -t 0 --cport 8888 --forceflush &
#	sleep 3

	# IPv4
	# 4×500×5×500 = 5000000 entries, could eat nearly 40Gi RAM.
	# 1 thread
#	ip netns exec S ./server -t -H 10.0.1.100 -P 1001-1500 &
#	ip netns exec C ./client -t -H 10.0.1.100 -P 1001-1500 -h 10.0.2.101,10.0.2.102,10.0.2.103,10.0.2.104,10.0.2.105 -p "50001-60000" &

	# 6 threads
#	ip netns exec S ./server -t -H 10.0.1.100,10.0.1.101,10.0.1.102,10.0.1.103,10.0.1.104,10.0.1.105 -P 1001-1500 &
#	ip netns exec C ./client -t -H 10.0.1.100,10.0.1.101,10.0.1.102,10.0.1.103,10.0.1.104,10.0.1.105 -P 1001-1500 \
#				    -h 10.0.2.101,10.0.2.102,10.0.2.103,10.0.2.104,10.0.2.105\
#				    -p 50001-60000 &



	# IPv6
	# 1 thread
#	ip netns exec S ./server -t -H 2000::100 -P 1001-1500 &
#	ip netns exec C ./client -t -H 2000::100 -P 1001-1500 -h 2001::100,2001::101,2001::102,2001::103,2001::104,2001::105 -p 50001-60000 &

	# 6 threads
	ip netns exec S ./server -t -H 2000::100,2000::101,2000::102,2000::103,2000::104,2000::105 -P 1001-1500 &
	ip netns exec C ./client -t -H 2000::100,2000::101,2000::102,2000::103,2000::104,2000::105 -P 1001-1500 -h 2001::100,2001::101,2001::102,2001::103,2001::104,2001::105 -p 50001-60000 &





	#ip netns exec S netserver
	#ip netns exec C netperf -4 -L 10.0.2.103 -H 10.0.1.103 -t TCP_CRR -l 100000 &
	#sleep 5

}

set -x
install
create_topo
add_ipaddrs
test -z $1 && enable_conntrack
sys_setting
run_test
#watching &
set +x
wait
