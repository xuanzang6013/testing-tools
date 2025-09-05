#! /bin/bash

cleanup()
{
	for n in $(ip netns)
	do
		kill $(ip netns pids $n) 2> /dev/null
		ip netns del $n 2> /dev/null
	done
	#nft flush ruleset
	rmmod bridge 2> /dev/null
	rmmod veth 2> /dev/null
	return 0
}
trap cleanup EXIT

topo_cs_create()
{
	cleanup
	sysctl -w net.netfilter.nf_log_all_netns=1

        ip netns add S
        ip netns add C

        ip link add s_c netns S type veth peer name c_s netns C
        ip netns exec S ip link set s_c up
        ip netns exec C ip link set c_s up

        ip netns exec S ip link set lo up
        ip netns exec C ip link set lo up

	ip netns exec S ip -4 addr add 10.167.1.1/16 dev s_c
	ip netns exec S ip -4 addr add 10.167.1.2/16 dev s_c
	ip netns exec S ip -4 addr add 10.167.1.3/16 dev s_c
	ip netns exec S ip -4 addr add 10.167.1.4/16 dev s_c
	ip netns exec S ip -4 addr add 10.167.1.5/16 dev s_c

        ip netns exec C ip -4 addr add 10.167.2.1/16 dev c_s
        ip netns exec C ip -4 addr add 10.167.2.2/16 dev c_s
        ip netns exec C ip -4 addr add 10.167.2.3/16 dev c_s
        ip netns exec C ip -4 addr add 10.167.2.4/16 dev c_s
        ip netns exec C ip -4 addr add 10.167.2.5/16 dev c_s


        ip netns exec S ip -6 addr add 2001:db8:ffff:1::1/48 dev s_c nodad
        ip netns exec S ip -6 addr add 2001:db8:ffff:1::2/48 dev s_c nodad
        ip netns exec S ip -6 addr add 2001:db8:ffff:1::3/48 dev s_c nodad
        ip netns exec S ip -6 addr add 2001:db8:ffff:1::4/48 dev s_c nodad
        ip netns exec S ip -6 addr add 2001:db8:ffff:1::5/48 dev s_c nodad

        ip netns exec C ip -6 addr add 2001:db8:ffff:2::1/48 dev c_s nodad
        ip netns exec C ip -6 addr add 2001:db8:ffff:2::2/48 dev c_s nodad
        ip netns exec C ip -6 addr add 2001:db8:ffff:2::3/48 dev c_s nodad
        ip netns exec C ip -6 addr add 2001:db8:ffff:2::4/48 dev c_s nodad
        ip netns exec C ip -6 addr add 2001:db8:ffff:2::5/48 dev c_s nodad

	sleep 0.5
        ip netns exec C ping 10.167.1.1 -c1 || return 1
        ip netns exec C ping 2001:db8:ffff:1::1 -c1 || return 1

	return 0
}


dynamic_1ms_stress()
{
	local t=10

	topo_cs_create
	ip netns exec S nft -f - <<-EOF
		flush ruleset
		table inet t {
			set myset_ipv4 {
				type ipv4_addr . inet_service . ipv4_addr . inet_service . inet_proto
				size 655350
				flags dynamic,timeout
				timeout 1ms
			}
			set myset_ipv6 {
				type ipv6_addr . inet_service . ipv6_addr . inet_service . inet_proto
				size 655350
				flags dynamic,timeout
				timeout 1ms
			}

			chain c {
				type filter hook input priority filter; policy accept;
				tcp flags and ( syn or ack or fin or rst ) == ( syn|ack ) counter add @myset_ipv4 { ip saddr . tcp sport . ip daddr . tcp dport . ip protocol timeout 1ms} counter
				tcp flags and ( syn or ack or fin or rst ) == ( syn|ack ) counter add @myset_ipv6 { ip6 saddr . tcp sport . ip6 daddr . tcp dport . ip6 nexthdr timeout 1ms} counter
			}
		}
	EOF
	ip netns exec S nft list ruleset


	# ipv4
	serIPs=10.167.1.1,10.167.1.2,10.167.1.3,10.167.1.4,10.167.1.5
	serPorts=1001-10000
	cliIPs=10.167.2.1,10.167.2.2,10.167.2.3,10.167.2.4,10.167.2.5
	cliPorts=10000-60000
	set -x
	ip netns exec S timeout $t connect_flood_server -t -H $serIPs -P $serPorts &
	ip netns exec C timeout $t connect_flood_client -t -H $serIPs -P $serPorts -h $cliIPs -p $cliPorts &
	set +x

	# ipv6
	serIPs=2001:db8:ffff:1::1,2001:db8:ffff:1::2,2001:db8:ffff:1::3,2001:db8:ffff:1::4,2001:db8:ffff:1::5
	serPorts=1001-10000
	cliIPs=2001:db8:ffff:2::1,2001:db8:ffff:2::2,2001:db8:ffff:2::3,2001:db8:ffff:2::4,2001:db8:ffff:2::5
	cliPorts=10000-60000
	set -x
	ip netns exec S timeout $t connect_flood_server -t -H $serIPs -P $serPorts &
	ip netns exec C timeout $t connect_flood_client -t -H $serIPs -P $serPorts -h $cliIPs -p $cliPorts &
	set +x

	wait
}


pipapo_update_dump_stress()
{
	# 1) create set S and fill with elements - type must be
	#    concatenated, and interval flag set (to force use of pipapo backend)
	nft -f - <<-EOF
		flush ruleset
		table ip t {
			set myset {
				type ipv4_addr . inet_service . inet_proto
				size 655350
				flags interval
				timeout 1d
			}

			chain c {
				type filter hook input priority filter; policy accept;
			}
		}
	EOF

	timeout 10 bash -c '
	for y in $(seq 1 10); do
		for x in $(seq 1 200); do
			nft add element t myset {10.$x.$y.1/24 . ${x}1-$((x+1))0 . 6-17}
		done
	done' &

	# 2) run a loop doing "add table foo; delete table foo"
	timeout 10 bash -c '
	while true; do
		nft add   table foo
		nft flush table foo
		nft list set ip t myset > /dev/null
	done' &

	# 3) check the output of 'list set S' to contain all elements
	wait
	nft list set ip t myset | head -20; echo "..."
}

pipapo_update_dump_stress
dynamic_1ms_stress
