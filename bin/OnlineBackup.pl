#! /usr/bin/perl
################################################################################
#
# Name: OnlineBackup.pl
# Description: This perl script copies the files to be backed up to a remote
# system, and saves the permissions before, so they can be restored as needed
# 
# Author: Michael Rhyner
# History:
# 2005-08-16 mr	created
# 2005-08-18 mr changed - added file globbing for include/exclude lists
# 2005-08-19 mr changed - rewritten exclude mechanism (improved performance)
# 2005-08-22 mr changed - added handling of multiple backups on remote side
# 2005-08-24 mr changed - added error handling on reading include/exclude files
# 2005-09-06 mr	V 1.0 - added ignore for empty lines in include/exclude files
# 2006-02-28 mr V 1.1 - added lock mechanism to avoid multiple running instances
# 2006-05-06 mr V 1.2 - better console/log outut, signal handling, bugfixes
# 2006-06-06 mr V 1.3 - further bugfixes and adapted to rsync version >=2.6.7
# 2006-12-14 mr V 1.4 - fixed incorrect permissions using some character classes
# 2006-12-19 mr V 1.5 - added better check if rsync was called successfully
# 2007-01-14 mr V 1.6 - use file list from rsync (if supported), bug fixes
# 2007-04-29 mr V 1.7 - backup/restore special files, handle links correctly
# 2007-08-02 mr V 1.8 - common routines for backup and restore in OLBUtils.pm
# 2007-09-22 mr V 1.9 - improved handling of paths in configuration files containing spaces
#                     - avoid that multiline filenames are passed to rsync because that leads to wrong filenames
#		      - avoid that dot (.) and double-dot (..) for parent dir are matched in include file
# 2007-12-09 mr V 1.10 - allow to use numeric user and group ids for permissions
# 2007-12-18 mr V 1.11 - delete excluded files on remote side by default, allow to disable per configuration
# 2008-01-28 mr V 1.12 - added storage of partition information for recovery
# 2008-02-04 mr V 1.13 - removed default remotehost
# 2011-08-16 pat.klaey@stepping-stone.ch V 1.14 - call writeStartXML and writeEndXML at the start / at the end of the backup process.
# 2011-09-13 pat.klaey@stepping-stone.ch V 2.0 - Read minuteSelected and hourSelected from config file and pass it to writeStartXML
# 2012-09-10 pat.klaey@stepping-stone.ch V 2.0.1 - If during rsync process some files vanish, it is no longer treated as an error
# 2020-01-29 sst-yde V 2.0.6 - Add CREATEPERMSCRIPT option.
# 2021-01-17 sst-yde V 2.0.7 - Add LEGACY option.
################################################################################

use Sys::Hostname;
use POSIX;
use strict;

my $script = $0;
my $basedir = $script;
$basedir =~ s:^(.*)\/(.*)$:$1:;
push (@INC, $basedir);

# import utility subs
require OLBUtils;

# Version
use constant VERSION => "2.0.11";

# setting default values
my $configfile = "../conf/OnlineBackup.conf";
my $logfile = "../log/OnlineBackup.log";
my $localdir = "/";
my $remotedir = "";
my $currentprefix = "~/incoming/";
my $snapshotprefix = "~/.snapshots/";
my $lockfile = "/var/lock/OnlineBackup.lock";
my $locktimeout = 23;
my $tempdir="/var/tmp/";
my $rsyncbin = "/usr/bin/rsync";
my $sshbin = "ssh";
my $sfdiskbin = "sfdisk";
my $rsynclist = 1;
my $remoteperms = 1;
my $createpermscript = 1;
my $numericowners = 0;
my $deleteexcluded = 1;
my $partitionfile = "";
my $scandisks = "";
my $sepioladir="/.sepiola_backup";
my $startxml="backupStarted.xml";
my $endxml="backupEnded.xml";
my $schedulerxml="scheduler.xml";
my $minuteSelected;
my $hourSelected;
our $verbose = 0;
my $legacy = 0;

# declare variables
my %config;
my @includes;
my @excludes;
my $excluded;
my @permlist;
my $filename;
my @locktime;
my $timestamp;
my $currentpid;
my $lockpid;
my $remotehost;
my $remoteuser;
my $privkeyfile;
my $includefile;
my $excludefile;
my $permscript;
my $message;
my $regexerror;
my $line = "";
my $includestring = "";
my %wildcards;
my @charclassmetas;
my @currenttime = localtime();
my $error = 0;
my $tripleasteriskdir = 0;
my $basepathslashcharclassvalid = 0;
my $chmodoption="";
my $remotepermoption=" --perms";
my $deleteexcludedoption=" --delete-excluded";
my $listonly=0;
my %uids = ();
my $uid_status = 0;       # 0: not started, 1: busy, 2: complete
my %gids = ();
my $gid_status = 0;       # 0: not started, 1: busy, 2: complete
# generate a backup ID to identify the backup process
# generates a random nr between 100000 and 1000000000
my $id=int(rand(999900000))+100000;


# Handle signals
$SIG{INT} = \&catch_break;   # catch sigint
$SIG{QUIT} = \&catch_break;  # catch sigquit
$SIG{TERM} = \&catch_break;   # catch sigterm
$SIG{HUP} = \&catch_break;   # catch sighup
$SIG{PIPE} = \&catch_break;  # catch sigpipe
$SIG{ALRM} = \&catch_break;  # catch sigalrm
$SIG{USR1} = \&catch_break;  # catch sigusr1
$SIG{USR2} = \&catch_break;  # catch sigusr2

# Getting arguments
for (my $i = 0; $i<=$#ARGV; $i++) {
  if (($ARGV[$i] eq "-h") || ($ARGV[$i] eq "--help")) {
      printUsage();
  }
  if (($ARGV[$i] eq "-c") || ($ARGV[$i] eq "--config")) {
      $i++;
      $configfile = $ARGV[$i];
  }
}

# Read configuration file
%config = OLBUtils::readConf ($configfile);

if ($config{VERBOSE} =~ /^[0-9]+$/) {
  $verbose = $config{VERBOSE};
}

if ($config{LOCALDIR}) {
  $localdir = $config{LOCALDIR};
}

if ($config{REMOTEDIR}) {
  $remotedir = $config{REMOTEDIR};
}

if ($config{CURRENTPREFIX}) {
  $currentprefix = $config{CURRENTPREFIX};
}

