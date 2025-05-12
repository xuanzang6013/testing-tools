#!/bin/bash

# Run this script on beaker machine dell-per750-20.rhts.eng.pek2.redhat.com
# mlx5_core
#               ┌───────────────────────────┐
#               │     netns N               │
#               │                           │
# ens7f0np0 ────┼──── ens7f1np1             │
#               └───────────────────────────┘
# Enable/disable functions below to see how they affect on a tcp stream.
#  start_tcp_stream_monitor
#  enable_conntrack()
#  start_an_udp_stream()
#  start_udp_cps_test()
#  start_pktgen()



# Include Beaker environment
rpm -q beakerlib || dnf -y install beakerlib
. /usr/share/beakerlib/beakerlib.sh || exit 1

# parse_netqe_nic_info.sh
test -x parse_netqe_nic_info.sh || {
	wget https://gitlab.cee.redhat.com/kernel-qe/kernel/-/raw/master/networking/common/tools/parse_netqe_nic_info.sh
	chmod u+x parse_netqe_nic_info.sh
}

exit_cleanup()
{
	echo "============exit_cleanup==============="

	pkill -9 -f connect_flood_server
	pkill -9 -f connect_flood_client
	pkill -9 -f iperf3
	kill -9 $PKTGEN_pid
	nft flush ruleset
	ip netns del N
}
trap  exit_cleanup 'EXIT'


install_udp_sink()
{
	[ -x udp_sink ] && return 0

	wget http://netqe-bj.usersys.redhat.com/share/yiche/network-testing-master.zip
	unzip -o -f network-testing-master.zip
	pushd network-testing-master/src || {
	git clone https://github.com/netoptimizer/network-testing.git
	pushd network-testing/src/
	}

	rlRun "make udp_sink"
	rlRun "cp udp_sink ../../"
	rlRun "cp udp_sink.c ../../"
	popd
}

install_pktgen()
{
	local ret=0
	RPM_MODULES_INTERNAL=$(uname -r | awk '{
	if (index($0,"rt")) {
		rt="-rt"
	}
	if (index($0,"debug")) {
		debug="-debug"
		gsub("+debug", "", $0)
	}
	split($0,v,"-");
	s=v[2];
	do {
		i=index(s,".");
		s=substr(s, i+1)
	} while(i > 0)
	sub("."s,"",v[2]);
	print "http://download.eng.bos.redhat.com/brewroot/packages/kernel"rt"/"v[1]"/"v[2]"/"s"/kernel"rt""debug"-modules-internal-"v[1]"-"v[2]"."s".rpm"
	print "http://download.eng.bos.redhat.com/brewroot/packages/kernel"rt"/"v[1]"/"v[2]"/"s"/kernel"rt"-selftests-internal-"v[1]"-"v[2]"."s".rpm"
	}')
	yum -y localinstall $RPM_MODULES_INTERNAL || let ret++
	cp /usr/libexec/ksamples/pktgen/{pktgen_sample05_flow_per_thread.sh,functions.sh,parameters.sh} . || let ret++
	#Setting Round Robin src ip
	sed -i '/src_min/c\    pg_set $dev "src_min 192.168.1.66"'  pktgen_sample05_flow_per_thread.sh || let ret++
	sed -i '/src_max/c\    pg_set $dev "src_max 192.168.1.254"'  pktgen_sample05_flow_per_thread.sh || let ret++
	return $ret
}

get_iface_name()
{
	local driver=${1:-"any"}
	local ifaces
	unset NIC_INFO
	# Choose speed >= 10g network card, the faster the better
	pci_id=$(./parse_netqe_nic_info.sh --match $(hostname) --raw --driver $driver | awk '{print $5}' | uniq)
	for i in $pci_id
	do
		ifaces+=$(ls /sys/bus/pci/devices/$i/net | tr '\n' ' ')
	done
	echo $ifaces
}

