setup_topo()
{
	systemctl start openvswitch
	systemctl start ovn-northd
	ovn-nbctl set-connection ptcp:6641
	ovn-sbctl set-connection ptcp:6642
	ovs-vsctl set open . external_ids:system-id=hv1 external_ids:ovn-remote=tcp:127.0.0.1:6642 external_ids:ovn-encap-type=geneve external_ids:ovn-encap-ip=127.0.0.1
	systemctl restart ovn-controller
	ovs-vsctl add-br br-ext
	ovs-vsctl set Open_vSwitch . external-ids:ovn-bridge-mappings=phynet:br-ext
	ovn-nbctl lr-add lr1
	ovn-nbctl lrp-add lr1 lr1-ls1 00:00:01:ff:02:03 192.168.1.254/24
	ovn-nbctl ls-add ls1
	ovn-nbctl lsp-add ls1 ls1p1
	ovn-nbctl lsp-set-addresses ls1p1 "00:00:01:01:01:01 192.168.1.1"
	ovn-nbctl lsp-add ls1 ls1p2
	ovn-nbctl lsp-set-addresses ls1p2 "00:00:01:01:01:02 192.168.1.2"
	ovn-nbctl lsp-add ls1 ls1-lr1
	ovn-nbctl lsp-set-type ls1-lr1 router
	ovn-nbctl lsp-set-options ls1-lr1 router-port=lr1-ls1
	ovn-nbctl lsp-set-addresses ls1-lr1 router
	ovn-nbctl ls-add pub
	ovn-nbctl lrp-add lr1 lr1-pub 00:00:01:ff:01:03 172.16.1.1/24
	ovn-nbctl lsp-add pub pub-lr1
	ovn-nbctl lsp-set-type pub-lr1 router
	ovn-nbctl lsp-set-addresses pub-lr1 router
	ovn-nbctl lsp-set-options pub-lr1 router-port=lr1-pub
	ovn-nbctl lsp-add pub pub-ln
	ovn-nbctl lsp-set-type pub-ln localnet
	ovn-nbctl lsp-set-addresses pub-ln unknown
	ovn-nbctl lsp-set-options pub-ln network_name=phynet
	ovn-nbctl lrp-set-gateway-chassis lr1-pub hv1
	ovn-nbctl lb-add lb_test 172.16.1.101 192.168.1.1
	ovn-nbctl lr-lb-add lr1 lb_test
	ovn-nbctl ls-lb-add ls1 lb_test
	ovs-vsctl add-port br-int ls1p1 -- set interface ls1p1 type=internal external_ids:iface-id=ls1p1
	ip netns add ls1p1
	ip link set ls1p1 netns ls1p1
	ip netns exec ls1p1 ip link set ls1p1 address 00:00:01:01:01:01
	ip netns exec ls1p1 ip link set ls1p1 up
	ip netns exec ls1p1 ip addr add 192.168.1.1/24 dev ls1p1
	ip netns exec ls1p1 ip route add default via 192.168.1.254
	ovs-vsctl add-port br-int ls1p2 -- set interface ls1p2 type=internal external_ids:iface-id=ls1p2
	ip link set ls1p2 up
	ip netns add ls1p2
	ip link set ls1p2 netns ls1p2
	ip netns exec ls1p2 ip link set ls1p2 address 00:00:01:01:01:02
	ip netns exec ls1p2 ip link set ls1p2 up
	ip netns exec ls1p2 ip addr add 192.168.1.2/24 dev ls1p2
	ip netns exec ls1p2 ip route add default via 192.168.1.254
	ovs-vsctl add-port br-ext ext1 -- set interface ext1 type=internal
	ip netns add ext1
	ip link set ext1 netns ext1
	ip netns exec ext1 ip link set ext1 up
	ip netns exec ext1 ip addr add 172.16.1.254/24 dev ext1
	ip netns exec ext1 ip addr add 172.16.1.253/24 dev ext1
	ip netns exec ext1 ip addr add 172.16.1.252/24 dev ext1
	ip netns exec ext1 ip addr add 172.16.1.251/24 dev ext1
	ip netns exec ext1 ip addr add 172.16.1.250/24 dev ext1
	ip netns exec ext1 ip addr add 172.16.1.249/24 dev ext1
	ovn-nbctl --wait=hv sync
	ip netns exec ext1 ping 172.16.1.101 -c 1
}