if ($config{SNAPSHOTPREFIX}) {
  $snapshotprefix = $config{SNAPSHOTPREFIX};
}

if ($config{REMOTEHOST}) {
  $remotehost = $config{REMOTEHOST};
} else {
  terminate (-1,"Variable REMOTEHOST must be set in configuration file\n       For example: REMOTEHOST=backup.domain.tld");
}

if ($config{LOCKFILE}) {
  $lockfile = $config{LOCKFILE};
}

if ($config{LOCKTIMEOUT} =~ /^[0-9]+$/) {
  $locktimeout = $config{LOCKTIMEOUT};
}

if ($config{LOGFILE}) {
  $logfile = $config{LOGFILE};
}

if ($config{REMOTEUSER}) {
  $remoteuser = $config{REMOTEUSER};
} else {
  terminate (-1,"Variable REMOTEUSER must be set in configuration file\n       For example: REMOTEUSER=3723123");
}

if ($config{PRIVKEYFILE}) {
  $privkeyfile = $config{PRIVKEYFILE};
} else {
  terminate (-1,"Variable PRIVKEYFILE must be set in configuration file\n       For example: PRIVKEYFILE=\$HOME/.ssh/backup_id_dsa");
}

if ($config{PERMSCRIPT}) {
  $permscript = $config{PERMSCRIPT};
} else {
  terminate (-1,"Variable PERMSCRIPT must be set in configuration file!\n       For example: PERMSCRIPT=\$HOME/OnlineBackup/.SetPermissions.sh");
}

if ($config{INCLUDEFILE}) {
  $includefile = $config{INCLUDEFILE};
} else {
  terminate (-1,"Variable INCLUDEFILE must be set in configuration file!\n      For example: INCLUDEFILE=\$HOME/OnlineBackup/OnlineBackupIncludeFiles.conf");
}

if ($config{EXCLUDEFILE}) {
  $excludefile = $config{EXCLUDEFILE};
} else {
  terminate (-1,"Variable EXCLUDEFILE must be set in configuration file!\n       For example: EXCLUDEFILE=\$HOME/OnlineBackup/OnlineBackupExcludeFiles.conf");
}

if ($config{TEMPDIR}) {
  $tempdir = $config{TEMPDIR};
}

if ($config{RSYNCBIN}) {
  $rsyncbin = $config{RSYNCBIN};
}

if ($config{RSYNCLIST} =~ /^[0-1]$/) {
  $rsynclist = $config{RSYNCLIST};
}

if ($config{SSHBIN}) {
  $sshbin = $config{SSHBIN};
}

if ($config{SFDISKBIN}) {
  $sfdiskbin = $config{SFDISKBIN};
}

if ($config{REMOTEPERMS} =~ /^[0-1]$/) {
  $remoteperms = $config{REMOTEPERMS};
}

if ($config{CREATEPERMSCRIPT} =~ /^[0-1]$/) {
  $createpermscript = $config{CREATEPERMSCRIPT};
}

if ($config{NUMERICOWNERS} =~ /^[0-1]$/) {
  $numericowners = $config{NUMERICOWNERS};
}

if ($config{DELETEEXCLUDED} =~ /^[0-1]$/) {
  $deleteexcluded = $config{DELETEEXCLUDED};
}

if ($config{PARTITIONFILE}) {
  $partitionfile = $config{PARTITIONFILE};
}

if ($config{SCANDISKS}) {
  $scandisks = $config{SCANDISKS};
}

if ($config{SEPIOLADIR}) {
  $sepioladir = $config{SEPIOLADIR};
}

if ($config{STARTXML}) {
  $startxml = $config{STARTXML};
}

if ($config{ENDXML}) {
  $endxml = $config{ENDXML};
}

if ($config{SCHEDULERXML}) {
  $schedulerxml = $config{SCHEDULERXML};
}

if ($config{SCHEDULEDMINUTE}) {
  $minuteSelected = $config{SCHEDULEDMINUTE};
} else {
  terminate (-1,"Variable SCHEDULEDMINUTE must be set in configuration file!\n       For example: SCHEDULEDMINUTE=00 or SCHEDULEDMINUTE=30");
}

if ($config{SCHEDULEDHOUR}) {
  $hourSelected = $config{SCHEDULEDHOUR};
} else {
  terminate (-1,"Variable SCHEDULEDHOUR must be set in configuration file!\n       For example: SCHEDULEDHOUR=05 or SCHEDULEDMINUTE=16");
}

if ($config{LEGACY} =~ /^[0-1]$/) {
  $legacy = $config{LEGACY};
}

my $temp_filelist=OLBUtils::removeSpareSlashes($tempdir . "/.filelist.tmp");

# clear rsync option for setting remote permissions when disabled
if ($remoteperms == 0) {
  $remotepermoption = "";
}

# clear rsync option for deleting excluded files when disabled
if ($deleteexcluded == 0) {
  $deleteexcludedoption = "";
}