topo_setting()
{
	rlRun "ip netns del N" 0-255
	# Need to set iface and addr
	local ret=0
	rlRun "systemctl stop irqbalance"

	r_ip=192.168.1.1
	s_ip=192.168.1.235
	rlRun "get_iface_name mlx5_core"
	read receiver sender < <(get_iface_name mlx5_core)
	rlRun "[[ -n receiver && -n sender ]]" 0 "Interfaces found: sender:$sender receiver:$receiver"
	r_mac=`cat /sys/class/net/$receiver/address`

	rlRun "ip addr flush $receiver"
	rlRun "ip addr add $r_ip/24 dev $receiver"
	rlRun "ip link set $receiver up"
	rlRun "ip netns add N"
	rlRun "ip link set $sender netns N"
	rlRun "ip -n N link set lo up"
	rlRun "ip -n N addr add $s_ip/24 dev $sender"
	rlRun "ip -n N link set $sender up"
	# open arp function to make ping pass. and will close while testing
	rlRun "ip -n N link set $sender arp on"
	rlRun "ip link set $receiver arp on"
	local i=30
	rlWatchdog "\
	while ((i--));do
		ping -I $receiver $s_ip -c1 && break;
		ip netns exec N ping -c3 $r_ip && break;
	done" 100
}

set_irq_affinity()
{
	local inter_grep_name=$1; shift
	local cpus=( $@ )
	echo "inter_grep_name=$inter_grep_name"
	echo "cpus=${cpus[@]}"
	# The reason use 'grep -v async':
	# If the first interrupt is Asynchronous Event Interrupt e.g. mlx5_async0@pci
	# It doesn't use to receiving. Should skip it,
	# make sure CPUs 3,5 (same numa node) bond to mlx5_comp1@pci
	# Then this looks correct:
	#
	# USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
	# root      20   0       0      0      0 R  99.7   0.0   6:17.15 ksoftirqd/3
	# root      20   0       0      0      0 R  99.7   0.0  14:34.47 ksoftirqd/5
	local ints=( $(cat /proc/interrupts |grep $inter_grep_name | grep -v 'async' |awk -F: '{print $1}') )
	if [ "x" == x"$ints" ];then return 1;fi
	echo "ints=${ints[@]}"
	for i in `seq 0 $((rx_queues_num - 1))`
	do
		rlRun "echo ${cpus[i]} > /proc/irq/${ints[i]}/smp_affinity_list"
	done
}

get_irq_affinity()
{
	local inter_grep_name=$1
	local int=`cat /proc/interrupts |grep $inter_grep_name |awk -F: '{print $1}'`
	if [ "x" == x"$int" ];then return 1;fi
	rlLog "Print interrupt map table"
	echo "interrupt : smp_affinity_list"
	for n in $int
	do
		echo "$n : `cat /proc/irq/$n/smp_affinity_list`"
	done
}
set_rx_queue_nr()
{
	local iface=$1

	# configure the number of RX queue for this NIC, using the 'combined'
	# channels (both rx and tx) and the RX as fallback
	# The "si" colomn in `top` reflect number of rx queues.
	rlRun "ethtool -L $iface combined $rx_queues_num" 0-255 && return
	rlRun "ethtool -L $iface rx $rx_queues_num" 0-255 && return

	rlFail "can't set rx queue nr to $nr on device $iface"
	return 1
}

start_tcp_stream_monitor()
{
	rlRun "iperf3 -s 192.168.1.1 -D"
	sleep 1
	rlRun "ip netns exec N iperf3 -t 100 -c 192.168.1.1 &"
}

start_pktgen()
{
		rlRun "timeout 10 taskset --cpu-list $udpsink_cpu ./udp_sink -u  -c 2000000 -r 20 --port 9  &"
		udpsink_pid=$(jobs -l | awk '/udp_sink/ {print $2}')
		sleep 1
		# Pktgen use 1 thread on numa node 0
		rlRun "ip netns exec N taskset --cpu-list $pktgen_cpu ./pktgen_sample05_flow_per_thread.sh -i $sender -s 64 -b 64 -d $r_ip -m $r_mac -n0 -f 0 -t 1 &" 0 "Pktgen use 1 thread on numa node 0"
		PKTGEN_pid=$!
}

