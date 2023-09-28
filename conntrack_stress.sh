#! /bin/bash
# SPDX-License-Identifier: GPL-2.0
# This script crate huge amount of tcp/udp/sctp ipv4/ipv6 connections
# to test/stress the connection tracking subsystem in linux kernel.
# Monitor one iperf3 stream to reflect conntrack hash matching performance


# Add path
export PATH=${PWD}/src:${PATH}

# Kselftest framework requirement - SKIP code is 4.
ksft_skip=4
sfx="-$(mktemp -u "XXXXXXXX")"

# default
l3proto=ipv4
l4proto=tcp

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
		4) l3proto=ipv4;;
		6) l3proto=ipv6;;
		t) l4proto=tcp;;
		u) l4proto=udp;;
		s) l4proto=sctp; modprobe sctp || exit $ksft_skip;;
		*) usage;;
	esac
done

[ -z $l3proto ] && l3proto=ipv4
[ -z $l4proto ] && l3proto=tcp


#echo "*************************************************"
#echo " l3protoproto   : $l3proto"
#echo " l4protoproto   : $l4proto"
#echo " num_serip  : $num_serip (Also threads Num)"
#echo " num_serport: $num_serport"
#echo " num_cliip  : $num_cliip"
#echo " num_cliport: $num_cliport"
#echo "*************************************************"


cleanup()
{
	echo "------------cleanup--------------"
	ip netns pids $S 2> /dev/null| xargs kill >/dev/null 2>&1
	ip netns pids $C 2> /dev/null| xargs kill >/dev/null 2>&1
	ip netns del $S 2> /dev/null
	ip netns del $C 2> /dev/null
	ip netns del $F 2> /dev/null
	rm server$sfx.log 2> /dev/null
	rm client$sfx.log 2> /dev/null

	sysctl -q fs.file-max=${backup_file_max}
	sysctl -q fs.nr_open=${backup_nr_open}
	rmmodule nf_conntrack

	unset num_serip
	unset num_serport
	unset num_cliip
	unset num_cliport
	unset timeout
	unset cli_extra_opt
	unset ser_extra_opt

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

create_ns_topo()
{
	backup_file_max=$(sysctl -n fs.file-max)
	backup_nr_open=$(sysctl -n fs.nr_open)

	F="F$sfx" # Forward
	S="S$sfx" # Server
	C="C$sfx" # Client

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

set_addrs()
{
	serIP4s=""
	serIP6s=""
	cliIP4s=""
	cliIP6s=""
	serPorts=""
	cliPorts=""

	# Config Server IPs
	for i in `seq 1 $num_serip`
	do
		ip -net $S addr add 10.1.0.$((100+i))/16 dev s_f
		ip -net $S addr add 2001::$((100+i))/16 dev s_f nodad
		serIP4s+="10.1.0.$((100+i)),"
		serIP6s+="2001::$((100+i)),"
	done
	serIP4s=${serIP4s%,}
	serIP6s=${serIP6s%,}

	# Config Client IPs
	for i in `seq 1 $num_cliip`
	do
		ip -net $C addr add 10.2.0.$((100+i))/16 dev c_f
		ip -net $C addr add 2002::$((100+i))/16 dev c_f nodad
		cliIP4s+="10.2.0.$((100+i)),"
		cliIP6s+="2002::$((100+i)),"
	done
	cliIP4s=${cliIP4s%,}
	cliIP6s=${cliIP6s%,}

	serPorts="1001-$((1000+num_serport))"
	cliPorts="5001-$((5000+num_cliport))"
}

start_flooding()
{
	if [ "$l3proto" == "ipv6" ]
	then
		local serIPs=$serIP6s
		local cliIPs=$cliIP6s
	else
		local serIPs=$serIP4s
		local cliIPs=$cliIP4s
	fi

	case "$l4proto" in
		"tcp")  param="-t";;
		"udp")  param="-u";;
		"sctp") param="-s";;
	esac

	# Prefer big "-p value".(client port is the Outermost Loop in code)
	set -x
	ip netns exec $S timeout $timeout connect_flood_server $param -H $serIPs -P $serPorts $ser_extra_opt | tee server$sfx.log &
	ip netns exec $C timeout $timeout connect_flood_client $param -H $serIPs -P $serPorts \
		-h $cliIPs -p $cliPorts $cli_extra_opt | tee client$sfx.log &
	set +x
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

