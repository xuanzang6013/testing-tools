#! /bin/bash -x
# SPDX-License-Identifier: GPL-2.0
# This script crate huge amount of tcp/udp/sctp ipv4/ipv6 connections
# to test/stress the connection tracking subsystem in linux kernel.
# Monitor one iperf3 stream to reflect conntrack hash matching perform
#

# Kselftest framework requirement - SKIP code is 4.
ksft_skip=4
sfx=$(mktemp -u "XXXXXXXX")

l3box=(ipv4 ipv6)
l4box=(tcp udp)

L3=${l3box[RANDOM%2]}
L4=${l4box[RANDOM%2]}

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

while getopts "46tusk" o
do
	case $o in
		4) L3=ipv4;;
		6) L3=ipv6;;
		t) L4=tcp;;
		u) L4=udp;;
		s) L4=sctp; modprobe sctp || exit $ksft_skip;;
		k) keep_topo=1;;
		*) usage;;
	esac
done

uname -a
free -h

echo "*************************************************"
echo "  $L3   $L4"
echo "*************************************************"


destroy_topo()
{
	echo "------------destroy_topo--------------"
	cleanup
	ip addr flush $pf0_name
	ip addr flush $pf1_name
	sysctl -q net.ipv4.conf.all.forwarding=0
	sysctl -q net.ipv6.conf.all.forwarding=0
	ip netns del $S 2> /dev/null
	ip netns del $C 2> /dev/null

	echo 0 > /sys/class/net/$pf0_name/device/sriov_numvfs
	echo 0 > /sys/class/net/$pf1_name/device/sriov_numvfs

	rm server-$sfx.log 2> /dev/null
	rm client-$sfx.log 2> /dev/null

	sysctl -q fs.file-max=${backup_file_max}
	sysctl -q fs.nr_open=${backup_nr_open}
	rmmodule nf_conntrack || lsmod nf_conntrack

	ip link set $pf0_name down
	ip link set $pf1_name down
	echo ""
}

if [[ $keep_topo != 1 ]]
then
	trap destroy_topo EXIT
fi

cleanup()
{
	jobs -p | xargs -x kill > /dev/null 2>&1
	ip netns pids $S 2> /dev/null| xargs kill >/dev/null 2>&1
	ip netns pids $C 2> /dev/null| xargs kill >/dev/null 2>&1
	ip -net $S addr flush $s_f
	ip -net $C addr flush $c_f
	ip addr flush $f_s
	ip addr flush $f_c
	nft flush ruleset
}

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

pci2name()
{
	local pci_id="$1"         # 0000:ca:00.0
	local pci_bus="${1%:*}"   # 0000:ca
	local name=$(ls /sys/class/pci_bus/$pci_bus/device/$pci_id/net | grep -v ".*vf.*")
        echo $name
}

name2pci()
{
	local ifname="$1"
	readlink /sys/class/net/$ifname/device | xargs -x basename
}

exclude_rep()
{
	read ifaces
	for i in $ifaces
	do
		ethtool -i $i |grep -q "_rep" || {
			echo $i
		}
	done
}

find_rep()
{
	read ifaces
	for i in $ifaces
	do
		ethtool -i $i |grep -q "_rep" && {
			echo $i
		}
	done
}

