#! /bin/bash
# SPDX-License-Identifier: GPL-2.0
# This script crate huge amount of tcp/udp/sctp ipv4/ipv6 connections
# to test/stress the connection tracking subsystem in linux kernel.
# Monitor one iperf3 stream to reflect conntrack hash matching perform
#

# Kselftest framework requirement - SKIP code is 4.
ksft_skip=4
sfx=$(mktemp -u "XXXXXXXX")

l3proto=(ipv4 ipv6)
l4proto=(tcp udp sctp)

L3=${l3proto[RANDOM%2]}
L4=${l4proto[RANDOM%3]}

usage(){
	echo ""
	echo "Usage:"
	echo "conntrack_stress.sh [-4/-6] [-t/-u/-s]"
	echo "   -4 ipv4"
	echo "   -6 ipv6"
	echo "   -t tcp"
	echo "   -u udp"
	echo "   -s sctp"
	exit 1
}

while getopts "46tus" o
do
	case $o in
		4) L3=ipv4;;
		6) L3=ipv6;;
		t) L4=tcp;;
		u) L4=udp;;
		s) L4=sctp; modprobe sctp || exit $ksft_skip;;
		*) usage;;
	esac
done

echo "*************************************************"
echo " L3proto: $L3, L4proto: $L4"
echo "*************************************************"

uname -a
free -h

cleanup()
{
	echo "------------cleanup--------------"
	ip netns pids $S 2> /dev/null| xargs kill >/dev/null 2>&1
	ip netns pids $C 2> /dev/null| xargs kill >/dev/null 2>&1
	ip netns del $S 2> /dev/null
	ip netns del $C 2> /dev/null
	ip netns del $F 2> /dev/null
	rm server-$sfx.log 2> /dev/null
	rm client-$sfx.log 2> /dev/null

	sysctl -q fs.file-max=${backup_file_max}
	sysctl -q fs.nr_open=${backup_nr_open}
	rmmodule nf_conntrack
	echo ""
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
	backup_file_max=$(sysctl -n fs.file-max)
	backup_nr_open=$(sysctl -n fs.nr_open)

	F="F-$sfx" # Forward
	S="S-$sfx" # Server
	C="C-$sfx" # Client

	# Veth Setting
	ip netns add $F
	ip netns add $S
	ip netns add $C

	ip link add name s_f netns $S type veth peer name f_s netns $F
	ip link add name c_f netns $C type veth peer name f_c netns $F
	ip -net $S link set s_f up
	ip -net $C link set c_f up
	ip -net $F link set f_s up
	ip -net $F link set f_c up

	ip netns exec $C ethtool -K c_f tso off
	ip netns exec $C ethtool -K c_f gso off
	ip netns exec $C ethtool -K c_f tx-sctp-segmentation off

	ip -net $S link set lo up
	ip -net $C link set lo up
	ip -net $F link set lo up

	ip -net $S link set s_f mtu 1500
	ip -net $C link set c_f mtu 1500
	ip -net $F link set f_s mtu 1500
	ip -net $F link set f_s mtu 1500

	# IPv4 Setting
	ip netns exec $F sysctl -q net.ipv4.conf.all.forwarding=1

	ip -net $F addr add 10.1.255.254/16 dev f_s
	ip -net $F addr add 10.2.255.254/16 dev f_c

	ip -net $S addr add 10.1.0.100/16 dev s_f
	ip -net $C addr add 10.2.0.100/16 dev c_f
	ip -net $S route add default via 10.1.255.254
	ip -net $C route add default via 10.2.255.254

	if ! ip netns exec $C ping 10.1.0.100 -i 0.3 -c 3 > /dev/null
	then
		echo "Topo init fail ipv4"
		exit 1
	fi

	# IPv6 Setting
	ip netns exec $F sysctl -q net.ipv6.conf.all.forwarding=1

	ip -net $F addr add 2001:f::0/16 dev f_s nodad
	ip -net $F addr add 2002:f::0/16 dev f_c nodad

	ip -net $S addr add 2001::100/16 dev s_f nodad
	ip -net $C addr add 2002::100/16 dev c_f nodad
	ip -net $S route add default via 2001:f::0 dev s_f
	ip -net $C route add default via 2002:f::0 dev c_f

	local retry=10
	until ip netns exec $C ping -6 2001::100 -i 0.3 -c 3 -W 1 > /dev/null
	do
		if ! ((retry--))
		then
			echo "Topo init fail ipv6"
			exit 1
		fi
	done

	sysctl -wq fs.file-max=64852200 || exit 1;
	sysctl -wq fs.nr_open=$(sysctl -n fs.file-max) || exit 1;
}