#+++++++++++ do test ++++++++++++++++++++
#sysctl net.netfilter.nf_conntrack_buckets=2621440
sysctl net.netfilter.nf_conntrack_hashsize=50000000
sysctl net.netfilter.nf_conntrack_max=50000000
sysctl net.core.rmem_max=33554432
sysctl net.core.wmem_max=33554432
sysctl net.ipv4.udp_mem="12340131 16453511 49360524"
conntrack -F

setup_topo
exit_cleanup()
{
        echo "============exit_cleanup==============="

        pkill -9 -f connect_flood_server
        pkill -9 -f connect_flood_client
        pkill -9 -f iperf3
        pkill -9 -f netserver
        pkill -9 -f netperf
	sysctl net.core.rmem_max=212992
	sysctl net.core.wmem_max=212992
	sysctl net.netfilter.nf_conntrack_buckets=262144
	sysctl net.ipv4.udp_mem="758799	1011732	1517598"
	conntrack -F

	systemctl stop ovn-controller &>/dev/null
	# delete it manually
	ovs-vsctl del-br br-int
	systemctl stop ovn-northd &>/dev/null
	systemctl stop openvswitch &>/dev/null
	sleep 1
	rm -rf /etc/openvswitch/*.db
	rm -rf /etc/openvswitch/*.pem
	rm -rf /var/lib/openvswitch/*
	rm -rf /var/lib/ovn/*
	rm -rf /etc/ovn/*.db
	rm -rf /etc/ovn/*.pem
	# clean up log
	rm -rf /var/log/ovn/*
	rm -rf /var/log/openvswitch/*
	ip -all netns del
	sync
}
trap  exit_cleanup 'EXIT'

udp_cps_test()
{
	ip netns exec ls1p1 connect_flood_server -u -H 192.168.1.1 -P 10000-11000 &
	sleep 1
	ip netns exec ext1 connect_flood_client -u -H 172.16.1.101 -P 10000-11000 -h 172.16.1.254,172.16.1.253,172.16.1.252,172.16.1.251,172.16.1.250,172.16.1.249 -p 1000-65535 &
	sleep 100
}

udp_cps_and_tput_test()
{
	ip netns exec ls1p1 connect_flood_server -u -H 192.168.1.1 -P 10000-11000 &
	sleep 1
	ip netns exec ext1 connect_flood_client -u -H 172.16.1.101 -P 10000-11000 -h 172.16.1.254,172.16.1.253,172.16.1.252,172.16.1.251,172.16.1.250,172.16.1.249 -p 1000-65535 | tee client.log &
	sleep 10
	cmd=$(awk -F '`' '/Throughput mode/''{print $2}' client.log)
	$cmd
	sleep 100
}

udp_cps_and_tput_with_netperf_test()
{
#	ip netns exec ls1p1 connect_flood_server -u -H 192.168.1.1 -P 10000-11000 &
#	sleep 1
#	ip netns exec ext1 connect_flood_client -u -H 172.16.1.101 -P 10000-11000 -h 172.16.1.254,172.16.1.253,172.16.1.252,172.16.1.251,172.16.1.250,172.16.1.249 -p 1000-65535 | tee client.log &
#	sleep 15
#	cmd=$(awk -F '`' '/Throughput mode/''{print $2}' client.log)
#	$cmd
	ip netns exec ls1p1 netserver
	sleep 1
	ip netns exec ext1 netperf -4 -L 172.16.1.254 -H 172.16.1.101 -P 0 -f m -t UDP_CRR -l 10  -T1,1 -I 95,10 -i 6,3 -c -C -O 1,1 -- -m 1472 -k 'THROUGHPUT, LOCAL_CPU_UTIL, REMOTE_CPU_UTIL, CONFIDENCE_LEVEL, THROUGHPUT_CONFID, LOCAL_SEND_SIZE, REMOTE_RECV_SIZE, LOCAL_SEND_THROUGHPUT, REMOTE_RECV_THROUGHPUT, LOCAL_CPU_PEAK_UTIL, REMOTE_CPU_PEAK_UTIL'
	sleep 200
}

multi_thread_udp_cps_test()
{
	ip netns exec ls1p1 connect_flood_server -u -H 192.168.1.1 -P 10000-11000 &
	sleep 1
	for i in {1..1};do
		cli_addr=172.16.1."$((248-i))"
		sleep 1
		ip netns exec ext1 ip addr add ${cli_addr}/24 dev ext1
		ip netns exec ext1 connect_flood_client -u -H 172.16.1.101 -P 10000-11000 -h ${cli_addr} -p 1000-65535 -c &
	done
	sleep 100

}

#udp_cps_test
#udp_cps_and_tput_test
#udp_cps_and_tput_with_netperf_test
multi_thread_udp_cps_test
