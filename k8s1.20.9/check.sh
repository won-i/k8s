#!/bin/bash
count=$(netstat -antulp|grep 8443|grep LISTEN|wc -l)
if [ ${count} -eq 0 ];then
	echo "${host} is down"
	exit 1
else
	echo "${host} is up"
	exit 0
fi