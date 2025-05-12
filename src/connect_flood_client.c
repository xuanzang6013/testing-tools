// SPDX-License-Identifier: GPL-2.0
/* This is a connection flood tool aim to create a large
 * number of tcp/udp/sctp connections fastly,
 * and to stress conntrack subsystem in linux.
 *
 * Program will create a thread for each remote address to connect
 * In each thread, scan server port, client ip, then client port.
 * Capture SIGUSR1 to active close right after connect,
 * SIGUSR2 to pause connect in threads.
 *
 * e.g.
 * connect_flood_client -H 10.0.1.100,10.0.1.101,10.0.1.102 -P 1001-1500 \
 * -h 10.0.2.101,10.0.2.102,10.0.2.103 -p 50001-60000 -t
 * Switch on/off close_soon  `kill -s 10 <pid>` close directly after connected.
 * Pause/Continue            `kill -s 12 <pid>` pause, ready to handle peer close.
 * Enter Throughput mode     `kill -s 34 <pid>` client do best to send data in NONBLOCK mode.
 *
 *  Authors: Chen Yi <yiche@redhat.com>
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

#define MAX_CLI_IP 1000

/* recv buffer size default 128k */
size_t BUFFER_SIZE = 0x20000;

char *cli_port_min;
char *cli_port_max;
char *ser_port_min;
char *ser_port_max;
char *cli_addr[MAX_CLI_IP];
char udpBuf[100];
int close_soon;
int *_close_all[MAX_TRD];
int block_flag;
int num_cli_ip;
sa_family_t addr_family;
int sock_protocol;
int sock_type = SOCK_STREAM;
int (*connect_func)(int sockfd, const struct sockaddr *s_addr, socklen_t len);

int Throughput;

void sg_handler(int sig)
{
	int i;
	if (sig == SIGUSR1) {
		close_soon = (close_soon) ? 0 : 1;
		if (close_soon)
			printf("\e[1;31mCLIENT: Switch on Close_soon mode\e[0m\n");
		else
			printf("\e[1;31mCLIENT: Switch off Close_soon mode\e[0m\n");
	}
	if (sig == SIGUSR2) {
		block_flag = (block_flag) ? 0 : 1;
		if (block_flag)
			printf("\e[1;31mCLIENT: Pausing...\e[0m\n");
		else
			printf("\e[1;31mCLIENT: Continue...\e[0m\n");
	}
	if (sig == SIGRTMIN) {
		Throughput = (Throughput) ? 0 : 1;
		if (Throughput) {
			block_flag = 0;
			printf("\e[1;31mCLIENT: Switch to Throughput mode. SENDBUF = %d, (set by the '-b' option)\e[0m\n", BUFFER_SIZE);
		}
		else {
			block_flag = 1;
			printf("\e[1;31mCLIENT: Switch off Throughput mode. Pausing...\e[0m\n");
		}
	}
	if (sig == SIGRTMIN + 1) {
		/* Tell all threads close their connections */
		for (i = 0; _close_all[i]; i++) {
			*_close_all[i] = 1;
		}
		block_flag = 0;
		Throughput = 0;
		printf("\e[1;31mCLIENT: Closing all connections...\e[0m\n");
	}
	fflush(NULL);
}

void *set_sockaddr(const char *addr, int port, struct sockaddr_storage *sockaddr)
{
	struct sockaddr_in *addr4 = (struct sockaddr_in *)sockaddr;
	struct sockaddr_in6 *addr6 = (struct sockaddr_in6 *)sockaddr;

	if (addr_family == AF_INET) {
		//port setting more likely hit
		if (port != 0) {
			addr4->sin_port = htons(port);
			return (void *)addr4;
		}
		if (addr) {
			inet_pton(AF_INET, (char *)addr, &addr4->sin_addr);
			return (void *)addr4;
		}
		addr4->sin_family = AF_INET;
		return (void *)addr4;
	}
	if (addr_family == AF_INET6) {
		if (port != 0) {
			addr6->sin6_port = htons(port);
			return (void *)addr6;
		}
		if (addr) {
			inet_pton(AF_INET6, (char *)addr, &addr6->sin6_addr);
			return (void *)addr6;
		}
		addr6->sin6_family = AF_INET6;
		return (void *)addr6;
	}
}