enable_conntrack()
{
        nft add table inet t
        nft add chain inet t c
        nft add inet t c ct state new
        sysctl -wq net.nf_conntrack_max=1001000

        sysctl -wq net.netfilter.nf_conntrack_buckets=$((`sysctl -n net.nf_conntrack_max`* 2))
        sysctl -wq net.netfilter.nf_log_all_netns=1
}

start_an_udp_stream()
{
	rlRun "iperf3 -s 192.168.1.1 -p 5202 -D"
	sleep 1
	rlRun "ip netns exec N unbuffer iperf3 -u -p 5202 -b0 -t 100 -c 192.168.1.1 | sed -e 's/^.*$/UDP: &/' -e 's/.*/$(echo -e '\033[31m')\0$(echo -e '\033[0m')/' &"
}

start_udp_cps_test()
{
	for i in `seq 2 100`
	do
	        rlRun "ip -net N addr add 192.168.1.$i/24 dev $sender"
	        cliIP4s+="192.168.1.$i,"
	done
	cliIP4s=${cliIP4s%,}

	rlRun "ip netns exec N ping 192.168.1.1 -c1"

	# Simulate DNS flood lookup
	rlRun "connect_flood_server -u -H $r_ip -P 53 &"
	sleep 1
	rlRun "ip netns exec N connect_flood_client -u -H $r_ip -P 53 -h ${cliIP4s} -p 10000-65000 &"
}

get_inter_grep_name()
{
	local receiver=$1
	local pci_info=`ethtool --driver $receiver |grep bus-info |awk '{print $2}'`
	case `ethtool --driver $receiver | grep driver` in
	*mlx5*)
		echo "$pci_info"
		;;
	*mlx4*)
		echo "$pci_info"
		;;
	*be2net*)
		echo "$pci_info"
		;;
	*i40e*)
		echo "$receiver"
		;;
	*)
		echo "$pci_info"
	esac
}

receiver_tuning()
{
	local cpus_to_bind=$@
	#disable pause frame
	rlRun "ethtool -A $receiver tx off"
	rlRun "ethtool -A $receiver rx off"
	rlRun "set_rx_queue_nr $receiver"
	local inter_grep_name=$(get_inter_grep_name $receiver)
	rlRun "set_irq_affinity $inter_grep_name $cpus_to_bind"
	rlRun "get_irq_affinity $inter_grep_name" 0 "checking $receiver irq setting"

	# enable napi_alloc_skb()
	rlRun "ethtool --set-priv-flags $receiver rx_striding_rq on"
	rlRun "ethtool -K $receiver lro on"

	# using the same RSS hkey
	# The rx hash is quite 'weak': it uses little entropy from the ingress L4
	# tuple and it can easily result in unbalance, if the number of L4 flows
	# is not very high, different seeds for such hash could produce different unbalance,
	# leading to different overall tput.
	# met pps=1880484.65 wich this hkey
	rlRun "ethtool -X $receiver hkey c3:41:ab:68:1b:1f:4f:d9:fb:fe:0c:2a:6e:c6:81:2c:b7:4e:8f:b1:d1:5e:26:3b:7c:43:66:31:56:15:fe:58:68:2e:6c:e8:ce:57:53:15"

	return 0
}

cpu_list_on_numa()
{
	local numa_node=${1:-0}
	local l
	read -t 1 l < /sys/devices/system/node/node${numa_node}/cpulist || return 1
	if [[ $l =~ "," ]]; then
		echo $l | sed 's/,/ /g'
	elif [[ $l =~ "-" ]]; then
		l=$(echo $l |sed 's/-/../g')
		eval echo {$l}
	fi
}

disable_all_SMT()
{
        # SMT: Simultaneous Multithreading
        # https://access.redhat.com/solutions/rhel-smt
	test -e /sys/devices/system/cpu/smt/control || { printf "CPU doesn't support SMT\n"; return 0; }
	local state=$(cat /sys/devices/system/cpu/smt/control)
	if [ "$state" == "on" ];then
		rlRun "echo off > /sys/devices/system/cpu/smt/control"
	fi
	rlRun "cat /sys/devices/system/cpu/smt/control"
	return 0
}


