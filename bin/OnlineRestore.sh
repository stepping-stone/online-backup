#! /bin/sh
# *******************************************************************
# * Name: OnlineRestore.sh                  	                    *
# * Synopsis: OnlineRestore.sh snapshot [configfile [destination]]  *
# * Version 1.4				                            *
# * Author: Michael Rhyner		                            *
# *******************************************************************

if [ "$1" == "" ] || [ "$1" == "-h" ] || [ "$1" == "--help" ]
then
  echo "usage: OnlineRestore.sh <snapshot> [configfile [destination]]"
  echo "where <snapshot> can be current | daily.0-6 | weekly.0-3 | monthly.0-11"
  exit 1
else
  SNAPSHOT=$1
fi

if [ "$2" != "" ]
then
  CONFIGFILE=$2
else
  CONFIGFILE=OnlineBackup.conf
fi

source $CONFIGFILE

if [ "$CURRENTPREFIX" = "" ]
then
  CURRENTPREFIX=/incoming/
fi

if [ "$SNAPSHOTPREFIX" = "" ]
then
  SNAPSHOTPREFIX=/.snapshots/
fi

if [ "$LOCALDIR" = "" ]
then
  LOCALDIR=/
fi

if [ "$LOGFILE" = "" ]
then
  LOGFILE=./OnlineBackup.log
fi

if [ "$RSYNCBIN" = "" ]
then
  RSYNCBIN=rsync
fi

if [ "$SSHBIN" = "" ]
then
  SSHBIN=ssh
fi

if [ "$3" != "" ]
then
  DESTINATION=$3
else
  DESTINATION=$LOCALDIR
fi

RESTOREPATH=/
RSYNC_SUPOPTS=""
TIMESTAMP=`date +"%a %b %e %H:%M:%S %Y"`
HOSTNAME=`hostname`

if [ "$SNAPSHOT" == "current" ]
then
  PREFIX=$CURRENTPREFIX/$REMOTEDIR
else
  PREFIX=$SNAPSHOTPREFIX/$SNAPSHOT/$REMOTEDIR
fi

SOURCE=$PREFIX$RESTOREPATH

if [ "$3" != "" ]
then
  ACTUALPATH=$DESTINATION
else
  ACTUALPATH=$LOCALDIR
fi

echo "$TIMESTAMP $HOSTNAME  Restore started" >>$LOGFILE
if [ $VERBOSE > 1 ]; then
  echo "Restore started"
fi

# move permission script away
if [ -f $ACTUALPATH/$PERMSCRIPT ]; then
  mv -f $ACTUALPATH/$PERMSCRIPT $ACTUALPATH/${PERMSCRIPT}.old
fi

# copy the files from the backup server back to the local machine
$RSYNCBIN -rlHtDvze "$SSHBIN -i $PRIVKEYFILE" $RSYNC_SUPOPTS $REMOTEUSER@$REMOTEHOST:$SOURCE $DESTINATION >>$LOGFILE 2>&1

# Restore the permissions saved by OnlineBackup.pl
chmod 700 $ACTUALPATH/$PERMSCRIPT >>$LOGFILE 2>&1
chroot $ACTUALPATH $PERMSCRIPT >>$LOGFILE 2>&1

if [ "$?" == "0" ]; then
  echo "$TIMESTAMP $HOSTNAME  Restore successfully done" >>$LOGFILE
  echo "$TIMESTAMP $HOSTNAME  -------------------------" >>$LOGFILE
  if [ $VERBOSE > 1 ]; then
    echo "Restore successfully done"
  fi
else
  echo "$TIMESTAMP $HOSTNAME  Restore failed" >>$LOGFILE
  echo "$TIMESTAMP $HOSTNAME  ---------------------------------" >>$LOGFILE
  if [ $VERBOSE > 1 ]; then
    echo "Restore failed"
  fi
fi
