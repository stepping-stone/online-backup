#! /usr/bin/perl
################################################################################
#
# Name: OnlineRestore.pl
# Description: This perl script copies the files back from the backup
# system, and restores the permissions afterwards
#
# Author: Michael Rhyner
# History:
# 2005-08-17 mr created
# 2005-08-19 mr changed - removed scp call, using only rsync
# 2005-08-22 mr changed - added handling of multiple backups on remote side
# 2005-08-24 mr V 1.0 - added error handling on executing permission script
# 2006-03-06 mr V 1.1 - better console/log outut, added signal handling,
# 			ignore owner/group on rsync, buxfixes
# 2006-04-30 mr V 1.2 - added partial restore from a certain path on (--from)
#			and removed permission script before restore
# 2006-01-21 mr V 1.3 - imporved / corrected error handling, binaries configurable
# 2007-05-04 mr V 1.4 - adapted permission script pattern for cropping
# 2007-08-02 mr V 1.5 - common routines for backup and restore in OLBUtils.pm
# 2007-09-19 mr V 1.6 - small correction of slashes within square brackets were not correctly interpreted from restorepath
# 2007-10-17 mr V 1.7 - adapted restore of permissions using rsync list for current rsync version (2.6.9)
# 2007-10-21 mr V 1.8 - corrected verbosity level not effective within library functions
# 2008-02-10 mr V 1.9 - removed default remotehost, fixed permissions not being set for permission script on partial restore when using rsync list
################################################################################

use Sys::Hostname;
use strict;
my $script = $0;
my $basedir = $script;
$basedir =~ s:^(.*)\/(.*)$:$1:;
push (@INC, $basedir);

# setting default values
my $configfile = "../conf/OnlineBackup.conf";
my $logfile = "../log/OnlineBackup.log";
my $localdir = "/";
my $remotedir = "";
my $currentprefix = "/incoming/";
my $snapshotprefix = "/.snapshots/";
my $restorepath = "/";
my $tempdir="/var/tmp/";
my $rsyncbin = "rsync";
my $sshbin = "ssh";
my $rsynclist = 1;
our $verbose = 0;

# declare variables
my %config;
my $snapshot;
my $destination;
my $source;
my $prefix;
my $remotehost;
my $remoteuser;
my $privkeyfile;
my $permscript = "";
my $actualpermscript;
my $includestring;
my $message;
my @permlist;
my $error = 0;
my $rsyncrc = 0;
my $listonly = 0;
my $basepathslashcharclassvalid = 0;

# import utility subs
require OLBUtils;

# Handle signals
$SIG{INT} = \&catch_break;   # catch sigint
$SIG{QUIT} = \&catch_break;  # catch sigquit
$SIG{TERM} = \&catch_break;  # catch sigterm
$SIG{HUP} = \&catch_break;   # catch sighup
$SIG{PIPE} = \&catch_break;  # catch sigpipe
$SIG{ALRM} = \&catch_break;  # catch sigalrm
$SIG{USR1} = \&catch_break;  # catch sigusr1
$SIG{USR2} = \&catch_break;  # catch sigusr2

# Getting arguments
if ($#ARGV eq -1) {
  printUsage();
}