# check lock file and read its content
if (-e $lockfile) {
  open (FH,"<",$lockfile) or terminate (-1,"open $lockfile: $!");
  read (FH, $line,21);
  # check content of lockfile
  if ($line =~ /^\d{15}\s\d+$/) {
    ($timestamp,$lockpid) = split (/\s/,$line);
  } else {
    terminate (-2, "Incorrect lockfile format, possibly wrong file configured! If not, please delete $lockfile.");
  }
  close (FH);
  for (my $i=1; $i<5; $i++) {
    push ( @locktime, substr($timestamp,-(1+$i*2),2) ); # two-digit parts
  }
  push ( @locktime, substr($timestamp,-11,2) - 1 ); # month
  push ( @locktime, substr($timestamp,-15,4) - 1900 ); # year
  # find out about daylight saving time
  if (substr($timestamp,-1,1) == 1) {
    # decrease hour by DST bias so it compares with current UNIX timestamp
    @locktime[2] = sprintf("%02d",@locktime[2] -1);
  }
  my $lockfileage = (time() - mktime(@locktime));
  print "Age of lockfile: " . $lockfileage . " sec, Timeout: " . $locktimeout*3600 . " sec\n" if ($verbose > 2);
  # if lockfile is older than locktimeout we try to kill the "hanging" process
  if ( $lockfileage > ($locktimeout*3600) ) {
    # check if the pid really belongs to an OnlineBackup process
    if (checkInstance ($lockpid) == 1) {
      # kill process and check if successfully or not
      if (killProcess($lockpid) == 0) {
        $message = "Longrunning backup process with PID $lockpid killed!";
        OLBUtils::writeLog($message,"",$logfile);
        print (STDOUT "$message\n") if ($verbose > 1);
	sleep 30;
      } else {
        terminate (-2,"cannot kill longrunning backup process with PID $lockpid!");
      }
    } elsif (checkInstance($lockpid) == 0) {
      # if no instance is running with the pid from lockfile, assume it's stale
      if (unlink $lockfile) {
        $message = "Stale lock file $lockfile removed!";
        OLBUtils::writeLog($message,"",$logfile);
        print (STDOUT "$message\n") if ($verbose > 1);
      } else {
        $message = "Cannot remove stale lock file $lockfile!";
        OLBUtils::writeLog($message,"",$logfile);
        print (STDERR "$message\n") if ($verbose > 1);
      }
    } else {
      terminate (-2,"cannot check for process, possibly another instance of OnlineBackup,  PID $lockpid, is already running! If this is not true, please delete the file $lockfile.");
    }
  } else {
    # lockfile hasn't expired yet, show an appropriate message
    if (checkInstance($lockpid) == 1) {
      terminate (-2,"another instance of OnlineBackup, PID $lockpid, is already running! If this is not correct, please delete the file $lockfile.");
    } elsif (checkInstance($lockpid) == 0) {
      terminate (-2,"lockfile found, but no running OnlineBackup with PID $lockpid found. Possibly, OnlineBackup has been killed, but rsync may still be running. If this is not true, please delete the file $lockfile.");
    } else {
      terminate (-2,"cannot check for process, possibly another instance of OnlineBackup,  PID $lockpid, is already running! If this is not true, please delete the file $lockfile.");
    }
  }
}

# write lock file
$timestamp = sprintf("%04d%02d%02d%02d%02d%02d%01d", $currenttime[5]+1900,$currenttime[4]+1,$currenttime[3],$currenttime[2],$currenttime[1],$currenttime[0],$currenttime[8]);
$currentpid = $$;
open (FH,">",$lockfile) or terminate (-1,"open $lockfile: $!");
print (FH $timestamp . " " . $currentpid);
close (FH);

$message = "Backup started";
OLBUtils::writeLog ($message,"",$logfile);
print (STDOUT "$message\n") if ($verbose > 1);

# the directory where the xml files are located
my $xmldir=OLBUtils::removeSpareSlashes("$currentprefix/$remotedir/$sepioladir/");

# create the xml directory if it does not already exist and write
# the 'backupStarted.xml' file to this directory
OLBUtils::writeStartXML($id,$privkeyfile,$rsyncbin,$remotehost,$remoteuser,$xmldir,$startxml,$schedulerxml,$minuteSelected,$hourSelected,$logfile,VERSION);

# the prefix used for localdir shouldn't contain trailing slashes
my $localdirprefix = $localdir;
$localdirprefix =~ s/\/+$//;

my @rsyncversions = OLBUtils::getRsyncVersion ($rsyncbin,$logfile);
# Check if rsync is available
if ($rsyncversions[0] == -1) {
  terminate (-1, "cannot execute $rsyncbin, reason: $rsyncversions[1]!");
}
# check version of rsync for different features
if ( (($rsyncversions[0] == 2) && ($rsyncversions[1] == 6) && ($rsyncversions[2] >= 7)) || (($rsyncversions[0] == 2) && ($rsyncversions[1] > 6)) || ($rsyncversions[0] > 2) ) {
  $tripleasteriskdir = 1;
  $basepathslashcharclassvalid = 0;
  if ($remoteperms == 1) {
    $chmodoption = " --chmod=Du+wx,u+r";
  }
} elsif ( (($rsyncversions[0] == 2) && ($rsyncversions[1] == 6) && ($rsyncversions[2] >= 0)) || (($rsyncversions[0] == 2) && ($rsyncversions[1] > 6)) || ($rsyncversions[0] > 2) ) {
  $tripleasteriskdir = 0;
  $basepathslashcharclassvalid = 1;
  $chmodoption = "";
} else {
  terminate (-1, "$rsyncbin isn't at version 2.6.0 or higher!"); 
}


# Create Partition File
if ($partitionfile ne "") {
  $message = "Creating partition file";
  OLBUtils::writeLog ($message,"",$logfile);
  print (STDOUT "$message\n") if ($verbose > 1);
  system ($sfdiskbin . " -d " . $scandisks . " >" . $partitionfile . " 2>>" . $logfile);
  if ( ($? == 0) & ((stat $partitionfile)[7] > 0) ) {
    $message = "Creation of partition file OK";
  } else {
    $message = "Creation of partition file failed!";
    $error = 1;
  }
  OLBUtils::writeLog ($message,"",$logfile);
  print (STDOUT "$message\n") if ($verbose > 1);
}


# Create Permission script
$message = "Creating permission script";
OLBUtils::writeLog ($message,"",$logfile);
print (STDOUT "$message\n") if ($verbose > 1);
open (FH, '+>', OLBUtils::removeSpareSlashes($localdirprefix . "/" . $permscript)) or terminate (-1,"Cannot create permission script " . OLBUtils::removeSpareSlashes($localdirprefix . "/" . $permscript));
close (FH);

