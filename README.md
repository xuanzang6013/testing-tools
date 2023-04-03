# Connection flooding tools

## Overview
This is a tool for stress/test conntrack in kernel. The program could generate connection flood in ipv4/ipv6 tcp/udp/sctp. It will print out establishing/closing rate in 'cps'(conn per sec).
It supports multi threads and runtime intereact with SIGUSR1 (kill -12 <pid>)

## Usage
You can specify multiple server/client IPaddress, port range, that are used to generate connections (the 5 tuples).
```shell
connect_flood_server -t -4 -H 10.0.1.100,10.0.1.101,10.0.1.102 -P 1001-1500 &
connect_flood_client -t -4 -H 10.0.1.100,10.0.1.101,10.0.1.102 -P 1001-1500 -h 10.0.2.101,10.0.2.102,10.0.2.103 -p 50001-60000
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
Usage: connect_flood_server -H <serIp1[,serIp2,serIp3...]> -P <portMin-portMax> [-t|-u|-s]
- `-H`	specify one or more server addresses, separate by ','. one addr for each thread
- `-p`	specify client port range, separate by '-'
- `-t`	TCP mode (default)
- `-u`	UDP mode
- `-s`	SCTP mode


Usage: connect_flood_client -H <serIp1[,serIp2,serIp3...]> -P <portMin-portMax> -h <cliIp1[,cliIp2,cliIp3...]> -p <portMin-portMax> [-t|-u|-s]
- `-H`	specify one or more server addresses, separate by ','
- `-h`	specify one or more client addresses, separate by ','
- `-p`	specify client port range, separate by '-'
- `-P`	specify server port range, separate by '-'
- `-t`	TCP mode (default)
- `-u`	UDP mode
- `-s`	SCTP mode


## TODO
