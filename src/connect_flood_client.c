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
 * Switch on/off close_soon  `kill -s 10 15250` close directly after connected.
 * Pause/Continue            `kill -s 12 15250` pause, ready to handle peer close.
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

#define MAX_IP 1000
#define NUM_FD 30000000
#define IS_TCP 6
#define IS_UDP 17
#define IS_SCTP 132

char *cli_port_min;
char *cli_port_max;
char *ser_port_min;
char *ser_port_max;
char *cli_addr[MAX_IP];
char msg[1000];
int close_soon;
int block_flag;
int num_cli_ip;
sa_family_t addr_family;
int proto = IS_TCP;
int sock_protocol;
int sock_type = SOCK_STREAM;
int (*connect_func)(int sockfd, const struct sockaddr *s_addr, socklen_t len);

char *next_opt(char **s)
{
	char *sbegin = *s;
	char *p;

	if (!sbegin)
		return NULL;

	for (p = sbegin; *p; p++) {
		if (*p == ',' || *p == '-') {
			*p = '\0';
			*s = p + 1;  //point to next param
			return sbegin;
		}
	}
	*s = NULL;  //to NULL last time.
	return sbegin;
}

void sg_handler(int sig)
{
	if (sig == SIGUSR1) {
		close_soon = (close_soon) ? 0 : 1;
		printf("\e[1;31mCLIENT:close_soon = %d \e[0m\n", close_soon);
		fflush(NULL);
		return;
	}
	block_flag = (block_flag) ? 0 : 1;
	printf("\e[1;31mCLIENT:block_flag = %d \e[0m\n", block_flag);
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

int udp_connect(int sockfd, const struct sockaddr *addr, socklen_t len)
{
	char buf[100];
	struct timeval tv = {
		.tv_sec = 10
	};
	if (setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)) == -1) {
		perror("setsockopt");
		exit(1);
	}
	if (connect(sockfd, addr, len) == -1) {
		perror("connect");
		return -1;
	}

	if (send(sockfd, "SYN", 3, 0) == -1) {
		perror("CLIENT: UDP send");
		return -1;
	}
	// Don't send too fast, wait server write back.
	if (recv(sockfd, buf, sizeof(buf), 0) == -1) {
		//perror("CLIENT: UDP recv");
		return -1;
	}
	if (send(sockfd, "ACK", 3, 0) == -1) {
		perror("UDP send");
		return -1;
	}
	return 0;
}

void *worker(void *addrstr)
{
	int sockfd, s_port, c_port, i, fd, ready, epfd, enable;

	// create epoll instance
	int num_ser_port = atoi(ser_port_max) - atoi(ser_port_min) + 1;
	int num_cli_port = atoi(cli_port_max) - atoi(cli_port_min) + 1;
	int max_events = 100000;
	struct epoll_event ev;
	struct epoll_event evlist[max_events];

	epfd = epoll_create(5);
	if (epfd == -1) {
		perror("epoll_create");
		exit(1);
	}
	ev.events = EPOLLRDHUP; /* Only interested in close events */

	/* Support for both IPv4 and IPv6.
	 * sockaddr_storage: Can contain both sockaddr_in and sockaddr_in6
	 */
	struct sockaddr_storage seraddr, cliaddr;
	void *s_addr, *c_addr;

	bzero(&cliaddr, sizeof(cliaddr));
	bzero(&seraddr, sizeof(seraddr));

	//For better performance, config these once here, but not in deep loop.
	s_addr = set_sockaddr(addrstr, 0, &seraddr);
	s_addr = set_sockaddr(NULL, 0, &seraddr);
	c_addr = set_sockaddr(NULL, 0, &cliaddr);

	snprintf(msg, sizeof(msg), "Hello Server...\n");
	/*Loop for client ports*/
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

				ev.data.fd = sockfd;
				if (epoll_ctl(epfd, EPOLL_CTL_ADD, sockfd, &ev) == -1) {
					perror("epoll_ctl ADD");
					exit(1);
				}

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
						if (evlist[i].events & EPOLLRDHUP) { // peer closing
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

				if (close_soon) {
					if (close(sockfd) == -1) {
						perror("close_soon");
					}
					continue;
				}
			}
		}
	}
}

void usage(char *argv[])
{
	printf(" Usage: %s -H <serIp1[,serIp2,serIp3...]> -P <portMin-portMax> -h <cliIp1[,cliIp2,cliIp3...]> -p <portMin-portMax> [-t|-u|-s]\n", argv[0]);
	printf(" -H	specify one or more server addresses, separate by ','\n");
	printf(" -h	specify one or more client addresses, separate by ','\n");
	printf(" -p	specify client port range, separate by '-'\n");
	printf(" -P	specify server port range, separate by '-'\n");
	printf(" -t	TCP mode (default)\n");
	printf(" -u	UDP mode\n");
	printf(" -s	SCTP mode\n\n");
	printf(" -c	close_soon: close connect soon, right after established\n\n");
	printf("Example:\n");
	printf("%s -t -H 10.0.1.100,10.0.1.101,10.0.1.102 -P 1001-1500 -h 10.0.2.101,10.0.2.102 -p 50001-60000\n", argv[0]);
	printf("%s -t -H 2000::100,2000::101 -P 1001-1500 -h 2001::100,2001::101 -p 50001-60000\n", argv[0]);
}

int main(int argc, char *argv[])
{
	char *cli_port_range = NULL;
	char *ser_port_range = NULL;
	char *ser_addrs = NULL;
	char *cli_addrs = NULL;
	ssize_t n;
	int opt, i, sysfd;
	char nr_open[100] = {0};
	// Capitals config Local ,lowercase config remote
	while ((opt = getopt(argc, argv, "H:h:P:p:tusc")) != -1) {
		switch (opt) {
		case 'H':
			ser_addrs = optarg;
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
			proto = IS_TCP;
			sock_type = SOCK_STREAM;
			connect_func = connect;
			sock_protocol = IPPROTO_TCP;
			break;
		case 'u':
			proto = IS_UDP;
			sock_type = SOCK_DGRAM;
			connect_func = udp_connect;
			sock_protocol = IPPROTO_UDP;
			break;
		case 's':
			proto = IS_SCTP;
			sock_type = SOCK_STREAM;
			connect_func = connect;
			sock_protocol = IPPROTO_SCTP;
			break;
		case 'c':
			close_soon = 1;
			printf("\e[0;34mCLIENT: close soon is on\e[0m\n");
			break;
		default:
			dprintf(2, "Invalid parameter\n");
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
		return 1;
	}

	sem_t *sem_id;

	sem_id = sem_open("ready_to_connect", O_CREAT, 0600, 0);
	if (sem_id == SEM_FAILED)
		perror("sem_open");

	if (sem_wait(sem_id) < 0)
		perror("sem_wait in client");

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

	printf("\e[0;34mCLIENT: Switch on/off close_soon  `kill -s %d %d` \e[0m\n", (int)SIGUSR1, (int)getpid());
	printf("\e[0;34mCLIENT: Pause/Continue            `kill -s %d %d` \e[0m\n", (int)SIGUSR2, (int)getpid());
	fflush(NULL);

	pthread_t threads[MAX_IP];

	for (i = 0; ser_addrs; i++) {
		if (pthread_create(&threads[i], NULL, (void *)worker, next_opt(&ser_addrs)) != 0)
			perror("pthread_create");
	}
	int num_ser_ip = i;

	//Wait all threads to join
	for (i = 0; i < num_ser_ip; i++) {
		if (pthread_join(threads[i], NULL) != 0)
			perror("pthread_join");
	}
}