setup()
{
	[ -z $num_serip ]   && { echo "num_serip   need set"; exit 1;}
	[ -z $num_serport ] && { echo "num_serport need set"; exit 1;}
	[ -z $num_cliip ]   && { echo "num_cliip   need set"; exit 1;}
	[ -z $num_cliport ] && { echo "num_cliport need set"; exit 1;}
	[ -z $timeout ]     && { echo "timeout     need set"; exit 1;}

	create_ns_topo
	set_addrs
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
        for i in `seq 1 ${num_cliip:-6}`
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
		echo "FAIL: conntrack doesn't enabled!"
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

conntrack_code_paths()
{
	num_serip=5  # Also threads num
	num_cliip=6
	num_serport=500
	num_cliport=10000
	timeout=5

	echo "*************************************************"
	echo "*"
	echo "* Running ${FUNCNAME[0]}() with $num_serip threads:"
	echo "* Stressing while running conntrack -E"
	echo "*"
	echo "*************************************************"

	setup

	enable_conntrack

	set -x
	timeout -s 9 $timeout ip netns exec $F conntrack -f $L3 -E -b 212992001 > /dev/null 2>&1 &
	set +x
	start_flooding

	cleanup
}

start_iperf3()
{
	case "$l4proto" in
		"tcp")	local param="";;
		"udp")	local param="--udp -b 0";;
		"sctp") local param="--sctp";;
	esac

        case "$l3proto" in
		"ipv4") local ip="10.1.0.100";;
		"ipv6") local ip="2001::100";;
	esac
	set -x
	ip netns exec $S iperf3 -s -B $ip -p 5201 -D; sleep 0.3
	ip netns exec $C iperf3 $param -c $ip -t $timeout --cport 8888 --forceflush &
	set +x
	sleep 1
}

conntrack_steady_state()
{
	num_serip=5  # Also threads num
	num_cliip=6
	num_serport=500
	num_cliport=10000
	timeout=8

	echo "*************************************************"
	echo "*"
	echo "* Running ${FUNCNAME[0]}() with $num_serip threads: "
	echo "* create n flows while monitoring the throughput"
	echo "* nf_conntrack_buckets highly affects the 'cps'"
	echo "*"
	echo "*************************************************"

	setup

	# enable_conntrack or enable_nat
	enable_conntrack

	# nf_conntrack_buckets highly affects the 'cps'
	sysctl -w net.netfilter.nf_conntrack_max=500000
	sysctl -w net.netfilter.nf_conntrack_buckets=100000

	start_iperf3
	start_flooding
	ip netns exec $F nft list ruleset

	cleanup
}

conntrack_RPC_workload()
{
	num_serip=5  # Also threads num
	num_cliip=6
	num_serport=500
	num_cliport=10000
	timeout=15

	echo "*************************************************"
	echo "*"
	echo "* Running ${FUNCNAME[0]}() with $num_serip threads:"
	echo "* many short lived flows coming and going"
	echo "* stress the create/insert/delete conntrack path"
	echo "* while monitoring the throughput"
	echo "*"
	echo "*************************************************"

	setup

	enable_conntrack

	sysctl -w net.netfilter.nf_conntrack_max=100000000
	# provide enough hash buckets
	sysctl -w net.netfilter.nf_conntrack_buckets=2001000

	start_iperf3
	start_flooding
	sleep 2

	local sig_cmd=$(awk -F '`' /close_soon/'{print $2}' client$sfx.log)
	echo "-----------Client start closing soon: $sig_cmd---------------"
	eval $sig_cmd

	wait # wait start_flooding() to finish
	cleanup
}

