These script is for testing how much conntrack affect tcp establish rate
on two baremetal.
Topo:

┌─────────────┐
│             │  machine 1
│  Forward    │ dell-per740-42.rhts.eng.pek2.redhat.com
│ (conntrack) │ mlx5_core
└───┬─────┬───┘
    │     │
    │     │
    │     │
    │     │
    │     │
    │     │
┌───┴──┬──┴───┐
│      │      │ machine 2
│Server│Client│ dell-per740-34.rhts.eng.pek2.redhat.com
│      │      │ ixgbe
│netns1│netns2│
└──────┴──────┘

TCP estab rate:
1 thread
Without conntrack                     With conntrack
4512  tcp established, 4512 cps       4092 tcp established, 4092 cps,
9126  tcp established, 4614 cps       8349 tcp established, 4257 cps,
13796 tcp established, 4670 cps       12553 tcp established, 4204 cps,
18473 tcp established, 4677 cps       16793 tcp established, 4240 cps,
23136 tcp established, 4663 cps       20997 tcp established, 4204 cps,
27859 tcp established, 4723 cps       25299 tcp established, 4301 cps,
32511 tcp established, 4652 cps       29565 tcp established, 4266 cps,
37179 tcp established, 4668 cps       33796 tcp established, 4231 cps,
41790 tcp established, 4611 cps       38084 tcp established, 4288 cps,
46454 tcp established, 4663 cps       42294 tcp established, 4210 cps,
51000 tcp established, 4546 cps       46614 tcp established, 4319 cps,
90%

6 threads
Without conntrack                     With conntrack
54230  tcp established, 54230 cps     51558  tcp established, 51558 cps
112356 tcp established, 58126 cps     106782 tcp established, 55224 cps
171358 tcp established, 59000 cps     160694 tcp established, 53912 cps
230835 tcp established, 59476 cps     215780 tcp established, 55086 cps
289483 tcp established, 58645 cps     271174 tcp established, 55394 cps
347228 tcp established, 57745 cps     327444 tcp established, 56270 cps
405345 tcp established, 58115 cps     383423 tcp established, 55979 cps
463454 tcp established, 58108 cps     439656 tcp established, 56232 cps
521278 tcp established, 57820 cps     495739 tcp established, 56082 cps
579930 tcp established, 58652 cps     549965 tcp established, 54224 cps
638584 tcp established, 58651 cps     604708 tcp established, 54741 cps
696325 tcp established, 57739 cps     659888 tcp established, 55178 cps
753615 tcp established, 57287 cps     715813 tcp established, 55925 cps
811616 tcp established, 58001 cps     771152 tcp established, 55336 cps
92%

12 threads
Without conntrack                        With conntrack
95465   tcp established, 95465  cps      90777   tcp established, 90777 cps
201680  tcp established, 106215 cps      190843  tcp established, 100064 cps
305305  tcp established, 103623 cps      291737  tcp established, 100891 cps
408626  tcp established, 103319 cps      392314  tcp established, 100577 cps
508767  tcp established, 100136 cps      490435  tcp established, 98116 cps
609566  tcp established, 100796 cps      586603  tcp established, 96165 cps
710303  tcp established, 100734 cps      684321  tcp established, 97715 cps
810380  tcp established, 100073 cps      780583  tcp established, 96259 cps
912837  tcp established, 102455 cps      877625  tcp established, 97042 cps
1014815 tcp established, 101972 cps      972477  tcp established, 94846 cps
1117904 tcp established, 103087 cps      1065548 tcp established, 93070 cps
1221086 tcp established, 103176 cps      1161241 tcp established, 95687 cps
1323868 tcp established, 102778 cps      1257155 tcp established, 95909 cps
1427755 tcp established, 103881 cps      1353200 tcp established, 96041 cps
1531371 tcp established, 103615 cps      1450163 tcp established, 96961 cps
1633290 tcp established, 101918 cps      1547034 tcp established, 96868 cps
1735043 tcp established, 101749 cps      1643063 tcp established, 96028 cps
1836814 tcp established, 101770 cps      1739605 tcp established, 96538 cps
97%


Drawing tool: https://asciiflow.com/
