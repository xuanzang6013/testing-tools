#! /bin/bash
iface1=ens2f0
iface2=ens2f1

cleanup()
{
	echo "========== do cleanup ==============="
	set -x

	ip addr flush $iface1
	ip addr flush $iface2
	nft flush ruleset
	sysctl fs.file-max=6485220 > /dev/null
	sysctl fs.nr_open=1048576 > /dev/null
	sysctl net.ipv4.tcp_syn_retries=6
	nft delete table t 2> /dev/null
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
	ip addr flush $1
	ip addr flush $2

        ip addr add 10.0.1.1/24 dev $1
        ip addr add 10.0.2.1/24 dev $2

	sysctl net.ipv4.conf.all.forwarding=1

	ip link set $1 up
	ip link set $2 up
}

enable_conntrack()
{
	# Active conntrack
	if [ $(conntrack -C) == 0 ]
	then

		if [[ $(modinfo nf_conntrack |grep -q enable_hooks) && ! $(lsmod |grep nf_conntrack) ]]
		then
			modprobe nf_conntrack enable_hooks=1
		else
			nft add table t
			nft add chain t c
			nft add t c ct state new
		fi
	fi

	sysctl -w net.nf_conntrack_max=20000100
	sysctl -w net.netfilter.nf_conntrack_buckets=$((`sysctl -n net.nf_conntrack_max`* 2))

	# stress hash a little
	#sysctl -w net.netfilter.nf_conntrack_buckets=8000000

	sysctl -w net.netfilter.nf_conntrack_tcp_timeout_time_wait=5
	sysctl -w net.netfilter.nf_conntrack_tcp_timeout_close_wait=5
	sysctl -w net.netfilter.nf_conntrack_tcp_timeout_fin_wait=5
	sysctl -w net.netfilter.nf_flowtable_tcp_timeout=30000 # default 30s
	sysctl -w net.netfilter.nf_flowtable_udp_timeout=30000

}

enable_offload()
{
nft -f - <<-EOF
table inet filter {
        flowtable f1 {
                hook ingress priority -100
                devices = { $iface1, $iface2 }
        }

        chain forward {
                type filter hook forward priority filter; policy accept;
                meta l4proto tcp ct state established,related counter packets 0 bytes 0 flow add @f1 counter packets 0 bytes 0
                ip protocol tcp ct state invalid counter packets 0 bytes 0 drop
                ip protocol tcp tcp flags fin,rst counter packets 0 bytes 0 accept
                meta length < 100 counter packets 0 bytes 0 accept
                ip protocol tcp counter packets 0 bytes 0 log drop
        }
}

EOF
}

install()
{
	rpm -q conntrack-tools || dnf -y install conntrack-tools
}

watching()
{
	sysctl -a |grep nf_conntrack
	while true
	do
		conntrack -C
		sleep 1
	done
}
set -x
install
add_ipaddrs $iface1 $iface2
test -z "$1" || enable_conntrack
test -z "$2" || enable_offload
watching &
set +x
wait