int udp_close_active(int fd)
{
	/* active close: Send the "FIN" first */
	int nbytes;
	if (send(fd, "UDPFIN", 6, 0) == -1) {
		perror("udp_close_active: UDP send");
		return -1;
	}
	nbytes = recv(fd, udpBuf, sizeof(udpBuf), 0);
	/* The length of "ACK,UDPFIN" */
	if (nbytes == 10) {
		if (send(fd, "LASKACK", 7, 0) == -1) {
			perror("udp_close_active: UDP send");
			return -1;
		}
		close(fd);
		return 0;
	}
	else if (nbytes == -1) {
		perror("udp_close_active: UDP recv");
	}
	else
		printf("warning: udp_close_active: ACK,UDPFIN didn't received\n");
	return -1;
}

struct timeval tv = {
	.tv_sec = 1,
	.tv_usec = 300000
};

int udp_connect(int sockfd, const struct sockaddr *addr, socklen_t len)
{
	if (setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)) == -1) {
		perror("setsockopt");
		return -1;
	}
	if (connect(sockfd, addr, len) == -1) {
		perror("connect");
		return -1;
	}

	if (send(sockfd, "SYN", 3, 0) == -1) {
		perror("CLIENT: UDP send");
		return -1;
	}
	/* Don't send too fast, wait server write back */
	if (recv(sockfd, udpBuf, sizeof(udpBuf), 0) == -1) {
		//perror("CLIENT: UDP recv");
		return -1;
	}
	if (send(sockfd, "ACK", 3, 0) == -1) {
		perror("UDP send");
		return -1;
	}
	return 0;
}

void fill_buf(char* buffer)
{
	int i, repeat;
	char * payload;
	size_t len;
	payload = "connection flood tool payload\n";
	len = strlen(payload);
	repeat = sizeof(buffer) / len;

	memset(buffer, 0, sizeof(buffer));
	for(i = 0; i < repeat; i++) {
		memcpy(buffer + (i * len), payload, len);
	}
}

