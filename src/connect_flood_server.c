// SPDX-License-Identifier: GPL-2.0
/* This is a connection flood tool aim to create a large
 * number of tcp/udp/sctp ipv4/ipv6 connections fastly,
 * to stress conntrack subsystem in linux.
 *
 * Program will create a thread for each server address given.
 * In each thread, multiple listening sockets are created for
 * each port and using epoll() to demux them.
 *
 * e.g.
 * ./connect_flood_server -H 10.0.1.100,10.0.1.101,10.0.1.102 -P 1001-1500 -t &
 * Switch on/off close_all conections by `kill -s 10 <pid>`
 *
 * Authors: Chen Yi <yiche@redhat.com>
 */

#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <string.h>
#include <errno.h>
#include <arpa/inet.h>
#include <semaphore.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/prctl.h>
#include <signal.h>
#include <sys/wait.h>
#include <pthread.h>
#include <sys/time.h>
#include <sys/resource.h>
#include <sys/epoll.h>
#include "connect_flood.h"


/* send buffer size default 128k */
size_t BUFFER_SIZE = 0x20000;
char udp_buf[100];

char *ser_port_min;
char *ser_port_max;
int close_all;
int sock_type = SOCK_STREAM;
int sock_protocol;
int Throughput;
sa_family_t addr_family = AF_INET6;

static pthread_cond_t cond = PTHREAD_COND_INITIALIZER;
static pthread_mutex_t mtx = PTHREAD_MUTEX_INITIALIZER;
static pthread_barrier_t barrier;

int cnt_new[MAX_TRD];
int cnt_closed[MAX_TRD];
int ep_conns[MAX_TRD];
uint64_t cnt_nbytes[MAX_TRD];

typedef struct count {
	int new;
	int closed;
	uint64_t nbytes;
} count_t;

int (*accept_func)(int fd, struct sockaddr *peeraddr, socklen_t *addrlen);


void sg_handler(int sig)
{
	if (sig == SIGUSR1) {
		close_all = (close_all) ? 0 : 1;
		printf("\e[1;31mSERVER:close_all all= %d \e[0m\n", close_all);
		fflush(NULL);
	}
}

int udp_close_passive(int fd)
{
	/* FIN already received when call this */
	int nbytes;
	if (send(fd, "ACK,UDPFIN", 10, 0) == -1) {
		perror("SERVER: UDP FIN,ACK send");
		return -1;
	}

	nbytes = recv(fd, udp_buf, sizeof(udp_buf), 0);
	/* The length of "LASKACK" */
	if (nbytes == 7) {
		close(fd);
		return 0;
	}
	else if (nbytes == -1) {
		perror("SERVER: udp_close_passive recv error");
	}
	else
		printf("warning: udp_close_passive, LASKACK didn't received\n");
	return -1;
}

int udp_accept(int sockfd, struct sockaddr *peeraddr, socklen_t *len)
{
	int connfd = -1, flag = 1, mode;
	struct sockaddr_storage localaddr;

	if (recvfrom(sockfd, udp_buf, sizeof(udp_buf), 0, peeraddr, len) == -1) {
		perror("recvfrom");
		return -1;
	}
	connfd = socket(addr_family, SOCK_DGRAM, IPPROTO_UDP);
	if (connfd == -1) {
		perror("socket");
		return -1;
	}
	if (getsockname(sockfd, (struct sockaddr *)&localaddr, len) == -1) {
		perror("getsockname");
		return -1;
	}
	if (setsockopt(connfd, SOL_SOCKET, SO_REUSEADDR, &flag, sizeof(flag)) < 0) {
		perror("setsockopt(sockfd,SOL_SOCKET, SO_REUSEADDR)");
		return -1;
	}
	if (bind(connfd, (struct sockaddr *)&localaddr, sizeof(localaddr)) == -1) {
		perror("bind connfd");
		return -1;
	}
	if (connect(connfd, peeraddr, *len) == -1) {
		perror("UDP connect");
		return -1;
	}

	if (send(connfd, "SYN,ACK", 7, 0) == -1) {
		perror("SERVER: UDP send");
		return -1;
	}

	/* wait client to write back */
	if (recv(connfd, udp_buf, sizeof(udp_buf), 0) == -1) {
		perror("SERVER: UDP read");
		return -1;
	}
	return connfd;
}