# read includes
$line = "";
$message = "Searching for files";
OLBUtils::writeLog ($message,"",$logfile);
print (STDOUT "$message\n") if ($verbose > 1);
open (FH,"<",$includefile) or terminate (-1,"open $includefile: $!");
while ($line = <FH>) {
  chomp ($line);
  # ignore comments and emtpy lines
  next if (($line =~ /^(#|;)/) || ($line =~ /^\s*$/));
  $line =~ s/\s/\\ /g;
  if ($line =~ /\$/) {
    # resolve variables
    my @metachars = ("\\\$");
    $line = OLBUtils::replaceVarRefs ($line,@metachars);
    print "Variable resolved include: $line\n" if ($verbose > 3);
  }
  # remove superfluous slashes, but if line ended with a slash, add it again
  if ($line =~ /\/$/) {
    $line = OLBUtils::removeSpareSlashes($localdir . "/" . $line) . "/";
  } else {
    $line = OLBUtils::removeSpareSlashes($localdir . "/" . $line);
  }
  # resolve matching patterns possibly meaning multiple files to one line each
  my @glob_array = glob($line);
  foreach my $glob_line (@glob_array) {
    if ($glob_line =~ /\r|\n/) {
      # skip include line containing line breaks what would cause wrong filenames
      $message = "Skipping path item because it contains line breaks:\n" . $glob_line . "\n";
      OLBUtils::writeLog ($message,"",$logfile);
      print (STDOUT "$message\n") if ($verbose > 1);
      next;
    }
    if ( ($glob_line =~ /(^|\/)\.\.(\/|$)/) || ($glob_line =~ /(^|\/)\.(\/|$)/) ) {
      # skip include line containing dot (.) or double-dot (..) for current and parent dir
      $message = "Skipping directory: " . $glob_line . "\n";
      OLBUtils::writeLog ($message,"",$logfile);
      print (STDOUT "$message\n") if ($verbose > 1);
      next;
    }
    if ( (-e $glob_line) || (-l $glob_line) ) {
      # file or directory really exists
      my $includedir = $glob_line;
      # strip off prefix
      $includedir =~ s:^$localdirprefix/*(.*):./$1:g;
      # strip off trailing slashes because we don't need them any more
      $includedir =~ s:/$::;
      # add to include file list
      push (@includes,$includedir);
    } else {
      # file or directory doesn't exist
      $message = "File or directory " . $glob_line . " does not exist";
      OLBUtils::writeLog ($message,"",$logfile);
      print (STDOUT "$message\n") if ($verbose > 1);
      $error = 1;
    }
  } 
}

# sort the includes list
uniquesort (\@includes);

print "\n" if ($verbose > 2);
print "Includes: \n" if ($verbose > 2);
print join("\n",@includes) if ($verbose > 2);
print "\n\n" if ($verbose > 2);
close (FH);

# read excludes
open (FH,"<",$excludefile) or terminate (-1,"open $excludefile: $!");
while ($line = <FH>) {
  chomp ($line);
  # split by single CR because rsync sees the rest of the line as a new rule
  my @crlines = split (/\015/,$line);
  foreach my $crline (@crlines) {
    # omit comment lines or empty lines
    next if ( ($crline =~ /^(#|;)/) || ($crline =~ /^\s*$/) );
    # reset exclusion list if an exclamation mark (!) appears alone on a line
    if ( $crline =~ /^!$/ ) {
      @excludes = ();
      next;
    }

    # version 2.6.4 of rsync doesn't care about a leading plus (+) or minus (-) sign and space before an exclamation mark, thus always clearing the list
    if ( ($rsyncversions[0] == 2) && ($rsyncversions[1] == 6) && ($rsyncversions[2] == 4) ) {
      if ( $crline =~ /^[-+] !$/ ) {
        @excludes = ();
        next;   
      }
    }   

    # add an extra escape to an item beginning with escapes followed by a + sign to be in sync with the back-modification that occurs for explicitly excluded lines beginning with a + sign
    $crline =~ s/^(\\+)\+/$1\\\\\+/;
    # replace an explicitly excluded item (- <space> combination), optionally followed by escape characters (backslashes) and a + sign with an extra escape to distinguish the resulting literal + from an include rule
    $crline =~ s/^-\s(\\*)\+/$1\\\\\+/;
    # remove the - <space> combination because it has a literal meaning in regular expressions and therefore avoids exclusion
    $crline =~ s/^- //;

    # populate exclude list
    push (@excludes, $crline);
  }
}
print "Excludes: \n" if ($verbose > 2);
print join("\n",@excludes) if ($verbose > 2);
print "\n\n" if ($verbose > 2);
close (FH);

if ($createpermscript == 1) {
  # write the header of permission script
  open (FH, '+>', OLBUtils::removeSpareSlashes($localdirprefix . "/" . $permscript)) or terminate (-1,"Cannot open permission script " . OLBUtils::removeSpareSlashes($localdirprefix . "/" . $permscript));
  print FH '#! /bin/sh
  # This shell script sets the permissions back to those found in source directory
  # Please don\'t modify or delete it, it will be used by the restore script!
  
  if [ "$1" != "" ]
  then
    PREFIX="$1"
  else
    PREFIX=""
  fi
  
  ';
  
  # check rsync version to determine if file list from rsync can be used
  @rsyncversions = OLBUtils::getRsyncVersion ($rsyncbin,$logfile);
  if ( (($rsyncversions[0] == 2) && ($rsyncversions[1] == 6) && ($rsyncversions[2] >= 7)) || (($rsyncversions[0] == 2) && ($rsyncversions[1] > 6)) || ($rsyncversions[0] > 2) ) {
    # conditions allow to use rsync file list...
    $listonly=1;
    # ...and quoting filenames in remote shell command
    $sshbin = "\'$sshbin\'";
    $privkeyfile = "\'$privkeyfile\'";
  }
  
  if ( ($listonly == 1) && (-w $tempdir) && ($rsynclist == 1) ) {
    # build file list for setting permissions by using file list from rsync
    @permlist = buildFilelistFromRsync($temp_filelist,$excludefile,$rsyncbin,$sshbin,$privkeyfile,$localdir,$logfile,$verbose,@includes);
  } else {
    # build file list for setting permissions by using rules like rsync
    if ($rsynclist == 0) {
      $message = "Calculating includes/excludes by myself because option RSYNCLIST is turned off"; 
    } elsif ($listonly == 0) {
      $message = "Calculating includes/excludes by myself because available rsync version doesn't provide a suitable file list";
    } elsif (! -w $tempdir) {
      $message = "Calculating includes/excludes by myself because lack of a writable temporary directory. Please check config option TEMPDIR for an existing writable path!";
    }
    OLBUtils::writeLog($message,"",$logfile);
    @permlist = buildFilelistFromRules($rsyncbin,$logfile,\@includes,\@excludes);
  }

  # write commands to permission script
  print "\nResulting list of entries to be used:\n" if ($verbose > 2);
  foreach $filename (@permlist) {
    # remove leading slash from file name
    $filename =~ s:^/::;
    print "./$filename\n" if ($verbose > 2);
    my ($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size,$atime,$mtime,$ctime,$blksize,$blocks);
    my ($user,$group);
    if ( -l $localdirprefix . "/" . $filename ) {
      # for a link we have to use lstat, and only setting ownership
      ($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size,$atime,$mtime,$ctime,$blksize,$blocks) = lstat($localdirprefix . "/" . $filename);
      if ( $numericowners == 0 ) {
        # use user and group name
        $user=&fmt_uid($uid);
        $group=&fmt_gid($gid);
      } else {
        # use numeric user and group id
        $user=$uid;
        $group=$gid;
      }
    # replace single quote in a file name with backslash-escaped single quote
    $filename =~ s:':'\\'':g;
    printf (FH "chown -h %s:%s \"\${PREFIX}\"'/%s'\n",$user,$group,$filename);
    } elsif ( -e $localdirprefix . "/" . $filename ) {
      # for all other types of files we need stat
      ($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size,$atime,$mtime,$ctime,$blksize,$blocks) = stat($localdirprefix . "/" . $filename);
      if ( $numericowners == 0 ) {
        # use user and group name
        $user=&fmt_uid($uid);
        $group=&fmt_gid($gid);
      } else {
        # use numeric user and group id
        $user=$uid;
        $group=$gid;
      }
      # recreate special files
      if ( (-b $localdirprefix . "/" . $filename) || (-c $localdirprefix . "/" . $filename) ) {
        my ($major, $minor) = ($rdev >> 8, $rdev & 0xFF);
        my $devtype;
        # set device type according to type of file
        if (-b $localdirprefix . "/" . $filename) {
  	# block device
          $devtype = "b";
        } elsif (-c $localdirprefix . "/" . $filename) {
          # character device
          $devtype = "c";
        }
        print ("Device file: " . $filename . ", Type: " . $devtype . ", Major: " . $major . ", Minor: " . $minor . "\n") if ($verbose > 3);
        $filename =~ s:':'\\'':g;
        printf (FH "mknod \"\${PREFIX}\"'/%s' %s %s %s\n", $filename, $devtype, $major, $minor); 
      } elsif (-p $localdirprefix . "/" . $filename) {
        # named pipe
        my $devtype = "p";
        print ("Special file: " . $filename . ", Type: " . $devtype . "\n") if ($verbose > 3);
        $filename =~ s:':'\\'':g;
        printf (FH "mknod \"\${PREFIX}\"'/%s' %s\n", $filename, $devtype); 
      } else {
        # other file type
        $filename =~ s:':'\\'':g;
      }
 
      # setting ownership and permissions
      printf (FH "chown %s:%s \"\${PREFIX}\"'/%s'; chmod %04o \"\${PREFIX}\"'/%s'\n",$user,$group,$filename,$mode & 07777,$filename);
    }
  }

  # end of permission script
  print "\n\n" if ($verbose > 2);
  close (FH);
  chmod (0700, OLBUtils::removeSpareSlashes($localdirprefix . "/" . $permscript));
} else {
  $message = "Skipping creation of permission script because CREATEPERMSCRIPT is set to 0";
  OLBUtils::writeLog($message,"",$logfile);
  print (STDOUT "$message\n") if ($verbose > 1);
}

# Call rsync to transfer the files to the backup server
$message = "Transferring files to backup host";
OLBUtils::writeLog ($message,"",$logfile);
print (STDOUT "$message\n") if ($verbose > 1);
my $cmd;

if ($legacy == 1) {
  $cmd = "\"$rsyncbin\" --exclude-from=\"$excludefile\" --delete -rSlHtvze \"$sshbin -i $privkeyfile\"$chmodoption$remotepermoption$deleteexcludedoption --files-from=- \"$localdir\" $remoteuser\@$remotehost:" . OLBUtils::removeSpareSlashes($currentprefix . "/" . $remotedir) . "/";
} else {
  my $backupdir = OLBUtils::removeSpareSlashes("$snapshotprefix/" . strftime('%Y%m%d', localtime) . "/$remotedir");
  $cmd = "'$rsyncbin'"
       . " --rsh '$sshbin -i $privkeyfile'"
       . ' --recursive --sparse --links --hard-links --times --verbose --compress' # Expanded version of the options "-rSlHtvz".
       . ' --delete'
       . ' --backup'
       . " --backup-dir '$backupdir'"
       . " --files-from '$includefile'"
       . " --exclude-from '$excludefile'"
       . " '$localdir'"
       . " '$remoteuser\@$remotehost':" . OLBUtils::removeSpareSlashes("$currentprefix/$remotedir") . "/";
}

print "rsync call: " . $cmd . "\n" if ($verbose > 2);
open (INPUT, "| $cmd 1>>\"$logfile\" 2>&1");
foreach $includestring (@includes) {
  print INPUT $includestring . "\n";
}
close INPUT;

# free some memory
undef(@permlist);

# report about result of backup
if ($? == 0) {
  $message = "Transfer to backup host OK";
  OLBUtils::writeLog ($message,"",$logfile);
  print (STDOUT "$message\n") if ($verbose > 1);
} elsif ($? == 5120) {
  terminate (-1,"Somebody sent me a SIGINT!");
} elsif ($? == 256) {
  terminate (-1,"Calling of rsync failed!");
} elsif ($? == 32512) {
  terminate (-1,"$rsyncbin not found!");
} elsif ($? == 6144) {
  $message = "Some files vanished while transfering to backup host, but overall transfer to backup host OK";
  OLBUtils::writeLog ($message,"",$logfile);
  print (STDOUT "$message\n") if ($verbose > 1);
} else {
  $message = "Problems occured during transfer to backup host";
  OLBUtils::writeLog ($message,"",$logfile);
  print (STDERR "$message\n") if ($verbose > 1);
  $error=1;
}
# if there was no reason for an abort, terminate now with cumulative exit code
terminate($error);


# this sub runs rsync with list-only parameter to list the files/directories that would be transferred
sub buildFilelistFromRsync {
  my $includestring;
  my ($temp_filelist,$excludefile,$rsyncbin,$sshbin,$privkeyfile,$localdir,$logfile,$verbose,@includes) = @_;
  $message = "Using rsync file list for includes/excludes"; 
  OLBUtils::writeLog($message,"",$logfile);
  $tempdir =~ s/\/$//;
  my %controls = ("\\\\#000" => "\000",
  		  "\\\\#001" => "\001",
  	     	  "\\\\#002" => "\002",
  	     	  "\\\\#003" => "\003",
  	     	  "\\\\#004" => "\004",
  	     	  "\\\\#005" => "\005",
  	     	  "\\\\#006" => "\006",
  	     	  "\\\\#007" => "\007",
  	     	  "\\\\#010" => "\010",
  	     	  "\\\\#012" => "\012",
  	     	  "\\\\#013" => "\013",
  	     	  "\\\\#014" => "\014",
  	     	  "\\\\#015" => "\015",
  	     	  "\\\\#016" => "\016",
  	     	  "\\\\#017" => "\017",
  	     	  "\\\\#020" => "\020",
  	     	  "\\\\#021" => "\021",
  	     	  "\\\\#022" => "\022",
  	     	  "\\\\#023" => "\023",
  	    	  "\\\\#024" => "\024",
  	     	  "\\\\#025" => "\025",
  	     	  "\\\\#026" => "\026",
  	     	  "\\\\#027" => "\027",
  	     	  "\\\\#030" => "\030",
  	     	  "\\\\#031" => "\031",
  	     	  "\\\\#032" => "\032",
  	     	  "\\\\#033" => "\033",
  	     	  "\\\\#034" => "\034",
  	     	  "\\\\#035" => "\035",
  	     	  "\\\\#036" => "\036",
  	     	  "\\\\#037" => "\037",
	     	  "\\\\#134" => "\134");
  # create a temporary file for file list used by rsync because we need also its output
  open (FILELIST, "> $temp_filelist") or terminate (-1,"open $temp_filelist for writing: $!");
  # write every include line to the file list
  foreach $includestring (@includes) {
    print FILELIST $includestring . "\n";
  }
  close FILELIST;
  # actually call rsync to only generate a list of files that would be transferred
  my $cmd = "\"$rsyncbin\" --exclude-from=\"$excludefile\" --delete --list-only -rlHtvze \"$sshbin -i $privkeyfile\" --files-from=\"$temp_filelist\" -8 --no-implied-dirs \"$localdir\" \"$tempdir\"";
  print "rsync call: " . $cmd . "\n" if ($verbose > 2);
  # read the files directly from rsync's output
  open (FILELIST,"$cmd 2>>\"$logfile\" |") or terminate (-1,"cannot call rsync to get files for permission script: $!");
  print "\nList of items from rsync:\n" if ($verbose > 3);
  LISTWALK: while (my $item = <FILELIST>) {
    # extract path and filename out of each item listed by rsync
    if ($item =~ /^l.{9}\s+(?>.+?\s+.+?\s+.+?\s+)(.+)\s->\s(.+)$/) {
      # symlink, only get link itself (not the target)
      $item =~ s/^l.{9}\s+(?>.+?\s+.+?\s+.+?\s+)(.+)\s->\s(.+)\n$/$1/g;
    } elsif ($item =~ /^(?>(?!s)[^\s]{10}\s+.+?\s+.+?\s+.+?\s+)(.+)$/) {
      # not a symlink and not a socket file, get path and filename
      if ($item =~ /^d/) {
        # item is a directory, add a slash at end of path
        $item =~ s/^(?>[^\s]{10}\s+.+?\s+.+?\s+.+?\s+)(.+)\n$/$1\//g;
      } else {
        # item is a regular file, without slash at end of path
        $item =~ s/^(?>[^\s]{10}\s+.+?\s+.+?\s+.+?\s+)(.+)\n$/$1/g;
      }
    } else {
      # skip socket files
      next LISTWALK;
    }
    # replace control characters escaped by \#ddd with \ddd
    foreach my $controlchar (keys %controls) {
      $item=~s/$controlchar/$controls{$controlchar}/g;
    }  
    # add the file/directory to the permissions file list
    push (@permlist,$item);
    print $item . "\n" if ($verbose > 3);
  }
  close FILELIST;
  unlink ($temp_filelist);
  uniquesort (\@permlist);
  return @permlist;
}

# This sub generates file list by itself, without rely on file list from rsync
sub  buildFilelistFromRules {
  my $rsyncbin = $_[0];
  my $logfile = $_[1];
  my $includesref = $_[2];
  my $excludesref = $_[3];
  my @includes = @$includesref;
  my @excludes = @$excludesref;

  # prepare regular expressions for matching the same items as rsync
  @excludes = OLBUtils::prepareRsyncRegex ($rsyncbin,$logfile,@excludes);

  # write lines for all items that should be saved (included but not excluded)
  foreach my $glob_line (@includes) {
    my @includeitems;
    my $item;
    my $lastexclude;
    my $lastexclude_quoted;
    my $include;
    my $include_quoted;
    my $line;
    my $excluded;
    $line = $glob_line;
    $include = $line;
    # remove the dot at first position in front of the slash (./) of every line
    $include =~ s/^\.(?=\/|$)//;
    $line = OLBUtils::removeSpareSlashes($localdir . "/" . $include);
    # check if line is a real directory (not a symlink)
    if ((-d $line) && (! -l $line)) {
      # if there's no slash as last character of a line, we add it here to distinguish later between files and directories
      $include = $include . "/" if ($include !~ /\/$/);
      # add the directory itself to the file list
      if ($line eq "/") {
        push (@includeitems,$line);
      } else {
        push (@includeitems,$line . "/");
      } 
      # add the contents of the directory to the file list
      push (@includeitems, scanDirectory($line));
    # check if line contains a regular file, symlink, block device, character device or a pipe
    } elsif ( (-f $line) || (-l $line) || (-b $line) || (-c $line) || (-p $line) ) {
      # add the file to the file list
      push (@includeitems,$line);
    } else {
      $message = "Path item " . $line . " ignored";
      OLBUtils::writeLog ($message,"",$logfile);
      print (STDOUT "$message\n") if ($verbose > 2);
      next;
    }
    uniquesort (\@includeitems);
    $include_quoted = quotemeta($include);

    TREEWALK: foreach my $item (@includeitems) {
      $item =~ s/^$localdirprefix(.*)$/$1/s;
      # path item forced excluded, deeper than excluded path
      if (($excluded == 2) && ($item =~ /^$lastexclude_quoted.+$/)) {
        next TREEWALK;
      # path item is excluded by a directory, deeper than excluded path and that in turn is equal or deeper than included path
      } elsif (($excluded == 1) && ($lastexclude_quoted =~ /\/$/) && ($item =~ /^$lastexclude_quoted.+$/s) && ($lastexclude =~ /^$include_quoted.*$/s)) {
        next TREEWALK;
      }
      # actually check if path item is excluded
      $excluded = excludeItem($item,$include,@excludes);
      print "Path: $item, Excluded: $excluded, Lastexclude: $lastexclude, Include: $include\n" if ($verbose > 3);
      if ($excluded == 0) {
	# definitively add path item to the permissions list
        push (@permlist, $item);
      } else {
	# remember path item as last excluded
        $lastexclude = $item;
        $lastexclude_quoted = quotemeta($item);
      }
    }
  }
  uniquesort (\@permlist);
  return @permlist;
}

# this subroutine scans a directory tree recursively and creates an array of it
sub scanDirectory {
  my @entries;
  my $workdir = OLBUtils::removeSpareSlashes(shift);
  if (! opendir (DH, $workdir)) {
    # cannot open directory
    $message = "Directory " . $workdir . " is not accessible";
    OLBUtils::writeLog ($message,"",$logfile);
    print (STDOUT "$message\n") if ($verbose > 1);
    return;
  }
  my @names;
  if (! (@names = readdir(DH))) {
    # cannot read directory
    $message = "Error while reading directory " . $workdir;
    OLBUtils::writeLog($message,"",$logfile);
    print (STDERR "$message\n") if ($verbose > 1);
    $error = 1;
  }
  # remove trailing slash from directory name
  $workdir =~ s/^\/$//;
  # loop through every entry
  foreach my $name (@names) {
    # ignore parent directories
    next if ($name eq "."); 
    next if ($name eq "..");
    # is this a real directory?
    if ((-d $workdir . "/" . $name) && (! -l $workdir . "/" . $name)) {
      # add scanned directory itself to list of entries
      push (@entries, $workdir . "/" . $name . "/");
      # scan directory by calling myself (recursive)
      push (@entries,&scanDirectory($workdir . "/" . $name));
    } elsif ( (-f $workdir . "/" . $name) || (-l $workdir . "/" . $name) || (-b $workdir . "/" . $name) || (-c $workdir . "/" . $name) || (-p $workdir . "/" . $name) ) {
      # add file to list of entries
      push (@entries, $workdir . "/" . $name);
    } else {
      $message = "Path item " . $workdir . "/" . $name . " ignored";
      OLBUtils::writeLog ($message,"",$logfile);
      print (STDOUT "$message\n") if ($verbose > 2);
      next;
    }
  }
  closedir (DH);
  return @entries;
}

# this subroutine determines user name from id - with cacheing
sub fmt_uid {
  my ($id) = shift (@_);
  my (@a);

 if ( $uid_status == 0 ) {
    setpwent;
    $uid_status = 1;
  }
  else {
    return $uids{$id} if defined $uids{$id};
  }

  return $id if $uid_status > 1;

  while (@a = getpwent) {
    # enter in table, not overriding exisiting values
    $uids{$a[2]} = $a[0] unless defined $uids{$a[2]};
    return $a[0] if $a[2] == $id;
  }
  endpwent;
  $uid_status = 2;

  return ($id);
}

# this subroutine determines group name from id - with cacheing
sub fmt_gid {
  my ($id) = shift (@_);
  my (@a);

  if ( $gid_status == 0 ) {
    setgrent;
    $gid_status = 1;
  }
  else {
    return $gids{$id} if defined $gids{$id};
  }

  return $id if $gid_status > 1;

  while (@a = getgrent) {
    # enter in table, not overriding exisiting values
    $gids{$a[2]} = $a[0] unless defined $gids{$a[2]};
    return $a[0] if $a[2] == $id;
  }
  endgrent;
  $gid_status = 2;

  return ($id);
}

# this subroutine kills a process with a given pid
sub killProcess {
  my ($pid) = @_;
  my $error = 0;
  my $cnt = 0;
  # kill process and get number of processes killed
  $cnt = kill 15,$pid;
  # no process killed if counter is zero, so return errorcode 1
  $error = 1 if ($cnt == 0);
  return $error;
}

# this subroutine checks if a given pid belongs to an instance of OnlineBackup
sub checkInstance {
  my ($pid) = @_;
  # get my own name
  my $script = $0;
  # get basename (name without path) of myself
  $script =~ s|.*/||;
  print "checkInstance - Basename of script: " . $script . "\n"  if ($verbose > 2);
  my $stderrt;
  # set target of standard error to null if verbosity isn't greater than 2
  if ($verbose > 2) {
    $stderrt = ""
  } else {
    $stderrt = " 2>/dev/null";
  }
  # command for process list
  my $pscmd = "ps ax" . $stderrt;
  # alternative command for process list
  my $altpscmd = "ps -ef" . $stderrt;
  # get process list
  my $procs = `$pscmd`;
  if ( $? != 0) {
    # try alternative process command
    $procs = `$altpscmd`;
    return -1 if ( $? != 0);
  }
  if ( $procs =~ /$pid.*$script/ ) {
    # pid belongs to me
    return 1;
  } else {
    # it's not my pid
    return 0;
  }
}

# this subroutine shows the usage line
sub printUsage {
  print "Usage: OnlineBackup.pl [-c configfile]\n";
  exit 0;
}

# this subroutine terminates the script properly
sub terminate {
  my  ($error,$reason) = @_;
  # remove lockfile if there wasn't an existing lockfile of another instance
  if ($error != -2) {
    unlink ($lockfile);
  }
  if ( -f $temp_filelist ) {
    # remove a temporary file list
    unlink ($temp_filelist);
  }

  # write the endxml to the xml directory. 
  OLBUtils::writeEndXML($id,$privkeyfile,$rsyncbin,$remotehost,$remoteuser,$xmldir,$endxml,$error,$logfile,VERSION);

  # check cause of termination
  if ($error < 0) {
    # program was aborted
    $message = "Backup aborted because: " . $reason;
    # check if termination was not because of a failure to open log file
    if ($error != -3) {
      OLBUtils::writeLog ($message,"",$logfile);
      OLBUtils::writeLog ("------------------------------------","",$logfile);
    }
    print (STDOUT "$message\n");
  } elsif ($error > 0) {
    # some warnings / errors occured
    $message = "Backup finished with errors";
    OLBUtils::writeLog ($message,"",$logfile);
    OLBUtils::writeLog ("------------------------------------","",$logfile);
    print (STDOUT "$message\n") if ($verbose > 0);
  } elsif ($error == 0) {
    # all was fine
    $message = "Backup finished successfully";
    OLBUtils::writeLog ($message,"",$logfile);
    OLBUtils::writeLog ("------------------------------------","",$logfile);
    print (STDOUT "$message\n") if ($verbose > 0);
  }
  exit $error;
}

# this subroutine catches signals
sub catch_break {
  my $signame = shift;
  if ($signame eq "TERM") {
    # signal TERM was caught, abort immediately, also stop child processes
    kill 15, -$$;
  }
  terminate (-1,"Somebody sent me a SIG$signame!");
} 

# this subroutine sorts a list/array and eliminates duplicates by reference
sub uniquesort {
  my %seen = ();
  my ($ref_sort) = @_;
  @$ref_sort = sort {$a cmp $b} grep {!$seen{$_}++ } @$ref_sort;
}

# this subroutine excludes files or directories
sub excludeItem {
  my ($currentpath,$includepath,@excludes) = @_;
  my $excluded;
  my $doexclude = 0;
  my @plusincludes;
  my $recursiveexcl;
  my $recursiveincl;
  my $currentinclude = "";
  my $currentexclude = "";
  my $currentexclude_quoted = "";
  my $noexclude;

  EXCLUDE:
  foreach my $regex_exclude (@excludes) {
    $excluded = 0;
    $noexclude = 0;
    my $real_regex_exclude = $regex_exclude;
    my $currentpath = $currentpath;
    my $extra_escape = "\\\\\\\\\\\\\\\\";

    # Check if we have to match a simple (non-doubled) backslash because of wildcard character
    if ($regex_exclude =~ /(\*|\?|\[^\\\/\]\{1\}|\[)/) {
      $extra_escape =~ s/\\\\/\\/g;
    }

    if ($regex_exclude =~ /^(\\+)$extra_escape[\+]/) {
      # remove extra-escaped plus at beginning for matching a literal plus sign
      $real_regex_exclude =~ s/^(\\+)$extra_escape[\+]/$1+/;
    }

    if ($currentpath =~ /^(.*\/)*$real_regex_exclude(\/)*$/s) {
      # exclude rule matches current path
      $excluded = 1;
    }

    # do we have an include in excludes possibly inhibits the exclusion
    if ($regex_exclude =~ /^\\\+ /) {
      # remove the plus sign/space combination at beginning of the line for comparison with the current path
      $regex_exclude =~ s/^\\\+ //;
      # check if include item matches current path and some additional rules
      my @currentincluderecord = OLBUtils::findMatch ($currentpath,$regex_exclude, $basepathslashcharclassvalid);
      # add the include to a seperate list
      push (@plusincludes,\@currentincluderecord) if ($currentincluderecord[0] ne "");
    }

    if ($excluded == 1) {
      # path is excluded
      my $recexclude = 0;
      my $norecexcl = 0;
      my $subinclude = "";
      my $currentincluderef;

      if ($regex_exclude =~ /^(\\+)$extra_escape[\+]/) {
        # remove extra-escaped plus at beginning for matching a literal plus sign
        $regex_exclude =~ s/^(\\+)$extra_escape[\+]/$1+/;
      }
      # check some additional rules, e.g. concerning character classes
      ($currentexclude,$recursiveexcl) = OLBUtils::findMatch ($currentpath,$regex_exclude, $basepathslashcharclassvalid);
      $currentexclude_quoted = quotemeta($currentexclude);

      # if two asterisks then the exclude will be forced recursively over includes
      if ($recursiveexcl == 1) {
	if ($#plusincludes >= 0) {
	  # note that this exclusion rule goes over includes (hence recursive)
	  $recexclude = 1;
	}
      } 

      # if exclude was invalidated (is empty) by additional rules, don't exclude
      if ($currentexclude eq "") {
        next EXCLUDE;
      }

      # if a path deeper than the current excluded path was specified in include file, don't exclude
      if ($includepath =~ /^$currentexclude_quoted.+$/) {
        next EXCLUDE;
      }

      COMPAREPLUS: foreach $currentincluderef (@plusincludes) {
        ($currentinclude,$recursiveincl) = @$currentincluderef;
	print "excludeItem - Plusincludes: @plusincludes\n\nCurrentpath: $currentpath, Currentexclude: $currentexclude, Recursive Exclude: $recursiveexcl, Currentinclude: $currentinclude, Recursive Include: $recursiveincl, Subinclude: $subinclude, Recexclude: $recexclude\n" if ($verbose > 3);
	# is the plus included path exactly the same as the exclude?
        if ($currentexclude eq $currentinclude) {
	  # is exclude recursive but a deeper path is stored, so don't exclude
	  if (($recexclude == 1) && ($subinclude =~ /^$currentexclude_quoted.+$/)) {
	    $noexclude = 1;
	  # exclude isn't recursive or the current path is the same as excluded?
	  } elsif (($recexclude == 0) || ($currentpath eq $currentexclude)) {
	    $noexclude = 1;
	  }
	  # prevent recursive exclusion when exclude is the same as plus include
	  $norecexcl = 1;
	  # is the current include a deeper path under the current exclude?
	} elsif ($currentinclude =~ /^$currentexclude_quoted.+$/s) {
	  # is recursive forced exclusion set?
	  if ($recexclude == 1) {
	    # is recursive forced exclusion disabled?
	    if ($norecexcl == 1) {
	      # the path shouln't be excluded
	      $noexclude = 1;
	      last COMPAREPLUS;
	    } else {
	      # store this subpath for later comparison
	      $subinclude = $currentinclude;
	    }
	  }
	}
	# is the current include recursively forced, so don't exclude it
	if ($recursiveincl == 1) {
          $noexclude = 1;
	  last COMPAREPLUS;
	}
      }
      # end of COMPAREPLUS

      # plus include rules that avoid exclusion matched, then don't exclude
      if ($noexclude == 1) {
        $doexclude = 0;
        # otherways exclude
      } else {
        $doexclude = 1;
	# note also if exclude was recursive
	$doexclude += $recexclude if ($norecexcl == 0);
        last EXCLUDE;
      }
    }
  }
  # end of foreach excludes
  print "excludeItem - Plusincludes: @plusincludes\n\nCurrentpath: $currentpath, Currentexclude: $currentexclude, Recursive Exclude: $recursiveexcl, Currentinclude: $currentinclude, Recursive Include: $recursiveincl, Doexclude: $doexclude\n" if ($verbose > 3);
  return $doexclude;
}