void *worker(void *p)
{
	thdp_t *thp = (thdp_t *)p;
	char * addrstr = thp->addrp;

	buff_t buf_state;
	int fd, sockfd, sendfd, epfd;
	int s_port, c_port;
	int i, ready, enable, close_all = 0, close_flag_sum = 0;
	int * travel_p = NULL;

	_close_all[thp->thd_seq]= &close_all;

	/* create epoll instance */
	int num_ser_port = atoi(ser_port_max) - atoi(ser_port_min) + 1;
	int num_cli_port = atoi(cli_port_max) - atoi(cli_port_min) + 1;
	int max_events = 100000;
	struct epoll_event ev;
	struct epoll_event evlist[max_events];
	char SNDBUF[BUFFER_SIZE];
	fill_buf(SNDBUF);

	epfd = epoll_create(5);
	if (epfd == -1) {
		perror("epoll_create");
		exit(1);
	}

	/* Only interested in close events */
	ev.events = EPOLLRDHUP;

	/* this is a per thread instance */
	if (create_queue(&buf_state) != 0) {
		dprintf(2, "calloc failed\n");
		exit(1);
	}

	/* Support for both IPv4 and IPv6.
	 * sockaddr_storage: Can contain both sockaddr_in and sockaddr_in6
	 */
	struct sockaddr_storage seraddr, cliaddr;
	void *s_addr, *c_addr;

	bzero(&cliaddr, sizeof(cliaddr));
	bzero(&seraddr, sizeof(seraddr));

	/* For better performance, config these once here, but not in deep loop */
	s_addr = set_sockaddr(addrstr, 0, &seraddr);
	s_addr = set_sockaddr(NULL, 0, &seraddr);
	c_addr = set_sockaddr(NULL, 0, &cliaddr);

	/* Loop for client ports */
	for (c_port = atoi(cli_port_min); c_port <= atoi(cli_port_max); c_port++) {
		c_addr = set_sockaddr(NULL, c_port, &cliaddr);
		/* Loop for client ip */
		for (i = 0; i < num_cli_ip; i++) {
			c_addr = set_sockaddr(cli_addr[i], 0, &cliaddr);
			/* Loop for server ports */
			for (s_port = atoi(ser_port_min); s_port <= atoi(ser_port_max); s_port++) {
				s_addr = set_sockaddr(NULL, s_port, &seraddr);

				sockfd = socket(addr_family, sock_type, sock_protocol);
				if (sockfd == -1) {
					perror("socket");
					exit(1);
				}

				enable = 1;
				if (setsockopt(sockfd, SOL_SOCKET, SO_REUSEADDR, &enable, sizeof(int)) < 0) {
					perror("setsockopt(SO_REUSEADDR) failed");
					exit(1);
				}

				if (bind(sockfd, (struct sockaddr *)c_addr, sizeof(struct sockaddr_storage)) == -1) {
					perror("CLIENT: bind");
					exit(1);
				}

				if ((*connect_func)(sockfd, (const struct sockaddr *)s_addr, sizeof(seraddr)) == -1) {
					//perror("connect error");
					//dprintf(2, "CLIENT:s_addr = %s, cli_addr = %s, s_port = %d, c_port = %d\n", addrstr, cli_addr[i], s_port, c_port);
					continue;
				}

				if (close_soon) {
					if (IS_UDP) {
						if (udp_close_active(sockfd) == -1)
							perror("udp_close_active");
					}
					else {
						if (close(sockfd) == -1)
							perror("close_soon");
					}
				}
				else {
					if (enqueue(sockfd, &buf_state) != 0) {
						dprintf(2, "enqueue failed, buffer full\n");
						exit(1);
					}

					ev.data.fd = sockfd;
					if (epoll_ctl(epfd, EPOLL_CTL_ADD, sockfd, &ev) == -1) {
						perror("epoll_ctl ADD");
						exit(1);
					}
				}

				while (close_all) {
					fd = dequeue(&buf_state);
					if (fd == -1) {
						//dprintf(2,"dequeue empty\n");
						close_all = 0;
						block_flag = 1;
						/* Judge all threads finished closing */
						for (i = 0; _close_all[i]; i++) {
							close_flag_sum += *_close_all[i];
						}
						if (!close_flag_sum)
							printf("\e[1;31mCLIENT: All closed. Pausing...\e[0m\n");
						break;
					}
					if (IS_UDP) {
						if (udp_close_active(fd) == -1)
							perror("udp_close_active");
					}
					else {
						if (close(fd) == -1)
							perror("client close:");
					}
				}

				while (Throughput) {
					sendfd = travelqueue(&buf_state, &travel_p);
					//dprintf(2,"throughput send on fd = %d\n", sendfd);
					if (sendfd < 0)
						dprintf(2, "travelqueue error! \n");

					/* set NONBLOCK mode */
					int f_state = fcntl(sendfd, F_GETFL, 0);
					if (f_state == -1) {
						perror("fcntl F_GETFL");
					}

					if (fcntl(sendfd, F_SETFL, f_state | O_NONBLOCK) == -1) {
						perror("fcntl F_SETFL");
					}

					while (1) {
						ssize_t bytes_sent = send(sendfd, SNDBUF, BUFFER_SIZE, 0);
						//dprintf (2,"%d bytes sent\n", bytes_sent);
						if (bytes_sent < 0) {
							if (errno == EAGAIN) {
								//dprintf (2,"send EAGAIN: Resource temporarily unavailable\n");
								break;
							}
							else {
								perror("send failed exit Thoughput mode");
								printf("sendfd = %d\n", sendfd);
								block_flag = 1;
								printf("\e[1;31mCLIENT: Pausing \e[0m\n");
								goto out_Throughput;
							}
						}
						/* UDP socket rarely return EAGAIN, so force move to next fd */
						if (IS_UDP)
							break;
					}
				}
				out_Throughput:

				/*
				 * When receive SIGUSR2 block here
				 * ready to handle peer closing
				 */
				while (block_flag) {
					ready = epoll_wait(epfd, evlist, max_events, 1000);
					if (ready == -1) {
						perror("epoll_wait");
						exit(1);
					}
					for (i = 0; i < ready; i++) {
						/* peer closing */
						if (evlist[i].events & EPOLLRDHUP) {
							if (epoll_ctl(epfd, EPOLL_CTL_DEL, evlist[i].data.fd, &ev) == -1) {
								perror("epoll_ctl DEL");
								exit(1);
							}
							if (close(evlist[i].data.fd) == -1) {
								perror("client handle close");
							}

						} else {
							if (evlist[i].events & (EPOLLHUP | EPOLLERR)) {
								dprintf(2, "epoll returned EPOLLHUP | EPOLLERR\n");
								exit(1);
							}
						}
					}
				}
			}
		}
	}
}