for (my $i = 0; $i<=$#ARGV; $i++) {
  if (($ARGV[$i] eq "-h") || ($ARGV[$i] eq "--help")) {
    printUsage();
  }
  if (($ARGV[$i] eq "-c") || ($ARGV[$i] eq "--config")) {
    $i++;
    $configfile = $ARGV[$i];
  }
  if (($ARGV[$i] eq "-s") || ($ARGV[$i] eq "--snapshot")) {
    $i++;
    $snapshot = $ARGV[$i];
  }
  if (($ARGV[$i] eq "-d") || ($ARGV[$i] eq "--destination")) {
    $i++;
    $destination = $ARGV[$i];
  }
  if (($ARGV[$i] eq "-f") || ($ARGV[$i] eq "--from")) {
    $i++;
    $restorepath = $ARGV[$i];
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

if ($config{TEMPDIR}) {
  $tempdir = $config{TEMPDIR};
}

if ($config{RSYNCBIN}) {
  $rsyncbin = $config{RSYNCBIN};
}

if ($config{SSHBIN}) {
  $sshbin = $config{SSHBIN};
}

if ($config{RSYNCLIST} =~ /^[0-1]$/) {
  $rsynclist = $config{RSYNCLIST};
}

if ($snapshot eq "") {
  printUsage();
} elsif ($snapshot eq "current") {
  # set prefix to path of current backup plus remote directory
  $prefix=$currentprefix . "/" . $remotedir;
} else {
  # set prefix to path where the given snapshot resides plus remote directory
  $prefix=$snapshotprefix  . "/" . $snapshot . "/" . $remotedir;
}


# if no destination was given then set it to local base dir
if ($destination eq "") {
  $destination = $localdir;
} 

# strip needless slashes
$source = OLBUtils::removeSpareSlashes($prefix) . "/";
$destination = OLBUtils::removeSpareSlashes($destination);

$message = "Restore started";
OLBUtils::writeLog ($message,"",$logfile);
print (STDOUT "$message\n") if ($verbose > 1);

my @rsyncversions = OLBUtils::getRsyncVersion ($rsyncbin, $logfile);
# Check if rsync is available
if ($rsyncversions[0] == -1) {
  terminate (-1, "cannot execute $rsyncbin, reason: $rsyncversions[1]!");
}
# check version of rsync
if ( ! ( (($rsyncversions[0] == 1) && ($rsyncversions[1] == 7) && ($rsyncversions[2] >= 0)) || (($rsyncversions[0] == 1) && ($rsyncversions[1] > 7)) || ($rsyncversions[0] > 1) ) ) {
  terminate (-1, "$rsyncbin isn't at version 1.7.0 or higher!"); 
}

# Build include string for feeding rsync if from path option is used
if ($restorepath ne "/") {
  # Check if rsync is in a version suitable for a given from path
  if ( ! ( (($rsyncversions[0] == 2) && ($rsyncversions[1] == 6) && ($rsyncversions[2] >= 0)) || (($rsyncversions[0] == 2) && ($rsyncversions[1] > 6)) || ($rsyncversions[0] > 2) ) ) {
    terminate (-1, "$rsyncbin isn't at version 2.6.0 or higher, only a full restore (without '-f' option) can be done!"); 
  }

  # escape wildcard characters in leading path
  my @pathparts = split (/\//,$restorepath);
  my $num_pathparts = $#pathparts;
  my $i=0;
  my %wildcards;
  my $lastclass = 0;
  my $concatpart = "";
  $restorepath = "";
  # go trough every part of the path
  foreach my $pathpart (@pathparts) {
    if ( OLBUtils::isCharClass($pathpart,$lastclass) && ($i < $num_pathparts) ) {
      # a slash within a character class is not any more a path delimiter, so concatenate those parts together and skip to the next part (if not the last part)
      if ($concatpart ne "") {
        $concatpart .= "/" . $pathpart;
      } else {
        $concatpart .= $pathpart;
      }

      # note that this part ends with an open character class
      $lastclass = 1;
      $i++;
      next;
    } else {
      # note that this part don't ends with an open character class
      $lastclass = 0;
    }
    if ($concatpart ne "") {
      # path part was saved for concatenating, add it before the current part
      $pathpart = $concatpart . "/" . $pathpart;
      $concatpart = "";
    }
    # check if we are not at the last part
    if ($i < $num_pathparts) {
      # escape wildcards in leading parts
      %wildcards = ("\\*" => "\\*",
		    "\\?" => "\\?",
		    "\\[" => "\\[");
      $restorepath .= OLBUtils::replaceWildcards($pathpart, %wildcards) . "/";
    } else {
      # leave alone last part
      $restorepath .= $pathpart;
    }
    $i++;
  }
  print "Restorepath: $restorepath\n" if ($verbose > 3);
  # avoid that double asterisks cause recursion (if not at end of restore path)
  %wildcards = ("\\\*+" => "*");
  $restorepath = OLBUtils::replaceWildcards($restorepath, %wildcards);
  # asterisk at end of restore path will cause recursion
  %wildcards = ("\\\*\$" => "**");
  $restorepath = OLBUtils::replaceWildcards($restorepath, %wildcards);

  # build rsync include parameter
  $includestring = buildIncludeString($restorepath);
  $includestring = $includestring . buildIncludeString($permscript);
}

# get rsync version to determine if file list from rsync can be used
my @rsyncversions = OLBUtils::getRsyncVersion ($rsyncbin, $logfile);
if ( (($rsyncversions[0] == 2) && ($rsyncversions[1] == 6) && ($rsyncversions[2] >= 7)) || (($rsyncversions[0] == 2) && ($rsyncversions[1] > 6)) || ($rsyncversions[0] > 2) ) {
  # conditions allow to use rsync file list...
  $listonly=1;
  # ...and quoting filenames in remote shell command
  $sshbin = "\'$sshbin\'";
  $privkeyfile = "\'$privkeyfile\'";
}

# move old permission script away
if (-f $destination . "/" . $permscript) { rename ($destination . "/" . $permscript, $destination . "/" . $permscript . ".bak") };

# if a from path is given
if ($restorepath ne "/") {
  # restore only from this path and the permission script

  if ( ($listonly == 1) && (-w $tempdir) && ($rsynclist == 1) ) {
    # build file list for setting permissions by using file list from rsync

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
    my $temp_filelist=OLBUtils::removeSpareSlashes($tempdir . "/.filelist.tmp");
    open (FILELIST, "> $temp_filelist") or terminate (-1,"open $temp_filelist for writing: $!");
    # write every include line to the file list
    print FILELIST $includestring;
    close FILELIST;
    # call rsync to transfer the files from the backup server to the local machine
    my $cmd = "\"$rsyncbin\" -rlHtDvvze \"$sshbin -i $privkeyfile\" --include-from=\"$temp_filelist\" -8 --exclude=\"*\" $remoteuser\@$remotehost:$source \"$destination\"";
    print "rsync call: " . $cmd . "\n" if ($verbose > 2);
    open (RSYNCOUT, "$cmd 2>>\"$logfile\" |") or terminate (-1,"cannot call rsync: $!");
    open (LOGFILE, '+>>', $logfile) or terminate (-3, "cannot open logfile!"); 
    my $restorepath_pattern = OLBUtils::removeSpareSlashes($restorepath);
    # split and get number of path elements of restore pattern
    my @pathparts_pattern = split (/\//,$restorepath_pattern);
    my $num_pathparts_pattern = $#pathparts_pattern;
    # don't count empty path element because of leading slash
    $num_pathparts_pattern-- if ($pathparts_pattern[0] eq ""); 

    LISTWALK: while (my $item = <RSYNCOUT>) {
      # only match inclusion lines encapsed by certain fix text
      if ($item=~/^(\[.*\]\s)*(including|showing)\s\w+\s(.*)\sbecause of pattern\s(.*)$/) {
	print "Line for inclusion of rsync: $item\n" if ($verbose > 3);
        # extract pathname only
        $item=~s/^(\[.*\]\s)*(including|showing)\s\w+\s(.*)\sbecause of pattern\s(.*)$/$3/;
        # split and get number of path elements of item
	my @pathparts_item = split (/\//,$3);
	my $num_pathparts_item = $#pathparts_item;
	# only match lines with items that are of the same depth or deeper as the restorepath or it's the permission script
	if ( ($num_pathparts_item < $num_pathparts_pattern) && ($4 ne OLBUtils::removeSpareSlashes ("/" . $permscript)) ) {
	  print "Skipping $3 not the same depth or deeper as $restorepath_pattern\n" if ($verbose > 3);
          print (LOGFILE "$item");
	  next LISTWALK;
	}
      } elsif ( ($item=~/^receiving file list \.\.\. $/) || ($item=~/^sent.*sec$/) || ($item=~/^total size.*speedup.*$/) || ($item =~ /^\s*$/) ) {
        print (LOGFILE "$item");
        next LISTWALK;
      } else {
        next LISTWALK;
      }

      # write item to log file
      print (LOGFILE "$item");

      # replace control characters escaped by \#ddd with \ddd
      foreach my $controlchar (keys %controls) {
        $item=~s/$controlchar/$controls{$controlchar}/g;
      }  

      # path item looks like a symlink
      if ($item =~ /^(.+)\s->\s(.+)$/) {
        if (-l $destination . "/" . $1) {
          # symlink, only get link itself (not the target)
          $item =~ s/^(.+)\s->\s(.+)$/\1/g;
        }
      }
      # add the file/directory to the permissions file list
      push (@permlist,$item);
    }
    close (RSYNCOUT);
    close (LOGFILE);
    $rsyncrc = $?;
    unlink ($temp_filelist);
  } else {
    # only call rsync if calculating own filelist to match rsync rules
    my $cmd = "\"$rsyncbin\" -rlHtDvze \"$sshbin -i $privkeyfile\" --include-from=-  --exclude=\"*\" $remoteuser\@$remotehost:$source \"$destination\"";
    print "rsync call: " . $cmd . "\n" if ($verbose > 2);
    open (INPUT, "| $cmd 1>>\"$logfile\" 2>&1");
    print INPUT $includestring . "\n";
    close (INPUT);
    $rsyncrc = $?;
  }
} else {
  # full restore, no from path given
  # call rsync to transfer the files from the backup server to the local machine
  my $cmd = "\"$rsyncbin\" -rlHtDvze \"$sshbin -i $privkeyfile\" $remoteuser\@$remotehost:$source \"$destination\"";
  print "rsync call: " . $cmd . "\n" if ($verbose > 2);
  system ("$cmd 1>>\"$logfile\" 2>&1");
  $rsyncrc = $?;
}

# check return code of rsync
if ($rsyncrc == 0) {
  $message = "transfer from backup host OK";
  OLBUtils::writeLog ($message,"",$logfile);
  print (STDOUT "$message\n") if ($verbose > 1);
} elsif ($rsyncrc == 5120) {
  terminate (-1,"Somebody sent me a SIGINT!");
} else {
  $message = "Problems occured during transfer from backup host";
  OLBUtils::writeLog ($message,"",$logfile);
  print (STDERR "$message\n") if ($verbose > 1);
  $error = 1;
}

# if a restore path is given, modify permission script to set only restored part
if ($restorepath ne "/") {
  if ( ($listonly == 1) && (-w $tempdir) && ($rsynclist == 1) ) {
    $message = "Using rsync file list for includes/excludes"; 
    $actualpermscript = cropPermscriptByList($permscript,$destination,$restorepath,$rsyncbin,@permlist);
  } else {
    $message = "Calculating includes/excludes by myself"; 
    $actualpermscript = cropPermscriptByRules($permscript,$destination,$restorepath,$rsyncbin);
  }
  OLBUtils::writeLog ($message,"",$logfile);
} else {
  $actualpermscript = OLBUtils::removeSpareSlashes($destination . "/" . $permscript);
}

# Restore the permissions saved by OnlineBackup.pl
chmod (0700, $actualpermscript);
my $cmd;
if ($destination ne $localdir) {
  # restore to another path than backed up from
  $cmd = "\"$actualpermscript\" \"" . OLBUtils::removeSpareSlashes($destination) . "\""; 
  print "Call for permission script: $cmd\n" if ($verbose > 2);
} else {
  # restore to the original path
  my $localdirprefix = $localdir;
  $localdirprefix =~ s/^\/$//;
  $cmd = "\"$actualpermscript\" \"" . OLBUtils::removeSpareSlashes($localdirprefix) . "\""; 
  print "Call for permission script: $cmd\n" if ($verbose > 2);
}
system ("$cmd 1>>\"$logfile\" 2>&1");
if ($? & 127) {
  terminate (-1,sprintf("permission script died with signal %d\n", ($? & 127)));
} elsif ($? != 0) {
  $message = "Problems occured while setting file permissions. Check logfile $logfile !";
  OLBUtils::writeLog ($message,"",$logfile);
  print (STDERR "$message\n") if ($verbose > 1);
  $error = 1;
}

terminate($error);

# This subroutine shows the usage line
sub printUsage {
  print "Usage: OnlineRestore.pl -s <snapshot> [-c configfile] [-f from] [-d destination]\n";
  print "where <snapshot> can be current | daily.0-6 | weekly.0-3 | monthly.0-11\n";
  exit 0;
}

# This subroutine terminates the script properly
sub terminate {
  my ($error,$reason) = @_;

  # check cause of termination
  if ($error < 0) {
    # program was aborted
    $message = "Restore aborted because: " . $reason;
    if ($error != -3) {
      OLBUtils::writeLog ($message,"",$logfile);
      OLBUtils::writeLog ("------------------------------------","",$logfile);
    }
    print (STDOUT "$message\n");
  } elsif ($error > 0) {
    # some warnings / errors occured
    $message = "Restore finished with errors";
    OLBUtils::writeLog ($message,"",$logfile);
    OLBUtils::writeLog ("------------------------------------","",$logfile);
    print (STDOUT "$message\n") if ($verbose > 0);
  } elsif ($error == 0) {
    # all was fine
    $message = "Restore finished successfully";
    OLBUtils::writeLog ($message,"",$logfile);
    OLBUtils::writeLog ("------------------------------------","",$logfile);
    print (STDOUT "$message\n") if ($verbose > 0);
  }
  exit $error;
}

# this sub cuts out the lines of permission script for files to be restored using the file list retrieved from rsync
sub cropPermscriptByList {
  my $line="";
  my $scriptline="";
  my $item;
  my $script_item;
  my $compare_item;
  my $isheader;
  my @restorepaths;
  my ($permscript,$destination,$restorepath,$rsyncbin,@permlist) = @_;
  my $permscriptpath = OLBUtils::removeSpareSlashes($destination . "/" . $permscript);
  my $permscript_temp = $permscriptpath;
  my $specialfile;
  $permscript_temp =~ s/(.*)\.sh/$1Cropped.sh/;
  $restorepath = OLBUtils::removeSpareSlashes($restorepath);
  # open permission script
  open (FHIN,"<",$permscriptpath) or terminate (-1,"open $permscriptpath: $!");
  # open partial permission script
  open (FHOUT,">",$permscript_temp) or terminate (-1,"open $permscript_temp: $!");

  push (@restorepaths, $restorepath);
  print "cropPermscriptByList - Restorepath before conversion to regex: " . $restorepath . "\n" if ($verbose > 3);
  # convert to regular expressions for following the same rules as rsync 
  my $regexrp = (OLBUtils::prepareRsyncRegex($rsyncbin,$logfile,@restorepaths))[0];
  print "cropPermscriptByList - Regular Expression after conversion: " . $regexrp . "\n" if ($verbose > 3);

  # Remove entries from permission script if a path to start from is given

  $isheader = 1;
SCRIPTLOOP: while ($line = <FHIN>) {
    my $escapes = $line;

    # look if the line belongs to the header / preamble of the script
    if ( $isheader == 1 ) {
      if ( $line =~ /^.+ .*\"\$\{PREFIX\}\"\'.+/ ) {
        # real stuff begins
        $isheader = 0;
      } else {
        # write header of partial permission script
        print (FHOUT $line);
        next SCRIPTLOOP;
      }
    }

    # decide if last single apostrophe was escaped
    if ($line =~ /\\''($| [bc] \d+ \d+$| p$)/) {
     $escapes =~ s/^.*?([\\]+)''(\012)$/$1/m;
    } else {
     $escapes = "";
    }
    print "cropPermscriptByList - Escapes before end quotation mark: " . $escapes . ", Nubmer of Escapes: " . (length ($escapes) ) . "\n" if ($verbose > 3);
    if ( ($line !~ /'($| [bc] \d+ \d+$| p$)/) || ((length ($escapes) % 2) != 0) ) {
      $scriptline .= $line;
      print "cropPermscriptByList - Scriptline: " . $scriptline . "; Line: " . $line . "\n" if ($verbose > 3);
      next SCRIPTLOOP;
    } elsif ($scriptline ne "") {
      $scriptline .= $line;
      print "cropPermscriptByList - Concatenated line: " . $scriptline . "\n"  if ($verbose > 3); 
    } else {
      $scriptline = $line;
    }

    foreach $item (@permlist) {
      # check if filename begins with given subpath that should be restored
      $script_item = $scriptline;
      $compare_item = $item;
      chomp($script_item);
      chomp($compare_item);
      $script_item =~ s/\012/\\\#012/g;
      $compare_item =~ s/\012/\\\#012/g;
      $script_item =~ s/^.*\"\$\{PREFIX\}\"\'(.*)\'(;.*$|$| [bc] \d+ \d+$| p$)/$1/;
      $compare_item =~ s/\'/'\\''/g;
      $compare_item = OLBUtils::removeSpareSlashes($compare_item);
      $script_item = OLBUtils::removeSpareSlashes($script_item);
      print "cropPermscriptByList - Script Item: $script_item \n" if ($verbose > 3);
      print "cropPermscriptByList - Compare Item: $compare_item \n" if ($verbose > 3);

      # check if item in script matches current one in list from rsync
      if ($script_item eq "/" . $compare_item) {
	print "cropPermscriptByList - $compare_item matches $script_item\n" if ($verbose > 3);
        # write to cropped permission script
	print "cropPermscriptByList - writing line: " . $scriptline . "\n" if ($verbose > 3);
        print (FHOUT $scriptline);
      } 
    }
    # check if it is a special file
    if ( ($scriptline =~ /^mknod \"\$\{PREFIX\}\"\'(.*)\'( [bc] \d+ \d+$| p$)/) || ($scriptline =~ /^.*\"\$\{PREFIX\}\"\'$specialfile\'(;.*$|$)/) ) {
      # test if restore path includes that file
      if ( checkItemByRules($script_item, $regexrp, $restorepath) ) {
	$specialfile = $script_item;
        # write to cropped permission script
        print "cropPermscriptByList - writing line: " . $scriptline . "\n" if ($verbose > 3);
        print (FHOUT $scriptline);
      }	else {
        $specialfile = "";
      }
    }
    # reset script line
    $scriptline = "";
  }
  close FHOUT;
  close FHIN;
  chmod (0700, $permscript_temp);
  return $permscript_temp;
}

# this sub cuts out the lines of permission script for files to be restored using pattern rules like rsync
sub cropPermscriptByRules {
  my $line="";
  my $scriptline="";
  my $script_item="";
  my $isheader;
  my ($permscript,$destination,$restorepath,$rsyncbin) = @_;
  my $permscriptpath = OLBUtils::removeSpareSlashes($destination . "/" . $permscript);
  my $permscript_temp = $permscriptpath;
  $permscript_temp =~ s/(.*)\.sh/$1Cropped.sh/;
  $restorepath = OLBUtils::removeSpareSlashes($restorepath);
  # open permission script
  open (FHIN,"<",$permscriptpath) or terminate (-1,"open $permscriptpath: $!");
  # open partial permission script
  open (FHOUT,">",$permscript_temp) or terminate (-1,"open $permscript_temp: $!");

  my @restorepaths;
  if ($restorepath =~ /(\*|\?|\[)/) {
    my %wildcards = ("\\\\\(?!\\*|\\?|\\[|\\\\)" => "\\\\");
    $restorepath = OLBUtils::replaceWildcards ($restorepath, %wildcards);
  } else {
    my %wildcards = ("\\\\\\\\" => "\\");
    $restorepath = OLBUtils::replaceWildcards ($restorepath,  %wildcards);
  }
  push (@restorepaths, $restorepath);

  print "cropPermscriptByRules - Restorepath before conversion to regex: " . $restorepath . "\n" if ($verbose > 3);
  # convert to regular expressions for following the same rules as rsync 
  my $regexrp = (OLBUtils::prepareRsyncRegex($rsyncbin,$logfile,@restorepaths))[0];
  print "cropPermscriptByRules - Regular Expression after conversion: " . $regexrp . "\n" if ($verbose > 3);

  # Remove entries from permission script if a path to start from is given
  $isheader = 1;
  SCRIPTLOOP: while ($line = <FHIN>) {
    my $eop;
    my $escapes = $line;

    # look if the line belongs to the header / preamble of the script
    if ( $isheader == 1 ) {
      if ( $line =~ /^.+ .*\"\$\{PREFIX\}\"\'.+/ ) {
        # real stuff begins
        $isheader = 0;
      } else {
        # write header of partial permission script
        print (FHOUT $line);
        next SCRIPTLOOP;
      }
    }

    # decide if last single apostrophe was escaped
    if ($line =~ /\\''($| [bc] \d+ \d+$| p$)/) {
     $escapes =~ s/^.*?([\\]+)''(\012)($| [bc] \d+ \d+$| p$)/$1/m;
    } else {
     $escapes = "";
    }
    print "cropPermscriptByRules - Escapes before end quotation mark: " . $escapes . ", Nubmer of Escapes: " . (length ($escapes) ) . "\n" if ($verbose > 3);
    if ( ($line !~ /'($| [bc] \d+ \d+$| p$)/) || ((length ($escapes) % 2) != 0) ) {
      $scriptline .= $line;
      print "cropPermscriptByRules - Scriptline: " . $scriptline . "; Line: " . $line . "\n" if ($verbose > 3);
      next SCRIPTLOOP;
    } elsif ($scriptline ne "") {
      $scriptline .= $line;
      print "cropPermscriptByRules - Concatenated line: " . $scriptline . "\n"  if ($verbose > 3); 
    } else {
      $scriptline = $line;
    }
    # set end of path
    if ( ($restorepath =~ /(\\*\*)$/) && (OLBUtils::isEscapedMetachar($1,"\\*") == 0) ) {
      # capture item in permission script until end of line
      $eop="(\/)*\'";
    } else {
      # capture item in permission script until last slash or end of line
      $eop="(\/|\')";
    }
    $script_item = $scriptline;
    $script_item =~ s/^(.*)\$\{PREFIX\}\"\'(\/*.*)$eop(.*)$/$2/s;
    $script_item =~ s/\'\\\'\'/'/g;
    print "cropPermscriptByRules - script Item: " . $script_item . "\n" if ($verbose > 3);
    # check if filename begins with given subpath that should be restored
    if ( checkItemByRules($script_item, $regexrp) || checkItemByRules($script_item, $permscript) ) {
      # write to cropped permission script
      print "cropPermscriptByRules - writing line: " . $scriptline . "\n" if ($verbose > 3);
      print (FHOUT $scriptline);
    }
    # reset script line
    $scriptline = "";
  }
  close FHOUT;
  close FHIN;
  chmod (0700, $permscript_temp);
  return $permscript_temp;
}

# check if an item (file / directory) matches following known include/exclude rules
sub checkItemByRules {
  my $regexrp;
  my $retval;
  my $eop;
  my $basepathslashcharclassvalid = 1;
  my $currentpath;
  my $recursive;
  my ($item,$regexrp_quoted, $restorepath) = @_;

  print "checkItemByRules - Restorepath: " . $restorepath . "\n" if ($verbose > 3);

  # set end of path
  if ( ($restorepath =~ /(\\*\*)$/) && (OLBUtils::isEscapedMetachar($1,"\\*") == 0) ) {
    # capture item in permission script until end of line
    $eop="(\/)*\$";
  } else {
    # capture item in permission script until last slash or end of line
    $eop="(\/|\$)";
  }
  # check if filename begins with given subpath that should be restored
    print "checkItemByRules - Line: " . $item . ", Regex: " . $regexrp_quoted . ", End of path pattern: " . $eop . "\n" if ($verbose > 3);
  if (($item =~ /^(\/)*($regexrp_quoted)$eop/s) ) {
    ($currentpath,$recursive) = OLBUtils::findMatch ($2,$regexrp_quoted,$basepathslashcharclassvalid);
  }
  # return true if regex was found in line or false if not 
  if ($currentpath ne "") {
    print "checkItemByRules - $regexrp_quoted matches $item\n" if ($verbose > 3);
    $retval = 1;
  } else {
    $retval = 0;
  }
}

# This subroutine builds an array with an incremental tree of a given path
sub buildIncrTree {
  my ($fullpath)=@_;
  my @arrincrtree;
  my @arrbasepath = split /\//,$fullpath;
  my $basepath = "";
  my $concatpart;
  my $lastclass = 0;
  # loop through all path parts
  for (my $i=0;$i<@arrbasepath;$i++) {
    # skip empty path part
    next if (@arrbasepath[$i] eq "");
    $basepath = $basepath . "/" . @arrbasepath[$i]; 
    if ( OLBUtils::isCharClass($basepath,$lastclass) && ($i < $#arrbasepath) ) {
      # a slash within a character class is not any more a path delimiter, so note that the last part ends with an open character class (if not the last part)
      $lastclass = 1;
    } else {
      # add the current base path to the incremental tree array
      push (@arrincrtree, OLBUtils::removeSpareSlashes($basepath));
      # note that this part don't ends with an open character class
      $lastclass = 0;
    }
  }
  return @arrincrtree;
}

# This subroutine creates the include string used for rsync on partial restore
sub buildIncludeString {
  my ($includepath) = @_;
  my @arrinclude = buildIncrTree ($includepath);
  my $i=0;
  my $includestring = "";
  my $line="";
  my $esc_bs_line="";
  my $asterisk;
  my $is_bs_doubled;
  foreach my $line (@arrinclude) {
    $i++; 
    if ($line =~ /(\*|\?|\[)/) {
      my %wildcards = ("\\\\\(?!\\*|\\?|\\[|\\\\)" => "\\\\");
      $line = OLBUtils::replaceWildcards ($line, %wildcards);
    } else {
      my %wildcards = ("\\\\\\\\" => "\\");
      $line = OLBUtils::replaceWildcards ($line, %wildcards);
    }
    if (($i == @arrinclude) && ($includepath =~ /[^\/](.*)\/*$/)) {
      # last line

      # prepare line with double backslashes when wildcards weren't present yet
      $esc_bs_line = $line;
      if ($line !~ /(\*|\?|\[)/) {
        $esc_bs_line =~ s/(\\)/$1$1/g;
      } else {
	# single backslash at end of string with wildcards causes illegal expression
        if ( ($esc_bs_line =~ /\\$/) && (OLBUtils::isEscapedMetachar($esc_bs_line,"\\\\") == 0) ) {
	  # so wipe escaped backslash line
	  $esc_bs_line = "";
	}
      }
      # add line to include string
      $includestring = $includestring . $line . "\n";

      if ( ($line =~ /\*$/) && (OLBUtils::isEscapedMetachar($line,"\\*") == 0) ) {
	# asterisk wildcard, add no additional asterisk
        $asterisk = "";
      } else {
	# no asterisk wildcard, add additional asterisk
        $asterisk = "*";
      }
      # if line contains a meta character
#      if ( ($line =~ /(\*|\?|\[)/) || ($asterisk eq "*") ) {
      if ($asterisk eq "*") {
	# use line with double backslashes
        $line = $esc_bs_line;
      }
      # single backslash at end (incomplete expression)
      if ( $esc_bs_line ne "" ) {
        # add rule for not matching additional characters until end of line
        $includestring = $includestring . "- $line$asterisk\n";
        # add rule for matching all under current directory
        $line = $esc_bs_line;
        $includestring = $includestring . "$line$asterisk*\n";
      }
    } else {
      # not last line, just add line to include string
      $includestring = $includestring . "$line/\n";
    }
  }
  print "buildIncludeString - Includestring: $includestring\n" if ($verbose > 2);
  return $includestring;
}

# This subroutine catches signals
sub catch_break {
  my $signame = shift;
  our $shucks++;
  if ($signame == "TERM") {
    kill 15, -$$;
  }
  terminate (-1,"Somebody sent me a SIG$signame!");
} 

