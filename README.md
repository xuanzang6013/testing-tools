# Connections flooding tool

## Overview
This is a tool for stress/test conntrack in kernel. The program could generates connection flood in ipv4/ipv6 tcp/udp/sctp. It will print out establishing/closing rate in 'cps'(conn per sec).

It supports multi threads and runtime intereact with SIGUSR singals.

## Usage
You can specify multiple server/client IPaddress, port range, that are used to generate connections (the 5 tuples).
- The number of serIPs, The number of threads are used
```shell
connect_flood_server -t -H 10.0.1.100,10.0.1.101,10.0.1.102 -P 1001-1500 &
connect_flood_client -t -H 10.0.1.100,10.0.1.101,10.0.1.102 -P 1001-1500 -h 10.0.2.101,10.0.2.102,10.0.2.103 -p 50001-60000
or
connect_flood_server -t -H 2001::101,2001::102 -P 1001-1500 &
connect_flood_client -t -H 2001::101,2001::102 -P 1001-1500 -h 2002::101,2002::102 -p 50001-60000
```

And when you want to adjust behaviour, you could:

SERVER: Switch on/off close_all (Stop receiving and close all opened connections)
```shell
kill -s <SIGUSR1> <pid_server>
```
CLIENT: Pause/Continue
```shell
kill -s <SIGUSR2> <pid_client>
```
CLIENT: Switch on/off close_soon (Directly close after established)
```shell
kill -s <SIGUSR1> <pid_client>
```

## Options
```
Usage: connect_flood_server -H <serIp1[,serIp2,serIp3...]> -P <portMin-portMax>  [-t|-u|-s]
```
The number of serIPs, The number of threads are used
- `-H` : specify one or more server addresses, separate by ','. Will create one thread for each seraddr.
- `-p` : specify client port range, separate by '-'
- `-t` : TCP mode (default)
- `-u` : UDP mode
- `-s` : SCTP mode

```
Usage: connect_flood_client -H <serIp1[,serIp2,serIp3...]> -P <portMin-portMax> -h <cliIp1[,cliIp2,cliIp3...]> -p <portMin-portMax> [-t|-u|-s]
```
The number of serIPs, The number of threads are used
- `-H` : specify one or more server addresses, separate by ','. Will create one thread for each seraddr.
- `-h` : specify one or more client addresses, separate by ','
- `-p` : specify client port range, separate by '-'
- `-P` : specify server port range, separate by '-'
- `-t` : TCP mode (default)
- `-u` : UDP mode
- `-s` : SCTP mode


# flow_offload_mlx5_sriov.sh

## Overview
This script is simulate traffic (throughput & connections flood) between containers (network namespace).
It configs HW OFFLOAD on INVIDA network card[1] with nftables See:[2],[3]

Also test timeout setting in HW OFFLOAD. 

- [1] https://blogs.nvidia.com/blog/2020/05/20/whats-a-dpu-data-processing-unit/
- [2] https://wiki.nftables.org/wiki-nftables/index.php/Flowtables
- [3] https://docs.kernel.org/networking/nf_flowtable.html

NVIDIA mlx5:
- https://enterprise-support.nvidia.com/s/article/Configuring-VF-LAG-using-TC

Intel E810:
- https://cdrdv2-public.intel.com/645272/645272_E810%20eSwitch%20switchdev%20Mode%20Config%20Guide_rev1_1.pdf


# conntrack_stress.sh
## Overview
This is a script focus on stress conntrack in linux kernel. and measure conntrack performance.
How conntrack will affect on connection establish rate?
Let's test.




#### Choose Red Hat Enterprise Linux!
