#!/bin/bash

iohktt slave  127.0.0.1 44445 &
iohktt slave  127.0.0.1 44446 &
iohktt slave  127.0.0.1 44447 &
iohktt slave  127.0.0.1 44448 &
sleep 1
iohktt master 127.0.0.1 44444