add_ipaddrs()
{
	# $n server ip will start $n threads
	serIpNum=${1:-1}
	cliIpNum=6
	serIP4s=""
	serIP6s=""
	cliIP4s=""
	cliIP6s=""

	# Config Server IPs
	for i in `seq 1 $serIpNum`
	do
		ip -net $S addr add 10.1.0.$((100+i))/16 dev s_f
		ip -net $S addr add 2001::$((100+i))/16 dev s_f nodad
		serIP4s+="10.1.0.$((100+i)),"
		serIP6s+="2001::$((100+i)),"
	done
	serIP4s=${serIP4s%,}
	serIP6s=${serIP6s%,}

	# Config Client IPs
	for i in `seq 1 $cliIpNum`
	do
		ip -net $C addr add 10.2.0.$((100+i))/16 dev c_f
		ip -net $C addr add 2002::$((100+i))/16 dev c_f nodad
		cliIP4s+="10.2.0.$((100+i)),"
		cliIP6s+="2002::$((100+i)),"
	done
	cliIP4s=${cliIP4s%,}
	cliIP6s=${cliIP6s%,}
}

setup()
{
	local serIpNum=${1:-1}

	create_topo
	add_ipaddrs $serIpNum
}

enable_flowtable()
{

ip netns exec $F nft -f - <<EOF
flush ruleset
table inet filter {
  flowtable f1 {
     hook ingress priority 0
     devices = { f_s, f_c }
   }

   chain forward {
      type filter hook forward priority 0; policy drop;

      meta oif "f_s" ct mark set 1 flow add @f1 counter accept
      ct mark 1 counter accept

      meta nfproto ipv4 meta l4proto icmp accept
      meta nfproto ipv6 meta l4proto icmpv6 accept
   }
}
EOF
	sysctl -wq net.nf_conntrack_max=1001000
	sysctl -wq net.netfilter.nf_conntrack_buckets=$((`sysctl -n net.nf_conntrack_max`* 2))
	sysctl -wq net.netfilter.nf_log_all_netns=1

	ip netns exec $F sysctl -wq net.netfilter.nf_conntrack_tcp_timeout_time_wait=2
	ip netns exec $F sysctl -wq net.netfilter.nf_conntrack_tcp_timeout_close=2

	ip netns exec $F nft list ruleset
}

enable_nat()
{
	# Config NAT IPs
        for i in `seq 1 ${cliIpNum:-6}`
        do
                ip -net $F addr add 10.1.$((100+i)).0/16 dev f_s
                ip -net $F addr add 2001::$((100+i)):0/16 dev f_s nodad
        done

ip netns exec $F nft -f /dev/stdin <<EOF || exit 1
flush ruleset
table inet nat {
	chain postrouting {
		type nat hook postrouting priority srcnat; policy accept;
		meta oif f_s counter masquerade
	}
}
EOF
	sysctl -wq net.nf_conntrack_max=1001000
	sysctl -wq net.netfilter.nf_conntrack_buckets=$((`sysctl -n net.nf_conntrack_max`* 2))
	sysctl -wq net.netfilter.nf_log_all_netns=1
}

enable_conntrack()
{
	# Active conntrack
	ip netns exec $F nft add table inet t
	ip netns exec $F nft add chain inet t c
	ip netns exec $F nft add inet t c ct state new

	for n in $S $C $F
	do
		ip netns exec $n sysctl -wq net.netfilter.nf_conntrack_tcp_timeout_time_wait=5
		ip netns exec $n sysctl -wq net.netfilter.nf_conntrack_tcp_timeout_close_wait=5
		ip netns exec $n sysctl -wq net.netfilter.nf_conntrack_tcp_timeout_fin_wait=5
	done
	sysctl -wq net.nf_conntrack_max=1001000
	sysctl -wq net.netfilter.nf_conntrack_buckets=$((`sysctl -n net.nf_conntrack_max`* 2))
	sysctl -wq net.netfilter.nf_log_all_netns=1

	ip netns exec $F ping 127.0.0.1 -c 1 > /dev/null
	if [ `ip netns exec $F conntrack -C` == "0" ]
	then
		echo "FAIL: conntrack doesn't get enabled!"
		exit 1
	fi
}

