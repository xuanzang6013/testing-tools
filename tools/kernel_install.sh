#! /bin/bash

# possible input are
# 5.14.0-484.el9.x86_64+debug
# 5.14.0-484.el9.x86_64+rt
# kernel-5.14.0-484.el9
# kernel-5.14.0-484.el9.x86_64
# kernel-debug-5.14.0-484.el9
# kernel-rt-5.14.0-484.el9
# kernel-rt-debug-5.14.0-484.el9
#
# Zstream
# kernel-5.14.0-427.29.1.el9_4
#
#
# 6.10.0-15.el10.x86_64
# /boot/vmlinuz-6.10.0-15.el10.x86_64+rt-debug
# 6.10.0-15.el10.x86_64+rt-debug
#
# 3.10.0-1160.119.1.el7.x86_64

input=$1
_all_arch="aarch64 ppc64le s390x x86_64"
version=$(echo $input | grep '[0-9]*\.[0-9]*\.[0-9]*\-[0-9]*\.[a-z][a-z][0-9]*') #5.14.0-484.el9

echo $input | grep -q rt && {
	bool_rt=true
}

echo $input | grep -q debug && {
	bool_debug=true
}