void usage(char *argv[])
{
	printf("\n");
	printf(" Usage: %s -H <serIp1[,serIp2,serIp3...]> -P <portMin-portMax> -h <cliIp1[,cliIp2,cliIp3...]> -p <portMin-portMax> [-t|-u|-s|-b <size>]\n", argv[0]);
	printf(" -H	specify one or more server addresses, separate by ','\n");
	printf(" -P	specify server port range, separate by '-'\n");
	printf(" -h	specify one or more client addresses, separate by ','\n");
	printf(" -p	specify client port range, separate by '-'\n");
	printf(" -b     set \"Throughput mode\" send BUFFER size(qual to the send size per call) Useful when you need to adjust the sending performance\n");
	printf(" -t	TCP mode (default)\n");
	printf(" -u	UDP mode\n");
	printf(" -s	SCTP mode\n");
	printf(" -c	set close_soon at start\n");
	printf("\n");
	printf(" Singals that support runtime configuration\n");
	printf(" Close all connections         kill -s %d <pid>`\n", (int)(SIGRTMIN + 1));
	printf(" Close soon  on/off            kill -s %d <pid>`\n", (int)SIGUSR1);
	printf(" Throughput mode on/off       `kill -s %d <pid>`\n", (int)SIGRTMIN);
	printf(" Pause/Continue (block_flag)  `kill -s %d <pid>`\n", (int)SIGUSR2);
	printf("\n");
	printf("Example:\n");
	printf("%s -t -H 10.0.1.100,10.0.1.101,10.0.1.102 -P 1001-1500 -h 10.0.2.101,10.0.2.102 -p 50001-60000\n", argv[0]);
	printf("%s -t -H 2000::100,2000::101 -P 1001-1500 -h 2001::100,2001::101 -p 50001-60000\n", argv[0]);
}