mac2name()
{
	# ls /sys/class/net/*/address  |while read line;do ls $line; cat $line;done
	local mac="$1"
	while read line
	do
	        if [ `cat $line` == "$1" ]
	        then
	                name=$(echo $line | awk -F '/' '{print $5}')
	                break;
	        fi
	done < <(ls /sys/class/net/*/address)
        echo $name
}

get_reps()
{
	target_id=$(cat /sys/class/net/$1/phys_switch_id)
	ls /sys/class/net/*/phys_switch_id | while read line
	do
		if grep -q -s $target_id $line; then
			echo $line | awk -F '/' '{print $5}' | find_rep
		fi
	done
}

create_sriov()
{
	# mlx SRIOV setting
	if which parse_netqe_nic_info.sh
	then
		#parse_netqe_nic_info.sh is a private script used in our lab
		[ -e /tmp/nic_info ] || {
			unset NIC_INFO
		}
		pcis=$(parse_netqe_nic_info.sh -d mlx5_core --match $(hostname) --raw |awk '{print $5}')
		pf0_pci_id=$(echo $pcis | awk '{print $1}')
		pf1_pci_id=$(echo $pcis | awk '{print $2}')

		pf0_name=$(pci2name $pf0_pci_id | exclude_rep)
		pf1_name=$(pci2name $pf1_pci_id | exclude_rep)
	else
		ip a
		echo "Specify a PF interface name by hand:"
		read -p "pf0_name=" pf0_name
		pf0_pci_id=$(name2pci $pf0_name)
	fi

	echo ""
	echo "PF0 $pf0_name $pf0_pci_id is used"
	echo "PF1 $pf1_name $pf1_pci_id unused"

	# Only use one PF
	# If no traffic out, even no need to set PF up
	ip link set $pf0_name up
	echo 2 > /sys/class/net/$pf0_name/device/sriov_numvfs

	vf0_pci_id=$(readlink /sys/class/net/$pf0_name/device/virtfn0 | xargs -l basename)
	vf1_pci_id=$(readlink /sys/class/net/$pf0_name/device/virtfn1 | xargs -l basename)

#	echo $vf0_pci_id > /sys/bus/pci/drivers/mlx5_core/unbind
#	echo $vf1_pci_id > /sys/bus/pci/drivers/mlx5_core/unbind

	devlink dev eswitch set pci/$pf0_pci_id mode switchdev || exit 2

#	echo $vf0_pci_id > /sys/bus/pci/drivers/mlx5_core/bind
#	echo $vf1_pci_id > /sys/bus/pci/drivers/mlx5_core/bind

	vf0_name=$(ls /sys/class/net/$pf0_name/device/virtfn0/net)
	vf1_name=$(ls /sys/class/net/$pf0_name/device/virtfn1/net)
}

create_topo()
{
	backup_file_max=$(sysctl -n fs.file-max)
	backup_nr_open=$(sysctl -n fs.nr_open)

	create_sriov

#	S="S-$sfx" # Server
#	C="C-$sfx" # Client
	S=S
	C=C

	s_f=$vf0_name
	f_s=$(get_reps $pf0_name| sed -n '1p')
	c_f=$vf1_name
	f_c=$(get_reps $pf0_name| sed -n '2p')

	echo "Rep0 $f_s"
	echo "Rep1 $f_c"
	echo "VF0 $s_f"
	echo "VF1 $c_f"

	# --This piece of code in case fe80:: not generated----
	nmcli device set $f_s managed no
	nmcli device set $f_c managed no

	ip link set $f_s addrgenmode eui64
	ip link set $f_c addrgenmode eui64

	ip link set $f_s down
	ip link set $f_c down
	#--------------------------------

	ip netns add $S
	ip netns add $C

	ip link set $s_f netns $S
	ip link set $c_f netns $C

	ip -net $S link set $s_f up
	ip -net $C link set $c_f up
	ip link set $f_s up
	ip link set $f_c up

	ip netns exec $C ethtool -K $c_f tx-sctp-segmentation off

	ip -net $S link set lo up
	ip -net $C link set lo up
	ip -net $S link set $s_f mtu 1500
	ip -net $C link set $c_f mtu 1500
	ip link set $f_s mtu 1500
	ip link set $f_c mtu 1500

	# IPv4 Setting
	sysctl -q net.ipv4.conf.all.forwarding=1

	ip addr add 10.1.255.254/16 dev $f_s
	ip addr add 10.2.255.254/16 dev $f_c

	ip -net $S addr add 10.1.0.100/16 dev $s_f
	ip -net $C addr add 10.2.0.100/16 dev $c_f
	ip -net $S route add default via 10.1.255.254
	ip -net $C route add default via 10.2.255.254

	local retry=3
	until ip netns exec $C ping 10.1.0.100 -c 3
	do
		if ! ((retry--))
		then
			echo "Topo init fail ipv4"
			exit 1
		fi
	done

	# IPv6 Setting
	sysctl -q net.ipv6.conf.all.forwarding=1

	echo "-----------------------------------"
	ip addr add 2111::ffff/64 dev $f_s nodad
	ip addr add 2112::ffff/64 dev $f_c nodad

	ip -net $S addr add 2111::100/64 dev $s_f nodad
	ip -net $C addr add 2112::100/64 dev $c_f nodad
	ip -net $S route add default via 2111::ffff dev $s_f
	ip -net $C route add default via 2112::ffff dev $c_f

	local retry=3
	until ip netns exec $C ping -6 2111::100 -c 3
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
	# server ip will start threads
	serIpNum=${1:-1}
	cliIpNum=6
	serIP4s=""
	serIP6s=""
	cliIP4s=""
	cliIP6s=""

	# Config Server IPs
	for i in `seq 1 $serIpNum`
	do
		ip -net $S addr add 10.1.0.$((100+i))/16 dev $s_f
		ip -net $S addr add 2111::$((100+i))/16 dev $s_f nodad
		serIP4s+="10.1.0.$((100+i)),"
		serIP6s+="2111::$((100+i)),"
	done
	serIP4s=${serIP4s%,}
	serIP6s=${serIP6s%,}

	# Config Client IPs
	for i in `seq 1 $cliIpNum`
	do
		ip -net $C addr add 10.2.0.$((100+i))/16 dev $c_f
		ip -net $C addr add 2112::$((100+i))/16 dev $c_f nodad
		cliIP4s+="10.2.0.$((100+i)),"
		cliIP6s+="2112::$((100+i)),"
	done
	cliIP4s=${cliIP4s%,}
	cliIP6s=${cliIP6s%,}
}

enable_flowtable()
{

	 ethtool -K $f_s hw-tc-offload on
	 ethtool -K $f_c hw-tc-offload on

# https://lwn.net/Articles/804384/
cat > rules <<-EOF
flush ruleset
table inet filter {
  flowtable f1 {
     hook ingress priority 10
     flags offload
     devices = { $f_s, $f_c }
   }

   chain forward {
      type filter hook forward priority 0; policy drop;

      meta oif "$f_s" ct mark set 1 flow add @f1 counter accept
      ct mark 1 counter accept

      meta nfproto ipv4 meta l4proto icmp accept
      meta nfproto ipv6 meta l4proto icmpv6 accept
   }
}
EOF

# The ruleset should be set on Representer but not on VF in namespace!
	nft -f rules || {
		echo "nft hw flow offload rule added fail"
		exit 1
	}

	modprobe nf_conntrack enable_hooks=1
	if [ $? != 0 ]
	then
		nft list ruleset
		exit 1
	fi

	sysctl -wq net.nf_conntrack_max=1001000
	sysctl -wq net.netfilter.nf_conntrack_buckets=$((`sysctl -n net.nf_conntrack_max`* 2))
	sysctl -wq net.netfilter.nf_log_all_netns=1

	#sysctl -wq net.netfilter.nf_conntrack_tcp_timeout_time_wait=2
	#sysctl -wq net.netfilter.nf_conntrack_tcp_timeout_close=2

	nft list ruleset
}

check_requires()
{
	which conntrack > /dev/null || { echo "SKIP, requires conntrack-tools"; exit $ksft_skip; }
	which iperf3 > /dev/null || { echo "SKIP, requires iperf3"; exit $ksft_skip; }
	gcc connect_flood_server.c -o connect_flood_server -l pthread
	gcc connect_flood_client.c -o connect_flood_client -l pthread
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
		"ipv6") local ip="2111::100";;
	esac
	#set -x
	ip netns exec $S iperf3 -s -B $ip -p 5201 -D
	ip netns exec $C iperf3 $param -c $ip -t $timeout --cport 8888 --forceflush &
	#set +x
	sleep 1
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

conntrack_flowtable()
{
	local threadsNum=1

	echo "*************************************************"
	echo "*"
	echo "* Running ${FUNCNAME[0]}() with $threadsNum threads: "
	echo "* testing the flowtable"
	echo "*"
	echo "*************************************************"

	add_ipaddrs $threadsNum

	enable_flowtable

	start_iperf3 1000
	sleep 5

	# 1. start a iperf3 stream.
	# 2. create a lot of connections
	# 3. close all the connections
	# 4. observe entries timeout
	start_flooding 1000 &

	sleep 1
	head -5 /proc/net/nf_conntrack
	sleep 60

	local sig_cmd=$(awk -F '`' /Pause/'{print $2}' client-$sfx.log)
	echo "----------Client pause to connect: $sig_cmd----------"
	eval $sig_cmd

	sleep 10

	head -5 /proc/net/nf_conntrack

	local sig_cmd=$(awk -F '`' /close_all/'{print $2}' server-$sfx.log)
	echo "----------Server start closing all connections: $sig_cmd----------"
	eval $sig_cmd

	sleep 10

	head -5 /proc/net/nf_conntrack

	wait # wait start_flooding()
	nft list ruleset

	cleanup
}

offload_timeout()
{
	enable_flowtable

	sysctl net.netfilter.nf_flowtable_tcp_timeout=6
	sysctl net.netfilter.nf_flowtable_udp_timeout=6

	case "$L4" in
		"tcp")	local ser_proto="TCP-LISTEN"
			local cli_proto="TCP"
			;;
		"udp")	local ser_proto="UDP-LISTEN"
			local cli_proto="UDP"
			;;
	esac

        case "$L3" in
		"ipv4") local ip="10.1.0.100"
			local socat_ip="10.1.0.100"
			export SOCAT_DEFAULT_LISTEN_IP=4
			;;
		"ipv6") local ip="2111:0000:0000:0000:0000:0000:0000:0100"
			local socat_ip="[2111:0000:0000:0000:0000:0000:0000:0100]"
			export SOCAT_DEFAULT_LISTEN_IP=6
			;;
	esac

	> pipefile

	set -x
	ip netns exec S socat $ser_proto:9999 STDOUT,ignoreeof & sleep 2
	echo "tail -f pipefile | socat STDIN $cli_proto:$socat_ip:9999 &" | ip netns exec C bash
	set +x


	# send packet 5s interval
	i=0;while ((++i));do echo "#$i. send a message" >> pipefile; sleep 5;done &
	while true;do cat /proc/net/nf_conntrack |grep "$ip"; sleep 1;done &
	sleep 50

	cleanup
}

run_all()
{
	# testing offload timeout
	offload_timeout

	# stress flow offload
	conntrack_flowtable
}

check_requires
create_topo
run_all