void *handle_peer_close_or_send(void *p)
{
	thdp_t *thp = (thdp_t *)p;
	/* thp: thread parameter */
	int ep_conn = ep_conns[thp->thd_seq];

	char RECVBUF[BUFFER_SIZE];
	int max_events = 100000;
	int ready, i;
	ssize_t nbytes;
	struct epoll_event conn_evlist[max_events];

	while (1) {
		ready = epoll_wait(ep_conn, conn_evlist, max_events, -1);
		if (ready == -1) {
			perror("SERVER: epoll_wait");
			exit(1);
		}
		for (i = 0; i < ready; i++) {
			/* ready to close */
			if (conn_evlist[i].events & EPOLLRDHUP) {
				if (epoll_ctl(ep_conn, EPOLL_CTL_DEL, conn_evlist[i].data.fd, NULL) == -1) {
					perror("epoll_ctl DEL");
					exit(1);
				}
				if (close(conn_evlist[i].data.fd) == -1) {
					perror("handle_peer_close");
				}
				cnt_closed[thp->thd_seq]++;
			}
			/* ready to recv */
			else if (conn_evlist[i].events & EPOLLIN) {
				/* handle udp close */
				if (!Throughput && IS_UDP) {
					nbytes = recv(conn_evlist[i].data.fd, RECVBUF, BUFFER_SIZE, 0);
					/* The len of "UDPFIN" */
					if (nbytes == 6) {
						if (!udp_close_passive(conn_evlist[i].data.fd))
							cnt_closed[thp->thd_seq]++;
					}
					else if (nbytes < 0)
					{
						perror("udp recv failed");
					}
					else
						Throughput = 1;
				}
				else {
					Throughput = 1;
					nbytes = recv(conn_evlist[i].data.fd, RECVBUF, BUFFER_SIZE, 0);
					if (nbytes < 0) {
						perror("recv failed");
					}
					cnt_nbytes[thp->thd_seq] += nbytes;
					//dprintf(2, "%d bytes received\n", nbytes);
				}
			}
			else {
				if (conn_evlist[i].events & (EPOLLHUP | EPOLLERR)) {
					perror("epoll returned EPOLLHUP | EPOLLERR");
				}
			}
		}
	}
}

void *handle_peer_new(void *p)
{
	thdp_t *thp = (thdp_t *)p;
	char *addrstr = thp->addrp;
	int ep_conn = ep_conns[thp->thd_seq];

	int connfd, sockfd, len, s_port;
	int ready, i, fd, max_listen, ep_lis;
	int enable = 1;
	buff_t buf_state;

	/* this is a per thread instance */
	if (create_queue(&buf_state) != 0) {
		dprintf(2, "calloc failed\n");
		exit(1);
	}

	/* Support for both IPv4 and IPv6.
	 * sockaddr_storage: Can contain both sockaddr_in and sockaddr_in6
	 */
	struct sockaddr_storage seraddr, peeraddr;
	struct sockaddr_in *addr4 = NULL;
	struct sockaddr_in6 *addr6 = NULL;

	memset(&seraddr, 0, sizeof(seraddr));

	if (addr_family == AF_INET) {
		addr4 = (struct sockaddr_in *)&seraddr;
		addr4->sin_family = AF_INET;
		inet_pton(AF_INET, (char *)addrstr, &addr4->sin_addr);
	}
	if (addr_family == AF_INET6) {
		addr6 = (struct sockaddr_in6 *)&seraddr;
		addr6->sin6_family = AF_INET6;
		inet_pton(AF_INET6, (char *)addrstr, &addr6->sin6_addr);
	}

	/* create listening socket epoll instance */
	max_listen = atoi(ser_port_max) - atoi(ser_port_min) + 1;
	struct epoll_event ev, conn_ev;
	struct epoll_event evlist[max_listen];

	ep_lis = epoll_create(5);
	if (ep_lis == -1) {
		perror("epoll_create");
		exit(1);
	}
	/* Interested in peer closing and sending events */
	conn_ev.events = EPOLLRDHUP | EPOLLIN;

	/*Loop for server port*/
	for (s_port = atoi(ser_port_min); s_port <= atoi(ser_port_max); s_port++) {
		sockfd = socket(addr_family, sock_type, sock_protocol);
		if (sockfd == -1) {
			perror("socket:");
			exit(1);
		}

		if (setsockopt(sockfd, SOL_SOCKET, SO_REUSEADDR, &enable, sizeof(int)) < 0) {
			perror("setsockopt(SO_REUSEADDR) failed");
			exit(1);
		}

		if (addr_family == AF_INET) {
			addr4->sin_port = htons(s_port);
			if (bind(sockfd, (struct sockaddr *)addr4, sizeof(seraddr)) == -1) {
				perror("SERVER bind ipv4:");
				exit(1);
			}
		}
		if (addr_family == AF_INET6) {
			addr6->sin6_port = htons(s_port);
			if (bind(sockfd, (struct sockaddr *)addr6, sizeof(seraddr)) == -1) {
				perror("SERVER bind ipv6:");
				exit(1);
			}
		}

		listen(sockfd, 20);

		/* Only interested in input events */
		ev.events = EPOLLIN;
		ev.data.fd = sockfd;
		if (epoll_ctl(ep_lis, EPOLL_CTL_ADD, sockfd, &ev) == -1) {
			perror("epoll_ctl");
			exit(1);
		}
	}

	int s = pthread_barrier_wait(&barrier);

	if (s != 0 && s != PTHREAD_BARRIER_SERIAL_THREAD) {
		perror("pthread_barrier_wait");
		exit(1);
	}

	socklen_t addrlen = sizeof(peeraddr);

	while (1) {
		ready = epoll_wait(ep_lis, evlist, max_listen, 500);
		if (ready == -1) {
			perror("epoll_wait");
			exit(1);
		}

		for (i = 0; i < ready; i++) {
			if (evlist[i].events & EPOLLIN) {
				connfd = (*accept_func)(evlist[i].data.fd, (struct sockaddr *)&peeraddr, &addrlen);
				if (connfd == -1) {
					perror("accept");
					exit(1);
				}
			} else {
				if (evlist[i].events & (EPOLLHUP | EPOLLERR)) {
					perror("epoll returned EPOLLHUP | EPOLLERR");
					exit(1);
				}
			}

			if (++cnt_new[thp->thd_seq] >= MAX_FD) {

				dprintf(2, "Too many fd %d == %d, exceed buffer\n", cnt_new[thp->thd_seq], MAX_FD);
				exit(1);
			}

			if (enqueue(connfd, &buf_state) != 0) {
				dprintf(2, "enqueue failed, buffer full\n");
				exit(1);
			}

			conn_ev.data.fd = connfd;
			if (epoll_ctl(ep_conn, EPOLL_CTL_ADD, connfd, &conn_ev) == -1) {
				perror("epoll_ctl ep_conn");
				exit(1);
			}
		}

		while (close_all) {
			fd = dequeue(&buf_state);
			if (fd == -1) {
				//dprintf(2,"dequeue fail, empty\n");
				sleep (1);
				break;
			}
			if (close(fd) == -1) {
				perror("server close");
			}
			cnt_closed[thp->thd_seq]++;
		}
	}

	/* Block this thread, should not reach here */
	if (pthread_mutex_lock(&mtx) != 0) {
		perror("connect");
		exit(1);
	}

	if (pthread_cond_wait(&cond, &mtx) != 0) {
		perror("pthread_cond_wait");
		exit(1);
	}

	if (pthread_mutex_unlock(&mtx) != 0) {
		perror("pthread_mutex_unlock");
		exit(1);
	}
}

