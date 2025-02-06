#! /bin/bash
# As the number of sockets increases
# compare the new established CPS (connections per second)
# of TCP and UDP.

cleanup()
{
        for n in $(ip netns)
        do
                kill $(ip netns pids $n) 2> /dev/null
                ip netns del $n 2> /dev/null
        done
        rmmod bridge 2> /dev/null
        rmmod veth 2> /dev/null
        return 0
}
trap cleanup 'EXIT'

ip netns add R
ip netns add S
ip netns add C

ip link add s_r netns S type veth peer name r_s netns R
ip netns exec S ip link set s_r up
ip netns exec R ip link set r_s up
ip link add c_r netns C type veth peer name r_c netns R
ip netns exec R ip link set r_c up
ip netns exec C ip link set c_r up

ip netns exec S ip link set lo up
ip netns exec R ip link set lo up
ip netns exec C ip link set lo up

# ipv4
ip netns exec S ip addr add 10.167.69.1/24 dev s_r
ip netns exec S ip addr add 10.167.69.2/24 dev s_r
ip netns exec S ip addr add 10.167.69.3/24 dev s_r
ip netns exec C ip addr add 10.167.68.1/24 dev c_r
ip netns exec C ip addr add 10.167.68.2/24 dev c_r
ip netns exec C ip addr add 10.167.68.3/24 dev c_r

ip netns exec R sysctl -w net.ipv4.conf.all.forwarding=1
ip netns exec R ip addr add 10.167.69.254/24 dev r_s
ip netns exec R ip addr add 10.167.68.254/24 dev r_c
ip netns exec C ip route add 10.167.69.0/24 via 10.167.68.254 dev c_r
ip netns exec S ip route add 10.167.68.0/24 via 10.167.69.254 dev s_r
ip netns exec C ping 10.167.69.1 -c1 || exit 1;

# ipv6
ip netns exec S ip addr add 2001:db8:ffff:22::1/64 dev s_r nodad
ip netns exec S ip addr add 2001:db8:ffff:22::2/64 dev s_r nodad
ip netns exec S ip addr add 2001:db8:ffff:22::3/64 dev s_r nodad
ip netns exec C ip addr add 2001:db8:ffff:21::1/64 dev c_r nodad
ip netns exec C ip addr add 2001:db8:ffff:21::2/64 dev c_r nodad
ip netns exec C ip addr add 2001:db8:ffff:21::3/64 dev c_r nodad

ip netns exec R sysctl -w net.ipv6.conf.all.forwarding=1
ip netns exec R ip addr add 2001:db8:ffff:22::fffe/64 dev r_s nodad
ip netns exec R ip addr add 2001:db8:ffff:21::fffe/64 dev r_c nodad
ip netns exec C ip route add 2001:db8:ffff:22::/64 via 2001:db8:ffff:21::fffe dev c_r
ip netns exec S ip route add 2001:db8:ffff:21::/64 via 2001:db8:ffff:22::fffe dev s_r
ip netns exec C ping 2001:db8:ffff:22::1 -c1 || exit 1;


echo ""
echo "Testing ipv4 tcp sockets"
ip netns exec S timeout 21 connect_flood_server -t -H 10.167.69.1,10.167.69.2,10.167.69.3 -P 10000-10010 &
sleep 1
ip netns exec C timeout 20 connect_flood_client -t -H 10.167.69.1,10.167.69.2,10.167.69.3 -P 10000-10010 \
		-h 10.167.68.1,10.167.68.2,10.167.68.3 -p 10000-60000 &
wait

echo ""
echo "Testing ipv4 udp sockets"
ip netns exec S timeout 21 connect_flood_server -u -H 10.167.69.1,10.167.69.2,10.167.69.3 -P 10000-10010 &
sleep 1
ip netns exec C timeout 20 connect_flood_client -u -H 10.167.69.1,10.167.69.2,10.167.69.3 -P 10000-10010 \
		-h 10.167.68.1,10.167.68.2,10.167.68.3 -p 10000-60000 &
wait

echo ""
echo "Testing ipv6 tcp sockets"
ip netns exec S timeout 21 connect_flood_server -t -H 2001:db8:ffff:22::1,2001:db8:ffff:22::2,2001:db8:ffff:22::3 -P 10000-10010 &
sleep 1
ip netns exec C timeout 20 connect_flood_client -t -H 2001:db8:ffff:22::1,2001:db8:ffff:22::2,2001:db8:ffff:22::3 -P 10000-10010 \
		-h 2001:db8:ffff:21::1,2001:db8:ffff:21::2,2001:db8:ffff:21::3 -p 10000-60000 &
wait

echo ""
echo "Testing ipv6 udp sockets"
ip netns exec S timeout 21 connect_flood_server -u -H 2001:db8:ffff:22::1,2001:db8:ffff:22::2,2001:db8:ffff:22::3 -P 10000-10010 &
sleep 1
ip netns exec C timeout 20 connect_flood_client -u -H 2001:db8:ffff:22::1,2001:db8:ffff:22::2,2001:db8:ffff:22::3 -P 10000-10010 \
		-h 2001:db8:ffff:21::1,2001:db8:ffff:21::2,2001:db8:ffff:21::3 -p 10000-60000 &
wait