disable_conntrack()
{
	for n in $S $C $F
	do
		ip netns exec $n nft flush ruleset
		ip netns exec $n nft flush ruleset
		ip netns exec $n nft flush ruleset
	done
	nft flush ruleset
	rmmodule nf_conntrack
	if ! modprobe -r nf_conntrack
	then
		echo "FAIL: unload nf_conntrack"
		sysctl -a |grep netfilter_nf
	fi
}

check_requires()
{
	which conntrack > /dev/null || { echo "SKIP, requires conntrack-tools"; exit $ksft_skip; }
	which iperf3 > /dev/null || { echo "SKIP, requires iperf3"; exit $ksft_skip; }
	gcc connect_flood_server.c -o connect_flood_server -lpthread
	gcc connect_flood_client.c -o connect_flood_client -lpthread
}

start_flooding()
{
	local to=${1:-5}

	if [ "$L3" == "ipv6" ]
	then
		local serIPs=$serIP6s
		local cliIPs=$cliIP6s
	else
		local serIPs=$serIP4s
		local cliIPs=$cliIP4s
	fi

	case "$L4" in
		"tcp")  param="-t";;
		"udp")  param="-u";;
		"sctp") param="-s";;
	esac

	# Prefer big "-p value".(client port is the Outermost Loop in code)
	#set -x
	ip netns exec $S timeout $to ./connect_flood_server $param -H $serIPs -P 1001-1500 | tee server-$sfx.log &
	ip netns exec $C timeout $to ./connect_flood_client $param -H $serIPs -P 1001-1500 \
		-h $cliIPs -p 50001-60000 | tee client-$sfx.log &
	#set +x
	wait

	echo "ip netns exec $F conntrack -C"
	ip netns exec $F conntrack -C

	while pgrep connect_flood_server
	do
		sleep 1
	done

	while pgrep connect_flood_client
	do
		sleep 1
	done

}

get_average()
{
	local file=$1;
	# Excluded first and last line from calculation
	awk 'BEGIN {
		a[1000];
		sum = i = n = 0;
	}
	/connections/ {
		a[i] = $4;
		i++;
	}
	END {
		for (n = 1; n < (i-1); n++)
			sum = sum + a[n];
		print int(sum / (i - 2));
	}' $file
}

conntrack_perf()
{
	# Config the Numer of threads are used to flood
	local threadsNum=1
	local timeout=5

	echo "*************************************************"
	echo "*"
	echo "* Running ${FUNCNAME[0]}() with $threadsNum threads:"
	echo "* Measuring how much conntrack/nat will affect the"
	echo "* connection creating rate"
	echo "*"
	echo "*************************************************"

	setup $threadsNum

	echo "----------measuring cps without conntrack----------"
	disable_conntrack
	start_flooding $timeout
	local no_trk=$(get_average server-$sfx.log)

	echo "----------measuring cps with enable conntrack----------"
	enable_conntrack
	start_flooding $timeout
	local en_trk=$(get_average server-$sfx.log)
	ip netns exec $F head -5 /proc/net/nf_conntrack

	# Flush entries. Or in following test, the udp tracker
	# won't treat reused port packet as new and nat won't rewrite.
	ip netns exec $F conntrack -F

	echo "----------measuring cps with NAT----------"
	enable_nat
	start_flooding $timeout
	ip netns exec $F nft list ruleset
	local en_nat=$(get_average server-$sfx.log)
	ip netns exec $F head -5 /proc/net/nf_conntrack

	p_trk=$(echo "scale=4; $en_trk/$no_trk*100;" |bc)
	p_nat=$(echo "scale=4; $en_nat/$no_trk*100;" |bc)
	echo "*************************************************"
	echo "* Average Result:"
	echo "* Disabe trk: $no_trk cps"
	echo "* Enable trk: $en_trk cps		$p_trk%"
	echo "* Enable nat: $en_nat cps		$p_nat%"
	echo "*************************************************"

	cleanup
}

conntrack_code_paths()
{
	local threadsNum=5
	local timeout=5

	echo "*************************************************"
	echo "*"
	echo "* Running ${FUNCNAME[0]}() with $threadsNum threads:"
	echo "* Stressing while running conntrack -E"
	echo "*"
	echo "*************************************************"

	setup $threadsNum

	enable_conntrack

	timeout -s 9 $flood_time ip netns exec $F conntrack -f $L3 -E -b 212992001 > /dev/null 2>&1 &
	start_flooding $flood_time

	cleanup
}