rlJournalStart
#----------------------------------------------------
# recvmsg is fast and ksoftirqd maybe unable to push
# packets fast enough inside the UDP socket
# So single RX queue/ksoftirqd process maybe not
# able to keep fully busy the udp_sink receiver.
#
# Increasing the RX queue number increases the contention on the socket
# receive buffer, reducing the performances
#
# So need to find out how many rx rqueues will make tput higher.

rx_queues_num=2
rlLog "Using $rx_queues rx queues"
#----------------------------------------------------
	rlPhaseStartSetup
		rlRun "killall udp_sink" 0-255
		rlRun "test -e ./pktgen_sample05_flow_per_thread.sh || install_pktgen"
		rlRun "rpm -q perf || dnf -y install perf"
		rlRun "rpm -q sysstat || dnf -y install sysstat"
		rlRun "rpm -q wget || dnf -y install wget"
		rlRun "rpm -q unzip || dnf -y install unzip"
		rlRun "rpm -q git || dnf -y install git"
		rlRun "rpm -q gcc || dnf -y install gcc"
		rlRun "test -x udp_sink || install_udp_sink"

		# The softirqd and udp_sink must be pinned on the same NUMA node
		# it would be better to run pktgen on a different NUMA node
		numa_node0=($(cpu_list_on_numa 0))
		numa_node1=($(cpu_list_on_numa 1))
		pktgen_cpu=${numa_node0[0]}
		udpsink_cpu=${numa_node1[0]}
		irqs_cpu=${numa_node1[@]:1:${rx_queues_num}}
		echo irqs_cpu=$irqs_cpu

		rlRun "sysctl net.core.rmem_max=16777216"
		rlRun "sysctl net.core.wmem_max=16777216"
		#rlRun "disable_the_other_cpu_thread $udpsink_cpu"
		rlRun "disable_all_SMT"
		rlRun "topo_setting"
		rlRun "receiver_tuning $irqs_cpu"
		echo "========================================================="
		rlLog "
			Pktgen using cpu: $pktgen_cpu
			udp_sink using cpu: $udpsink_cpu
			$rx_queues_num rx_queues using cpu: $irqs_cpu
		"
		echo "========================================================="
		rlRun "lscpu |grep NUMA"
	rlPhaseEnd

	rlPhaseStartTest "udp_sink recvmsg on CPU $udpsink_cpu"
		start_tcp_stream_monitor
		enable_conntrack
		start_an_udp_stream
#		start_udp_cps_test
#		start_pktgen
		wait $udpsink_pid

		rlRun "kill -9 $PKTGEN_pid" 0-255
		rlRun "pkill -9 -f connect_flood_server" 0-255
		rlRun "pkill -9 -f connect_flood_client" 0-255
		rlRun "pkill -9 -f iperf3" 0-255
	rlPhaseEnd

	rlPhaseStartCleanup
		rlRun "kill -9 $PKTGEN_pid" 0-255
		rlRun "pkill -9 -f connect_flood_server" 0-255
		rlRun "pkill -9 -f connect_flood_client" 0-255
		rlRun "pkill -9 -f iperf3" 0-255
		ip netns del N
		sleep 1
		#rlRun "chcpu -e 0-$(($(nproc)-1)) >/dev/null" 0 "make all cpu online"
		rlRun "ip link set $sender down"
		rlRun "ip link set $receiver down"
		rlRun "ip addr flush $sender"
		rlRun "ip addr flush $receiver"
		rlRun "ip link set $sender arp on"
		rlRun "ip link set $receiver arp on"
		rlRun "ethtool -A $receiver tx on"
		rlRun "ethtool -A $receiver rx on"
		rlRun "systemctl start irqbalance"
		rlRun "rmmod pktgen"
		rlRun "sysctl net.core.rmem_max=212992"
		rlRun "sysctl net.core.wmem_max=212992"
	rlPhaseEnd
rlJournalEnd
