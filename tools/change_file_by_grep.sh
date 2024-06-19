#! /bin/bash
grep -rn "ncat " netfilter/ | grep -v "\-l" | grep -v "assert" |grep -v "pkill" |grep -v "wait_start" |grep -v "rpm \-q" |grep -v "\-w" > tmp
while read -r content
do
	#echo "$content"
	name=$(echo "$content" | awk -F ':' '{print $1}')
	#echo $name
	line=$(echo "$content" | awk -F ':' '{print $2}')
	#echo $line
	sed -i "${line}s/ncat/ncat -w 1/" $name
done < tmp