count_t cnt_add(void)
{
	int i;
	count_t val = {0};

	for (i = 0; cnt_new[i]; i++)
		val.new += cnt_new[i];

	for (i = 0; cnt_closed[i]; i++)
		val.closed += cnt_closed[i];

	for (i = 0; cnt_nbytes[i]; i++)
		val.nbytes += cnt_nbytes[i];

	return val;
}

void usage(char *argv[])
{
	printf("\n");
	printf(" Usage: %s -H <serIp1[,serIp2,serIp3...]> -P <portMin-portMax> [-t|-u|-s|-b <size>]\n", argv[0]);
	printf(" -H	specify one or more server addresses, separate by ','. one addr for each thread\n");
	printf(" -P	specify server port range to listen on, separate by '-'\n");
	printf(" -b	set \"Throughput mode\" recv BUFFER size(equal to the recv size per call) Useful when you need to adjust the reception performance\n");
	printf(" -t	TCP mode (default)\n");
	printf(" -u	UDP mode\n");
	printf(" -s	SCTP mode\n");
	printf("\n");
	printf(" Singals that support runtime configuration\n");
	printf(" Close_All connections on/off    kill -s %d <pid>`\n", (int)SIGUSR1);
	printf("\n");
	printf("Example:\n");
	printf("%s -t -H 10.0.1.100,10.0.1.101,10.0.1.102 -P 1001-1500\n", argv[0]);
	printf("%s -t -H 2000::100,2000::101 -P 1001-1500\n", argv[0]);
}