start_iperf3()
{
	local timeout=$1
	case "$L4" in
		"tcp")	local param="";;
		"udp")	local param="--udp -b 0";;
		"sctp") local param="--sctp";;
	esac

        case "$L3" in
		"ipv4") local ip="10.1.0.100";;
		"ipv6") local ip="2001::100";;
	esac
	#set -x
	ip netns exec $S iperf3 -s -B $ip -p 5201 -D
	ip netns exec $C iperf3 $param -c $ip -t $timeout --cport 8888 --forceflush &
	#set +x
	sleep 1
}

conntrack_steady_state()
{
	local threadsNum=1
	local timeout=8

	echo "*************************************************"
	echo "*"
	echo "* Running ${FUNCNAME[0]}() with $threadsNum threads: "
	echo "* create n flows while monitoring the throughput"
	echo "* nf_conntrack_buckets highly affects the 'cps'"
	echo "*"
	echo "*************************************************"

	setup $threadsNum

	# enable_conntrack or enable_nat
	enable_conntrack

	# nf_conntrack_buckets highly affects the 'cps'
	sysctl -w net.netfilter.nf_conntrack_max=500000
	sysctl -w net.netfilter.nf_conntrack_buckets=100000

	start_iperf3 $timeout
	start_flooding $timeout
	ip netns exec $F nft list ruleset

	cleanup
}

conntrack_RPC_workload()
{
	local threadsNum=5
	local timeout=15

	echo "*************************************************"
	echo "*"
	echo "* Running ${FUNCNAME[0]}() with $threadsNum threads:"
	echo "* many short lived flows coming and going"
	echo "* stress the create/insert/delete conntrack path"
	echo "* while monitoring the throughput"
	echo "*"
	echo "*************************************************"

	setup $threadsNum

	enable_conntrack

	sysctl -w net.netfilter.nf_conntrack_max=100000000
	# provide enough hash buckets
	sysctl -w net.netfilter.nf_conntrack_buckets=2001000

	start_iperf3 $timeout
	start_flooding $timeout &
	sleep 2

	local sig_cmd=$(awk -F '`' /close_soon/'{print $2}' client-$sfx.log)
	echo "-----------Client start closing soon: $sig_cmd---------------"
	eval $sig_cmd

	wait # wait start_flooding() to finish
	cleanup
}

conntrack_flowtable()
{
	local threadsNum=1
	local timeout=15

	echo "*************************************************"
	echo "*"
	echo "* Running ${FUNCNAME[0]}() with $threadsNum threads: "
	echo "* testing the flowtable"
	echo "*"
	echo "*************************************************"

	setup $threadsNum

	# enable_conntrack or enable_nat
	enable_flowtable

	start_iperf3 $timeout

	# 1. start a iperf3 stream.
	# 2. create a lot of connections
	# 3. close all the connections
	# 4. observe entries timeout
	start_flooding $timeout &

	sleep $((timeout/5))
	ip netns exec $F head -5 /proc/net/nf_conntrack
	if ! ip netns exec $F head -5 /proc/net/nf_conntrack | grep -q "OFFLOAD"
	then
		echo "FAIL: ct OFFLOAD"
		ip netns exec $F nft list ruleset
		exit 1
	fi

	local sig_cmd=$(awk -F '`' /Pause/'{print $2}' client-$sfx.log)
	echo "----------Client pause to connect: $sig_cmd----------"
	eval $sig_cmd

	sleep $((timeout/5))

	local sig_cmd=$(awk -F '`' /close_all/'{print $2}' server-$sfx.log)
	echo "----------Server start closing all connections: $sig_cmd----------"
	eval $sig_cmd

	sleep $((timeout/5))
	sleep $((timeout/5))
	ip netns exec $F head -5 /proc/net/nf_conntrack

	local sig_cmd=$(awk -F '`' /close_all/'{print $2}' server-$sfx.log)
	echo "----------Server stop closing all connections: $sig_cmd----------"
	eval $sig_cmd

	sleep $((timeout/5))
	ip netns exec $F head -10 /proc/net/nf_conntrack

	wait # wait start_flooding()
	ip netns exec $F nft list ruleset

	cleanup
}

run_all()
{
	# measure how conntrack will affect connections
	# creating rate in this specific topo
	conntrack_perf

	# stress with `conntrack -E`
	conntrack_code_paths

	# create n flows while monitoring the throughput
	conntrack_steady_state

	# many short lived flows coming and going
	# stress the create/insert/delete conntrack path
	# while monitoring the throughput
	conntrack_RPC_workload

	# stress flow offload
	if [ x"$L4" != x"sctp" ]
	then
		conntrack_flowtable
	fi
}

check_requires
run_all
