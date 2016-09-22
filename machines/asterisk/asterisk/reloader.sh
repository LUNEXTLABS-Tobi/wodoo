#!/bin/bash
set -x

echo 'Starting script that watches for /opt/reload file; if exists then reloads asterisk config and deletes file'

TRIGGER=/opt/reloader/reload

while true;
do

    [[ -f $TRIGGER ]] && {

        echo 'Asterisk reload triggered'

        /usr/sbin/asterisk -rx 'sip reload'
        /usr/sbin/asterisk -rx 'reload'
        rm $TRIGGER

    }

    sleep 1

done
