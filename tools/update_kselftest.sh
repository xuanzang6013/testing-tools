#! /bin/bash -x

v2p()
{
	case $1 in
		el8)  echo "/home/fedora/repos/centos-stream-8";;
		el9)  echo "/home/fedora/repos/centos-stream-9";;
		el10) echo "/home/fedora/repos/centos-stream-10";;
		upstream) echo "/home/fedora/repos/linux";;
	esac
}

mount |grep netqe-bj.usersys.redhat.com || \
sudo mount -t nfs netqe-bj.usersys.redhat.com:/home/share/yiche /mnt/netqe-bj.usersys.redhat.com || exit 1

for ver in el8 el9 el10 upstream
do
	pushd $(v2p $ver)
	git pull
	tar -zcf /home/fedora/kselftests.$ver.tar.gz -C $PWD/tools/testing/ selftests
	cp /home/fedora/kselftests.$ver.tar.gz /mnt/netqe-bj.usersys.redhat.com && \
	rm /home/fedora/kselftests.$ver.tar.gz
	popd
done
