#! /bin/bash

iface1=ens3f0
iface2=ens3f1
#iface1=ens3f0
#iface2=ens3f1
cleanup()
{
	echo "========== do cleanup ==============="
	set -x

	ip netns pids S | xargs kill 2>/dev/null
	ip netns pids C | xargs kill 2>/dev/null

	ip netns exec S ip addr flush $iface1
	ip netns exec C ip addr flush $iface2
	ip netns del S
	ip netns del C

	sysctl fs.file-max=6485220 > /dev/null
	sysctl fs.nr_open=1048576 > /dev/null
	sysctl net.ipv4.tcp_syn_retries=6
	sysctl net.core.wmem_default=212992
	sysctl -w net.ipv4.tcp_mem="1529568 2039424 3059136"

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

add_ipaddrs() {
	ip netns add S
	ip netns add C
	ip link set $1 netns S || exit 1
	sleep 1
	ip link set $2 netns C || exit 1
	sleep 1

	ip -net S addr flush $1 || exit 1
	ip -net S addr add 10.0.1.99/24 dev $1
	ip -net S addr add 10.0.1.100/24 dev $1
	ip -net S addr add 10.0.1.101/24 dev $1
	ip -net S addr add 10.0.1.102/24 dev $1
	ip -net S addr add 10.0.1.103/24 dev $1
	ip -net S addr add 10.0.1.104/24 dev $1
	ip -net S addr add 10.0.1.105/24 dev $1
	ip -net S addr add 10.0.1.106/24 dev $1
	ip -net S addr add 10.0.1.107/24 dev $1
	ip -net S addr add 10.0.1.108/24 dev $1
	ip -net S addr add 10.0.1.109/24 dev $1
	ip -net S addr add 10.0.1.110/24 dev $1
	ip -net S addr add 10.0.1.111/24 dev $1
	ip -net S link set $1 up
	ip -net S route add default via 10.0.1.1 dev $1

	ip -net C addr flush $2 || exit 1
	ip -net C addr add 10.0.2.99/24 dev $2		
	ip -net C addr add 10.0.2.100/24 dev $2		
	ip -net C addr add 10.0.2.101/24 dev $2		
	ip -net C addr add 10.0.2.102/24 dev $2		
	ip -net C addr add 10.0.2.103/24 dev $2		
	ip -net C addr add 10.0.2.104/24 dev $2		
	ip -net C addr add 10.0.2.105/24 dev $2		
	ip -net C addr add 10.0.2.106/24 dev $2		
	ip -net C addr add 10.0.2.107/24 dev $2		
	ip -net C addr add 10.0.2.108/24 dev $2		
	ip -net C addr add 10.0.2.109/24 dev $2		
	ip -net C addr add 10.0.2.110/24 dev $2		
	ip -net C addr add 10.0.2.111/24 dev $2		
	ip -net C link set $2 up
	ip -net C route add default via 10.0.2.1 dev $2
	while ! ip netns exec S ping 10.0.2.101 -W 1 -c 1 > /dev/null
	do
		sleep 1
		continue
	done
	ip netns exec S ip a
	ip netns exec C ip a
}

sys_setting()
{
	sysctl -w fs.file-max=64852200 || exit 1;
	sysctl -w fs.nr_open=$(sysctl -n fs.file-max) || exit 1;
	sysctl -w net.ipv4.tcp_syn_retries=6

	ip netns exec S sysctl -w net.ipv4.tcp_rmem="4096 87380 16777216"
	ip netns exec C sysctl -w net.ipv4.tcp_rmem="4096 87380 16777216"
	ip netns exec S sysctl -w net.ipv4.tcp_wmem="4096 16384 16777216"
	ip netns exec C sysctl -w net.ipv4.tcp_wmem="4096 16384 16777216"
	sysctl -w net.core.wmem_default=21299200
	sysctl -w net.ipv4.tcp_mem="786432 2097152 314572800"



	echo "++++++++++++++++  System info  ++++++++++++++++++++++++++++++"
	echo "nf_conntrack"
	sysctl -a | grep conntrack
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
	gcc server_tcp.c -o server -l pthread || exit 1
	gcc client_tcp.c -o client -l pthread || exit 1
}

run_tool()
{
#	ip netns exec S iperf3 -s -B 10.0.1.99 -D
#	ip netns exec C iperf3 -c 10.0.1.99 -t 0 --cport 8888 --forceflush &
#	sleep 3

	# 1 thread
#	ip netns exec S ./server -H 10.0.1.100 -P 1001-1500 &
#	ip netns exec C ./client -H 10.0.1.100 -P 1001-1500 -h 10.0.2.101,10.0.2.102,10.0.2.103,10.0.2.104,10.0.2.105 -p "50001-60000" &

	# 6 threads
#	ip netns exec S ./server -H 10.0.1.100,10.0.1.101,10.0.1.102,10.0.1.103,10.0.1.104,10.0.1.105 -P 1001-1500 &
#	ip netns exec C ./client -H 10.0.1.100,10.0.1.101,10.0.1.102,10.0.1.103,10.0.1.104,10.0.1.105 -P 1001-1500 -h 10.0.2.101,10.0.2.102,10.0.2.103,10.0.2.104,10.0.2.105 -p "50001-60000" &

	# 12 threads
	ip netns exec S ./server -H \
		10.0.1.100,10.0.1.101,10.0.1.102,10.0.1.103,10.0.1.104,10.0.1.105,10.0.1.106,10.0.1.107,10.0.1.108,10.0.1.109,10.0.1.110,10.0.1.111\
	       	-P 1001-1500 &
	ip netns exec C ./client -H \
		10.0.1.100,10.0.1.101,10.0.1.102,10.0.1.103,10.0.1.104,10.0.1.105,10.0.1.106,10.0.1.107,10.0.1.108,10.0.1.109,10.0.1.110,10.0.1.111\
		-P 1001-1500\
	       	-h 10.0.2.101,10.0.2.102,10.0.2.103,10.0.2.104,10.0.2.105\
		-p 50001-60000 &
}

set -x
install
add_ipaddrs $iface1 $iface2
sys_setting
run_tool
set +x
wait
