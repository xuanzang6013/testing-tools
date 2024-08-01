#! /bin/bash

# Possible input are
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

input=$1
test -z $input && {
	echo "\$1 can't be empty"
}

_all_arch="aarch64 ppc64le s390x x86_64"
version=$(echo $input | grep -o -E '[0-9]*\.[0-9]*\.[0-9]*\-[0-9]*(\.[0-9]*)*\.[a-z][a-z][0-9]*(_[0-9]*)?' 2>/dev/null) #5.14.0-484.el9

for i in ${_all_arch}
do
	if [[ "$input" =~ "$i" ]]
	then
		arch=$i
	fi
done
arch=${arch:-x86_64}

echo $input | grep -q rt && {
	bool_rt=true
} || {
	bool_rt=false
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