int main(int argc, char *argv[])
{
	char *cli_port_range = NULL;
	char *ser_port_range = NULL;
	char *ser_addrs = NULL;
	char *ser_addr[MAX_TRD] = {0};
	char *cli_addrs = NULL;
	ssize_t n;
	int opt, i, sysfd, num_threads;
	char nr_open[100] = {0};

	if (argc < 2) {
		usage(argv);
		exit (1);
	}

	/* Capitals config Local ,lowercase config remote */
	while ((opt = getopt(argc, argv, "H:h:P:p:b:tusc")) != -1) {
		switch (opt) {
		case 'H':
			ser_addrs = optarg;
			for (i = 0; ser_addrs; i++)
				ser_addr[i] = next_opt(&ser_addrs);
			num_threads = i;
			break;
		case 'h':
			cli_addrs = optarg;
			for (i = 0; cli_addrs; i++)
				cli_addr[i] = next_opt(&cli_addrs);

			num_cli_ip = i;
			addr_family = strchr(cli_addr[0], ':') ? AF_INET6 : AF_INET;
			break;
		case 'P':
			ser_port_range = optarg;
			ser_port_min = next_opt(&ser_port_range);
			ser_port_max = next_opt(&ser_port_range);
			ser_port_max = (!ser_port_max) ? ser_port_min : ser_port_max;
			//printf("CLIENT: ser_port_min = %s,ser_port_max = %s\n",ser_port_min, ser_port_max);
			break;
		case 'p':
			cli_port_range = optarg;
			cli_port_min = next_opt(&cli_port_range);
			cli_port_max = next_opt(&cli_port_range);
			cli_port_max = (!cli_port_max) ? cli_port_min : cli_port_max;
			break;
		case 't':
			IS_TCP = 1;
			sock_type = SOCK_STREAM;
			connect_func = connect;
			sock_protocol = IPPROTO_TCP;
			break;
		case 'u':
			IS_UDP = 1;
			sock_type = SOCK_DGRAM;
			connect_func = udp_connect;
			sock_protocol = IPPROTO_UDP;
			/* assume MTU is 1500, to avoid fragment */
			BUFFER_SIZE = 1472;
			break;
		case 's':
			IS_SCTP = 1;
			sock_type = SOCK_STREAM;
			connect_func = connect;
			sock_protocol = IPPROTO_SCTP;
			break;
		case 'c':
			close_soon = 1;
			printf("\e[0;31mCLIENT: close soon is on\e[0m\n");
			break;
		case 'b':
			BUFFER_SIZE = (size_t) atoi(optarg);
			break;
		default:
			dprintf(2, "Invalid parameter\n");
			usage(argv);
			exit(1);
		}
	}

	// connect_func default
	if (!connect_func)
		connect_func = connect;

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
		return 1;
	}

/*
	sem_t *sem_id;

	sem_id = sem_open("ready_to_connect", O_CREAT, 0600, 0);
	if (sem_id == SEM_FAILED)
		perror("sem_open");

	if (sem_wait(sem_id) < 0)
		perror("sem_wait in client");
*/

	struct sigaction sa;
	sigset_t sa_mask;

	sigemptyset(&sa.sa_mask);
	sa.sa_flags = 0;
	sa.sa_handler = sg_handler;

	if (sigaction(SIGUSR1, &sa, NULL) != 0) {
		perror("sigaction, SIGUSR1");
		exit(1);
	}

	if (sigaction(SIGUSR2, &sa, NULL) != 0) {
		perror("sigaction, SIGUSR2");
		exit(1);
	}

	if (sigaction(SIGRTMIN, &sa, NULL) != 0) {
		perror("sigaction, SIGRTMIN");
		exit(1);
	}

	if (sigaction(SIGRTMIN + 1, &sa, NULL) != 0) {
		perror("sigaction, SIGRTMIN+1");
		exit(1);
	}

	printf("\e[0;34mCLIENT: Close All                    `kill -s %d %d` \e[0m\n", (int)(SIGRTMIN + 1), (int)getpid());
	printf("\e[0;34mCLIENT: Close soon on/off            `kill -s %d %d` \e[0m\n", (int)SIGUSR1, (int)getpid());
	printf("\e[0;34mCLIENT: Throughput mode on/off       `kill -s %d %d` \e[0m\n", (int)SIGRTMIN, (int)getpid());
	printf("\e[0;34mCLIENT: Pause/Continue               `kill -s %d %d` \e[0m\n", (int)SIGUSR2, (int)getpid());
	fflush(NULL);

	pthread_t threads[MAX_TRD];
	thdp_t thdp[MAX_TRD];

	for (i = 0; i < num_threads; i++) {
		thdp[i].addrp = ser_addr[i];
		thdp[i].thd_seq = i;

		if (pthread_create(&threads[i], NULL, (void *)worker, &thdp[i]) != 0)
			perror("pthread_create");
	}

	/* Wait all threads to join, block the main() */
	for (i = 0; i < num_threads; i++) {
		if (pthread_join(threads[i], NULL) != 0)
			perror("pthread_join");
	}

	printf("CLIENT exit, Bye!\n");
}
