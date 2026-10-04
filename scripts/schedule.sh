#!/bin/bash
# Daily schedule, meant for cron on Linux.
cd "$(dirname "$0")/.." || exit 1

if [ "$(uname)" == "Linux" ] ; then
    sudo service bluetooth stop
    sudo hciconfig hci0 up
fi

DAYOFWEEK=$(date +"%u")
echo DAYOFWEEK: $DAYOFWEEK

if [ "${DAYOFWEEK}" -le 5 ]
then
    ./bin/lilo.js -t 10,00,22,15
else
    ./bin/lilo.js -t 12,00,23,00
fi
