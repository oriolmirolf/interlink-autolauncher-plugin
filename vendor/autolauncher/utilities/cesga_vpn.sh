#!/bin/bash

snx -d 

expect -c "
	spawn snx -s secure.cesga.es -u $1
	expect \"Please enter your password:\"
	send \"$2\r\"
	expect \"Do you accept? \[y\]es/ \[N\]o:\"
	send \"y\"
	expect eof
"
