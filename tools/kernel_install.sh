#! /bin/bash

usage() 
{
echo "e.g."
echo "$0 kernel-5.14.0-487.el9.x86_64"
echo
echo "
# Possible input example
#
# 5.14.0-484.el9.x86_64+debug
# 5.14.0-484.el9.x86_64+rt
# kernel-5.14.0-484.el9
# kernel-5.14.0-484.el9.x86_64
# kernel-debug-5.14.0-484.el9
# kernel-rt-5.14.0-484.el9
# kernel-rt-debug-5.14.0-484.el9
#
# Zstream kernel-5.14.0-427.29.1.el9_4
#
#
# 6.10.0-15.el10.x86_64
# /boot/vmlinuz-6.10.0-15.el10.x86_64+rt-debug
# 6.10.0-15.el10.x86_64+rt-debug
#
# 3.10.0-1160.119.1.el7.x86_64
#
# LINK: https://download-node-02.eng.bos.redhat.com/brewroot/packages/kernel/5.14.0/487.el9/x86_64/kernel-5.14.0-487.el9.x86_64.rpm
# RT: kernel-rt-4.18.0-193.134.1.rt13.185.el8_2.x86_64.rpm
"
}

input=$1
test -z $input && {
	echo "\$1 can't be empty"
	usage
	exit 1
}

_all_arch="aarch64 ppc64le s390x x86_64"
version=$(echo $input | grep -o -E '[0-9]*\.[0-9]*\.[0-9]*\-[0-9]*(\.[0-9]*)*(\.rt[0-9]*(\.[0-9]*))?\.[a-z]{2}[0-9]*(_[0-9]*)?' 2>/dev/null)

for i in ${_all_arch}
do
	if [[ "$input" =~ "$i" ]]
	then
		arch=$i
		break
	fi
done
arch=${arch:-x86_64}

echo $input | grep -q rt && {
	bool_rt=true
	f1=kernel-rt
} || {
	bool_rt=false
	f1=kernel
}

echo $input | grep -q debug && {
	bool_debug=true
} || {
	bool_debug=false
}

name=kernel
$bool_rt && name+='-rt'
$bool_debug && name+='-debug'

echo version = $version 
echo arch = $arch
echo name = $name

[[ -n "$version" && -n "$arch" && -n "$name" ]] || {
	echo "$0 have bug, exit..."
	exit 1
}

f2=${version%%-*}
f3=${version#*-}

prefix="https://download-node-02.eng.bos.redhat.com/brewroot/packages/$f1/$f2/$f3/$arch/"
echo prefix = $prefix

#wget -nv --no-check-certificate $prefix/${name}-${version}.${arch}.rpm
#wget -nv --no-check-certificate $prefix/${name}-core-${version}.${arch}.rpm
#wget -nv --no-check-certificate $prefix/${name}-modules-${version}.${arch}.rpm
#wget -nv --no-check-certificate $prefix/${name}-modules-extra-${version}.${arch}.rpm
#wget -nv --no-check-certificate $prefix/${name}-modules-internal-${version}.${arch}.rpm
#wget --spider --quiet --tries=1 $prefix/${name}-modules-core-${version}.${arch}.rpm && {
#	wget -nv --no-check-certificate $prefix/${name}-modules-core-${version}.${arch}.rpm
#}

yum -y localinstall ${name}-*.rpm || exit 1