conntrack_flowtable()
{
	num_serip=5  # Also threads num
	num_cliip=6
	num_serport=500
	num_cliport=10000
	timeout=15

	echo "*************************************************"
	echo "*"
	echo "* Running ${FUNCNAME[0]}() with $num_serip threads: "
	echo "* testing the flowtable"
	echo "*"
	echo "*************************************************"

	setup

	# enable_conntrack or enable_nat
	enable_flowtable

	start_iperf3

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

	local sig_cmd=$(awk -F '`' /Pause/'{print $2}' client$sfx.log)
	echo "----------Client pause to connect: $sig_cmd----------"
	eval $sig_cmd

	sleep $((timeout/5))

	local sig_cmd=$(awk -F '`' /close_all/'{print $2}' server$sfx.log)
	echo "----------Server start closing all connections: $sig_cmd----------"
	eval $sig_cmd

	sleep $((timeout/5))
	sleep $((timeout/5))
	ip netns exec $F head -5 /proc/net/nf_conntrack

	local sig_cmd=$(awk -F '`' /close_all/'{print $2}' server$sfx.log)
	echo "----------Server stop closing all connections: $sig_cmd----------"
	eval $sig_cmd

	sleep $((timeout/5))
	ip netns exec $F head -10 /proc/net/nf_conntrack

	wait # wait start_flooding()
	ip netns exec $F nft list ruleset

	cleanup
}

measure_conntrack_performance()
{
	num_serip=1  # Also threads num
	num_cliip=6
	num_serport=500
	num_cliport=10000
	timeout=5


	echo "*************************************************"
	echo "*"
	echo "* Running ${FUNCNAME[0]}() with $num_serip threads:"
	echo "* Measuring how much conntrack/nat will affect the"
	echo "* connection creating rate"
	echo "*"
	echo "*************************************************"

	setup

	echo "----------measuring cps without conntrack----------"
	disable_conntrack
	start_flooding $timeout
	local no_trk=$(get_average server$sfx.log)

	echo "----------measuring cps with enable conntrack----------"
	enable_conntrack
	start_flooding $timeout
	local en_trk=$(get_average server$sfx.log)
	ip netns exec $F head -5 /proc/net/nf_conntrack

	# Flush entries. Or in following test, the udp tracker
	# won't treat reused port packet as new and nat won't rewrite.
	ip netns exec $F conntrack -F

	echo "----------measuring cps with NAT----------"
	enable_nat
	start_flooding $timeout
	ip netns exec $F nft list ruleset
	local en_nat=$(get_average server$sfx.log)
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

nat_iptables_stress()
{
	echo "*************************************************"
	echo "*"
	echo "* Running ${FUNCNAME[0]}() with $num_serip threads: "
	echo "* The 'CPS' should keep at high level."
	echo "*"
	echo "*************************************************"

	num_serip=1  # Also threads num
	num_cliip=10
	num_serport=1
	num_cliport=10000
	timeout=15
	cli_extra_opt="-c"

	enable_nat_iptables()
	{
		# bz2196717
	        ip -net $F addr add 10.1.$((100+i)).0/16 dev f_s
	        ip -net $F addr add 2001::$((100+i)):0/16 dev f_s nodad

		ip netns exec $F iptables -t nat -A POSTROUTING -p tcp -j MASQUERADE --random-fully

		sysctl -wq net.nf_conntrack_max=1001000
		sysctl -wq net.netfilter.nf_conntrack_buckets=$((`sysctl -n net.nf_conntrack_max`* 2))
		sysctl -wq net.netfilter.nf_log_all_netns=1
	}

	setup
	enable_nat_iptables
	start_flooding

	ip netns exec $F nft list ruleset
	ip netns exec $F head -5 /proc/net/nf_conntrack

	cleanup
}
run_all()
{
	# measure how conntrack will affect connections
	# creating rate
	measure_conntrack_performance

	# stress with `conntrack -E`
	conntrack_code_paths

	# create n flows while monitoring the throughput
	conntrack_steady_state

	# many short lived flows coming and going
	# stress the create/insert/delete conntrack path
	# while monitoring the throughput
	conntrack_RPC_workload

	# stress flow offload
	if [ x"$l4proto" != x"sctp" ]
	then
		conntrack_flowtable
	fi

	# test when snat port resource exhausted TIME_WAIT entry reuse
	nat_iptables_stress
}

run_all
