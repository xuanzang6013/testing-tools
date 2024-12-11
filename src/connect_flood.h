#ifndef _CONNECT_FLOOD_H
#define _CONNECT_FLOOD_H  1

#ifndef MAX_FD
#define MAX_FD 10000000
#endif

#define MAX_TRD 1000

int IS_TCP;
int IS_UDP;
int IS_SCTP;

typedef struct buff_state {
	int *min;
	int *max;
	int *head;
	int *end;
} buff_t;

typedef struct thread_param {
	char *addrp;
	/* thread sequence */
	int thd_seq;
} thdp_t;

int create_queue(buff_t *st)
{
	int *stor;

	stor = (int *)calloc(MAX_FD, sizeof(int));
	if (!stor) {
		perror("calloc");
		return -1;
	}
	st->min = st->head = st->end = stor;
	st->max = stor + MAX_FD - 1;
	return 0;
}

int enqueue(int fd, buff_t *st)
{
	if (st->end + 1 == st->head)
		return -1; /* full */
	*st->end = fd;
	st->end += 1;
	if (st->end == st->max)
		st->end = st->min;
	return 0;
}

int dequeue(buff_t *st)
{
	int fd;

	if (st->head == st->end)
		return -1; /* empty */
	fd = *st->head;
	st->head++;
	return fd;
}

/* Read Only Traversal*/
int travelqueue(buff_t *st, int** p)
{
	int ret;
	if (!*p)
		*p = st->head;
	ret = **p;
	if (*p == st->end - 1)
		*p = st->head;
	else if (*p == st->max)
		*p = st->min;
	else
		(*p)++;
	return ret;
}

char *next_opt(char **s)
{
	char *sbegin = *s;
	char *p;

	if (!sbegin)
		return NULL;
	for (p = sbegin; *p; p++) {
		if (*p == ',' || *p == '-') {
			*p = '\0';
			*s = p + 1;  /* next param */
			return sbegin;
		}
	}
	*s = NULL; /* the last time */
	return sbegin;
}

int get_core_num()
{
        FILE *f;
        char s[10];
        int n;
        f = popen("nproc", "r");
	if (!f)
        {
                perror("popen");
                exit(1);
        }
        if (!(fgets(s, 10, f)))
        {
                perror("fgets");
                exit (1);
        }
        n = atoi(s);
        printf ("num of cpu is %d, start %d threads\n",n,n);
	return n;
}

#endif /* _CONNECT_FLOOD_H */
