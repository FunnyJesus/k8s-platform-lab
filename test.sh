#!/bin/bash

for i in $(seq 1 5000); do
    curl localhost:8001 > /dev/null 2>&1
    curl localhost:8001 > /dev/null 2>&1
    curl localhost:8001 > /dev/null 2>&1
    curl localhost:8001/test > /dev/null 2>&1
    echo " Request completed $i"
done