int main(int argc, char *argv[])
{
	char *ser_port_range = NULL;
	char *ser_addrs = NULL;
	char *ser_addr[MAX_TRD] = {0};
	char *proto = "tcp";
	int opt, i, s, num_threads, sysfd;
	char nr_open[100] = {0};
	ssize_t n;

	if (argc < 2) {
		usage(argv);
		exit(1);
	}

	/* capital config Receiver ,lowercase config Sender */
	while ((opt = getopt(argc, argv, "H:P:b:tus")) != -1) {
		switch (opt) {
		case 'H':
			ser_addrs = optarg;
			for (i = 0; ser_addrs; i++)
				ser_addr[i] = next_opt(&ser_addrs);

			num_threads = i;
			/* judge ipv4/6 by find ':' in the first address string */
			addr_family = strchr(ser_addr[0], ':') ? AF_INET6 : AF_INET;
			break;
		case 'P':
			ser_port_range = optarg;
			ser_port_min = next_opt(&ser_port_range);
			ser_port_max = next_opt(&ser_port_range);
			ser_port_max = (!ser_port_max) ? ser_port_min : ser_port_max;
			//printf("server: ser_port_min = %s,ser_port_max = %s\n",ser_port_min, ser_port_max);
			break;
		case 't':
			proto = "tcp";
			IS_TCP = 1;
			sock_type = SOCK_STREAM;
			accept_func = accept;
			sock_protocol = IPPROTO_TCP;
			break;
		case 'u':
			proto = "udp";
			IS_UDP = 1;
			sock_type = SOCK_DGRAM;
			accept_func = udp_accept;
			sock_protocol = IPPROTO_UDP;
			break;
		case 's':
			proto = "sctp";
			IS_SCTP = 1;
			sock_type = SOCK_STREAM;
			accept_func = accept;
			sock_protocol = IPPROTO_SCTP;
			break;
		case 'b':
			BUFFER_SIZE = (size_t) atoi(optarg);
			break;
		default:
			dprintf(2, "Invalid parameter, exit");
			usage(argv);
			exit(1);
		}
	}

	sysfd = open("/proc/sys/fs/nr_open", O_RDONLY);
	if (sysfd < 1)
		perror("open /proc/sys/fs/nr_open");

	n = (read(sysfd, nr_open, 100));
	if (n < 0) {
		perror("read /proc/sys/fs/nr_open");
		exit(1);
	}
	//printf("Set RLIMIT_NOFILE = %d\n", atoi(nr_open));

	struct rlimit limit;

	limit.rlim_cur = (rlim_t)atoi(nr_open);
	limit.rlim_max = (rlim_t)atoi(nr_open);
	if (setrlimit(RLIMIT_NOFILE, &limit) != 0) {
		printf("setrlimit() failed with errno=%d\n", errno);
		exit(1);
	}

	s = pthread_barrier_init(&barrier, NULL, num_threads + 1);
	if (s != 0) {
		perror("pthread_barrier_init");
		exit(1);
	}

	pthread_t threads[MAX_TRD];
	thdp_t thdp[MAX_TRD];

	for (i = 0; i < num_threads; i++) {
		/* create connfds epoll instance */
		ep_conns[i] = epoll_create(5);
		if (ep_conns[i] == -1) {
			perror("epoll_create connfd");
			exit(1);
		}

		thdp[i].addrp = ser_addr[i];
		thdp[i].thd_seq = i;
		if (pthread_create(&threads[i], NULL, (void *)handle_peer_new, &thdp[i]) != 0)
			perror("pthread_create");
		if (pthread_create(&threads[i], NULL, (void *)handle_peer_close_or_send, &thdp[i]) != 0)
			perror("pthread_create");
	}

	/* barrier, to make sure all the threads are ready
	 * to accept connections, then send semaphore.
	 */
	s = pthread_barrier_wait(&barrier);
	if (s != 0 && s != PTHREAD_BARRIER_SERIAL_THREAD) {
		perror("pthread_barrier_wait");
		exit(1);
	}

	struct sigaction sa;
	sigset_t sa_mask;

	sigemptyset(&sa.sa_mask);
	sa.sa_flags = 0;
	sa.sa_handler = sg_handler;

	if (sigaction(SIGUSR1, &sa, NULL) != 0) {
		perror("sigaction");
		exit(1);
	}

	printf("\e[0;32mSERVER: Switch on/off close_all conns by `kill -s %d %d`\e[0m\n\n", (int)SIGUSR1, (int)getpid());
	fflush(NULL);

/*
	sem_t *sem_id;

	sem_id = sem_open("ready_to_connect", O_CREAT, 0600, 0);
	if (sem_id == SEM_FAILED)
		perror("sem_open");

	if (sem_post(sem_id) < 0)
		perror("sem_post");
*/

	count_t bef, aft;

	while (1) {
		bef = cnt_add();
		sleep(1);
		aft = cnt_add();

		if (Throughput) {
			printf("\e[0;32mReceived: %0.2f MBytes/sec, RECVBUF=%d \e[0m\n", (aft.nbytes - bef.nbytes) / (float)1000000, BUFFER_SIZE);
			Throughput = 0;
		}
		else {
			printf("\e[0;32m%d %s connections, %d cps (new) %d cps (closed)\e[0m\n", aft.new - aft.closed, proto, aft.new - bef.new, aft.closed - bef.closed);
		}
		fflush(NULL);
	}

	/* Wait all threads to finish */
	for (i = 0; i < num_threads; i++) {
		if (pthread_join(threads[i], NULL) != 0)
			perror("pthread_join");
	}
}
