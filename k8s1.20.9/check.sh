#!/bin/bash
count=$(netstat -antulp|grep 8443|grep LISTEN|wc -l)
if [ ${count} -eq 0 ];then
	echo "${host} is down"
	exit 1
else
	systemctl status haproxy
	if [ $? -ne 0 ];then
		systemctl restart haproxy
	fi
	echo "${host} is up"
	exit 0
fi