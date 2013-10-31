################################################################################
#
# Name: OLBUtils.pm
# Description: This perl module contains routines used by both perl scripts
# used for OnlineBackup, OnlineBackup.pl and OnlineRestore.pl.
# 
# Author: Michael Rhyner
# History:
# 2007-05-04 mr	V 1.0 - Created by outplacing common used subroutines
# 2007-05-07 mr V 1.1 - Added more comments
# 2007-06-12 mr V 1.2 - Fixed interpretation of backslashes in replaceWildcards
# 2007-07-31 mr V 1.3 - Added handling for exclamation mark (!) at begin of character class being the same as a circumflex (^) 
# 2011-09-13 pat.klaey@stepping-stone.ch V 2.0 - writeStartXML, writeEndXML and getXMLDateString implemented, to write the files required by the backup surveillance to the backup server
################################################################################

package OLBUtils;
use Sys::Hostname;
use File::Temp qw/ tempfile tempdir /;

use strict;
use vars (qw(@ISA @EXPORT));
require Exporter;
@ISA       = ('Exporter');
@EXPORT    = qw(&getRsyncVersion &writeLog &removeSpareSlashes &prepareRsyncRegex &replaceWildcards &isCharClass &findMatch &isEscapedMetachar &replaceVarRefs &readConf &writeStartXML &writeEndXML);

my $OS = $^O;

# This subroutine gets version information of rsync to determine features
sub getRsyncVersion {
  my ($rsyncbin,$logfile) = @_;
  my $rsyncversion;
  my @rsyncversions;
  my $errormsg;
  $rsyncversion = `\"$rsyncbin\" --version 2>/dev/null`;
  # return value -1 if not being able to call rsync and so find the version
  if ($? != 0) {
    if ($! eq "") {
      if ($? >> 8 == 126) {
        $errormsg = "Permission denied";
      } elsif ($? >> 8 == 127) {
        $errormsg = "No such file or directory";
      }
    } else {
      $errormsg = $!;
    }
    writeLog ("Cannot call rsync with " . $rsyncbin . " to determine features: " . $errormsg,"",$logfile);
    return (-1, $errormsg);
  }
  # grab version and protocol information
  $rsyncversion =~ s/^rsync.*version (\d+)\.(\d+)\.(\d+).*protocol version (\d+).*$/\1,\2,\3,\4/s;
  @rsyncversions = split (/,/,$rsyncversion);
  return @rsyncversions;
}

# This subroutine writes a message to the log file
sub writeLog {
  my ($message,$level,$logfile) = @_;
  my $timestamp = localtime(time);
  my $hostname = hostname();
  open (LOGFILE, '+>>', $logfile) or print ("cannot open logfile $logfile for logging $message!\n"); 
  print (LOGFILE "$timestamp $hostname $level $message\n");
  close (LOGFILE);
}

# this subroutine removes double or unneeded slashes from paths
sub removeSpareSlashes {
  my ($replacestring) = @_;
  # replace subsequent slashes by one slash
  $replacestring =~ s/(\/+)/\//g;
  # strip off a slash at the end of a string
  $replacestring =~ s/^(.+)\/$/$1/sg;
  return $replacestring;
}

# this subroutine prepares a (couple of) line(s) containing matching patterns to a regular expression line which behaves like used by rsync
sub prepareRsyncRegex {
  my $regex_line;
  my %wildcards;
  my ($rsyncbin,$logfile,@regex_lines) = @_;
  my %charclassmetas;
  my $regexerror;
  my $tripleasteriskdir;
  my @rsyncversions = getRsyncVersion ($rsyncbin,$logfile);
  if ( (($rsyncversions[0] == 2) && ($rsyncversions[1] == 6) && ($rsyncversions[2] >= 7)) || (($rsyncversions[0] == 2) && ($rsyncversions[1] > 6)) || ($rsyncversions[0] > 2) ) {
    $tripleasteriskdir = 1;
  }
  foreach my $regex_line (@regex_lines) {
    # escape backslash if no wildcard on line
    if ($regex_line !~ /(\*|\?|\[)/) {
      $regex_line =~ s/\\/\\\\/g;
    # remove backslash in front of regex meta characters if wildcards are used
    } else {
      %wildcards = ("\\\\\(?=[.(){}\$|])" => "");
      $regex_line = replaceWildcards ($regex_line, %wildcards);
    }
    # quote perl regex meta characters
    $regex_line =~ s/([.(){}\$|])/\\$1/g;

    # replace wildcard characters (must be done first before other replacements)
    %wildcards = (
    		"\\?" => "![^\/]{1}",
		"\\*" => "!.*");
    print "Before replaceWildcards: $regex_line\n" if ($::verbose > 3);
    $regex_line = replaceWildcards ($regex_line, %wildcards);
    print "After replaceWildcards: $regex_line\n" if ($::verbose > 3);

    # now replace all other regex meta characters
    %wildcards = (
		"\\\\d" => "\d",
		"\\\\s" => "\s",
		"\\\\w" => "\w",
		"\\\\D" => "\D",
		"\\\\S" => "\S",
		"\\\\W" => "\W",
		"\\\\A" => "A",
		"\\\\B" => "B",
		"\\\\C" => "C",
		"\\\\Z" => "Z",
		"\\\\N" => "N",
		"\\\\L" => "L",
		"\\\\U" => "U",
		"\\\\E" => "E",
		"\\\\Q" => "Q",
		"\\\\G" => "G",
		"\\\\X" => "X",
		"\\\\a" => "a",
		"\\\\b" => "b",
		"\\\\c" => "c",
		"\\\\e" => "e",
		"\\\\f" => "f",
		"\\\\l" => "l",
		"\\\\u" => "u",
		"\\\\n" => "n",
		"\\\\r" => "r",
		"\\\\t" => "t",
		"\\\\x" => "x",
		"\\\\z" => "z",
		"\\\\(?=[0-7]{3})" => "",
		"\\[:ascii:\\]" => "+[:ascii-invalid_POSIX_class_for_rsync:]",
		"\\[:word:\\]" => "+[:word-invalid_POSIX_class_for_rsync:]",
		"\\\\(?=[\\d])" => "",
		"\\[(?=.+\\])" => "!(?!\/)[",
		"\\\\\\\+" => "+",
		"\\\\p" => "p",
		"\\\\P" => "P");
    print "Before replaceWildcards: $regex_line\n" if ($::verbose > 3);
    $regex_line = replaceWildcards ($regex_line, %wildcards);
    print "After replaceWildcards: $regex_line\n" if ($::verbose > 3);

    # replace meta characters that have a different meaning in character classes
    %charclassmetas = ("!" => "^",
    		       "\\^" => "%");
    $regex_line = replaceMetaInCharClasses ($regex_line, %charclassmetas);
    print "After replaceMetaInCharClasses: $regex_line\n" if ($::verbose > 3);

    # the plus sign, single asterisk and slash at the beginning of line for including directories
    if ($regex_line =~ /^\+ \*\/$/) {
      $regex_line =~ s/^\+ \*\/$/\+ \.\*\\\//;
    # the asterisk at the beginning of line for matching all from top level
    } elsif ($regex_line =~ /^(\*)+$/) {
      $regex_line =~ s/^(\*)+$/\.\*/;
    } else {
      # replace plus sign with regex quoted plus sign
      $regex_line =~ s/\+/\\\+/g;
      # avoid that the containing directory itself is being excluded by asterisks after the slash
      $regex_line =~ s/\/(\.\*)$/\/(\.)($1)/g;
      # triple asterisk handling if this feature is enabled
      if ($tripleasteriskdir == 1) {
	# strip down to three asterisks if more are used
        $regex_line =~ s/\.\*\.\*(\.\*)+$/.*.*.*/g;
        # avoid that the containing directory itself is being excluded by /**
        $regex_line =~ s/\/(\.\*\.\*)$/\/(\.)($1)/g;
      } else {
	# strip down to two asterisks if more are used
        $regex_line =~ s/\.\*(\.\*)+$/.*.*/g;
        # avoid that the containing directory itself is being excluded by /*...
        $regex_line =~ s/\/((\.\*)+)$/\/(\.)($1)/g;
      }
      # replace single asterisk with regex for anything but a slash
      %wildcards = ("(?<!\\.\\*)\\.\\*" => "((?!\/)\.)\*");
      $regex_line = replaceWildcards ($regex_line, %wildcards);
    }
    # remove remainder of a line after a null character
    $regex_line =~ s/^(.*?)\000.*$/$1/s;

    # check for errors in regular expressions
    $regexerror = check_valid_regex ($regex_line);
    if ($regexerror) {
      writeLog ("Wrong syntax in item line: " . $regexerror,"",$logfile);
      $regex_line = "^\$";
    }
    print "Regex line: " . $regex_line . "\n" if ($::verbose > 3);
  }
  return @regex_lines;

}

# this subroutine replaces wildcard characters with regex equivalents, if not escaped
sub replaceWildcards {
  my ($regex,%wildcards) = @_;
  my $newregex;
  my $rplincharclasses;
  my $wildcard_pattern;
  foreach my $wildcard (keys %wildcards) {
    if ($wildcards{$wildcard} =~ /^\!/) {
      # an exclamation mark is used for avoiding transformation of the wildcard into a regex pattern within a character class
      $rplincharclasses = 0;
    } elsif ($wildcards{$wildcard} =~ /^\+/) {
      # a plus sign is used for transformation of the wildcard into a regex pattern only within a character class
      $rplincharclasses = 2;
    } else {
      $rplincharclasses = 1;
    }
    print "\n------\nreplaceWildcards - Regex: " . $regex . "; Wildcard: $wildcard" . "\n" if ($::verbose > 3);
    $newregex = $regex if ($newregex eq "");
    # check if given string contains current wildcard
    if ($regex =~ /($wildcard)/) {
      $wildcard_pattern = $1;
      # split string into parts delimited by wildcard
      my @patternprefixes = split (/$wildcard/,$newregex,-1);
      my $numparts = $#patternprefixes;
      my $i = 0;
      my $replace = "";
      my $noreplace = 0;
      my $charclass_pattern;
      my $ischarclass = 0;
      $newregex = "";
      # loop through splittted pattern to distinguish between escaped and non escaped wildcards
      foreach my $pattern (@patternprefixes) {
	my $escapes = $pattern;
	# looks that like an escape character?
  	if ($pattern =~ /\\$/) {
	  # capture all escapes
          $escapes =~ s/^.*?([\\]+)$/$1/;
	} else {
	  # empty escape string
	  $escapes = "";
	}
	# remove escapes from pattern
	$pattern =~ s/(\\)+$//g;
	# check if wildcard was marked for not being replaced in a char class
	if ($rplincharclasses == 0) {
	  # if it's really a character class or pattern is actually an open character class, ignore char class
	  if (isCharClass($charclass_pattern . $pattern,$ischarclass) == 1) {
	    $ischarclass = 1;
	    $noreplace = 1;
	  } else {
	    $ischarclass = 0;
	    $noreplace = 0;
	    $charclass_pattern = "";
	  }
	# check if wildcard was marked for only being replaced in a char class
	} elsif ($rplincharclasses == 2) {
	  # if it's really a character class or pattern is actually an open character class, ignore char class
	  if (isCharClass($charclass_pattern . $pattern,$ischarclass) == 1) {
	    $ischarclass = 1;
	    $noreplace = 0;
	  } else {
	    $ischarclass = 0;
	    $noreplace = 1;
	    $charclass_pattern = "";
	  }
	}
	if ( ((length ($escapes) % 2) == 0) && ($noreplace == 0) ) {
	  # even number of escape characters and replacement was not avoided, use the wildcard character/sequence for matching patterns, e.g. $replace = "[^\/]{1}" for a "?"
	  $replace = $wildcards{$wildcard};
	  if ($rplincharclasses == 0) {
	    # remove tag for not replacing within character classes
	    $replace =~ s/^\!//;
	    # Set charclass pattern to wildcard pattern if it is an opening square bracket so the next time an "[" was found, pattern will be seen as already in a char class
	    if ($wildcard_pattern eq "[") {
	      $charclass_pattern = $wildcard_pattern;
	    }
	  } elsif ($rplincharclasses == 2) {
	    # remove tag for replacing only within character classes
	    $replace =~ s/^\+//;
	  }
	} else {
	  # odd number of escape characters, or replacement was avoided, use the wildcard character literally, e.g. $replace = "\?" for a "?"
	  $replace = quotemeta($wildcard_pattern);
	  # replace backslash used in search string
	  $replace =~ s/\\(?!\\)//g;
	  # replace quoted backslashes back as before meta character quoting
	  $replace =~ s/\\\\/\\/g;
	  # replace look around sequence in search string
	  $replace =~ s/\(\?.+?\)//g;
	  if ($rplincharclasses == 2) {
	    # Set charclass pattern to wildcard pattern if it is an opening square bracket so the next time an "[" was found, pattern will be seen as already in a char class
	    if ($wildcard_pattern eq "[") {
	      $charclass_pattern = $wildcard_pattern;
	    }
	  }
	}
	if ($i < $numparts) {
	  # not last element of splitted entry, build new regex with the preamble pattern, escape characters and the replaced quantifier character
          $newregex .= $pattern . $escapes . $replace;
        } else {
	  # last element, only add remaining part (pattern) and backslashes (escapes)
	  $newregex .= $pattern . $escapes;
	}
	print "replaceWildcards - Pattern: " . $pattern . "; Escapes: " . $escapes . "; Replace: " . $replace . " result in " . $newregex . "\n" if ($::verbose > 3);
      	$i++;
      }
    }
  }
  $regex = $newregex;
  print "replaceWildcards - Regex to return: " . $regex . "\n" if ($::verbose > 3);
  return $regex;
}

# this subroutine checks if a certain path (or part of it) is in a character class
sub isCharClass {
  my ($regex,$lastopen) = @_;
  my $isclass = 0;
  my $bracket;
  my $prefix;
  my $posixclasspre = 0;
  my @compareparts = split (/(\[|\])/,$regex,-1);
  # loop through every part splitted on square brackets to examine if each bracket really means a character class begin or end
  foreach my $comparepart (@compareparts) {
    my $escaped;
    my $escapes;
    my $posixclass;
    # looks that like a square bracket?
    if ($comparepart =~ /(\[|\])/) {
      $bracket = $1;
    } else {
      $prefix = $comparepart;
      next;
    } 
    $prefix =~ s/\\/\\\\/g;
    $escaped = 0;
    # looks that like an escape character?
    if ($prefix =~ /([\\]+)$/g) {
      $escapes = $1;
      if ( ( (length ($escapes) / 2 ) % 2) == 0) {
	# even number of escape characters, e.g. $prefix = "[a-z]";
        $escaped = 0;
      } else {
	# odd number of escape characters, e.g. $prefix = "\[a-z\]";
        $escaped = 1;
      }
    }
    # looks that like a POSIX character class?
    if ($prefix =~ /^:.+:$/) {
      $posixclass = 1;
    } else {
      $posixclass = 0;
    }
    $prefix = "";
    if (($bracket eq "[") && ($escaped == 0)) {
      if (($lastopen) == 1) {
        $posixclasspre = 1;
      } else {
        $posixclasspre = 0;
      }
      $lastopen = 1;
    } elsif (($bracket eq "]") && ($escaped == 0)) {
      $lastopen = 0 if ( ($posixclass == 0) || ($posixclasspre == 0) );
    }
  }

  # determine if character class for regex part is still open, so character is within a char class
  if ($lastopen == 1) {
    $isclass = 1;
  }

  print "isCharClass - Regex: " . $regex . ", isclass: " . $isclass . ", Lastopen: " . $lastopen . "\n" if ($::verbose > 3);
  return $isclass;
}

# this subroutine replaces meta characters everywhere but not in character classes
sub replaceMetaInCharClasses {
  my ($regex,%metachars) = @_;
  my @charclasses;
  my $part;
  my $pattern;
  my $newregex;
  my $escaped;
  my $escapes = "";
  my $comparepart;
  my @compareparts;
  my $lastclass = 0;
  my $currentclass = 0;
  foreach my $metachar (keys %metachars) {
    if ($regex =~ /$metachar/) {
      @charclasses = split /$metachar/,$regex;
      my $i = 0;
      if ($#charclasses == -1) {
        $newregex = $regex;
      } else {
        $newregex = "";
      }
      # loop through every part splitted on given meta character to examine if the meta character is not escaped
      foreach $part (@charclasses) {
	$pattern = $metachar;
	$escaped = 0;
	# looks that like an escape character?
        if ($part =~ /([\\]+)$/) {
          $escapes = $1;
          if ( (length ($escapes) % 2) == 0) {
	    # even number of escape characters, e.g. "^", meta character isn't escaped
            $escaped = 0;
          } else {
	    # odd number of escape characters, e.g. "\^", meta character is escaped
            $escaped = 1;
          }
        }
	# check if meta character is within a character class or is escaped and wildcard appears on line
	if ( (isCharClass($part,$lastclass) == 1) || (($escaped == 1) && ($regex =~ /(\*|\?|\[)/) && ($metachars{$metachar} eq "%") ) ) {
	  if (isCharClass($part,$lastclass) == 1) {
	    $currentclass = 1;
	  } else {
	    $currentclass = 0;
	  }
	  # remove escaping of meta character
	  if ($metachars{$metachar} eq "%") {
	    $pattern =~ s/\\//;
	  # evaluate to replace meta character
	  } else {
	    if ( ($part =~ /^(.*)\[$/) && (! isEscapedMetachar($part, '\[')) ) {
	      # metachar must be at the beginning of a char class to be replaced
	      my $classprefix = $1;
	      if (isCharClass ($classprefix,$lastclass) == 0) {
		# prepending part not already within a char class, replace meta character
	        $pattern =~ s/$metachar/$metachars{$metachar}/;
	      }
	    }
	  }
	} else {
	  # otherwise meta character composition remains escaped / unchanged
	  $currentclass = 0;
        } 
	print "replaceMetaInCharClasses - Meta Character pattern: " . $pattern . " for part: " . $part . " seperated by metachar: " . $metachar . "\n" if ($::verbose > 3);
	# check if we are at the last part and rule doesn't end with meta char
	if ( ($i == $#charclasses) && ($regex !~ /$metachar$/) ) {
	  # add last part
	  $newregex .= $part;
	} else {
	  # add part and meta character pattern
	  $newregex .= $part . $pattern;
	}
	print "replaceMetaInCharClasses - original Regex: " . $regex . ", new Regex: " . $newregex . ", escaped: " . $escaped . ", currentclass: " . $currentclass . ", lastclass: " . $lastclass . "\n" if ($::verbose > 3);
	$lastclass = $currentclass;
	$i++;
      }
    $regex = $newregex;
    }
  }
  print "replaceMetaInCharClasses - resulting Regex: " . $regex . "\n" if ($::verbose > 3);
  return $regex;
}

# this subroutine tests if a regex has a correct syntax and either returns null string or the error from regex engine
sub check_valid_regex ($)
{
  eval { qr/$_[0]/ };
  return $@;
} 

# this subroutine searches the part of the path for a regular expression match and checks for some special cases, returns either a string with the found/verified path or the empty string if not
sub findMatch {
  my ($currentpath,$regex,$basepathslashcharclassvalid) = @_;
  my $matchingpath;
  my $recursiveflag = 0;
  my @regexparts;
  my $regexpart;
  my $i = 0;
  my $lastcharclasscirc = 0;
  if ($currentpath =~ /^((.*\/)*$regex(\/)*)$/s) {
    # expression matches (a part of) the current path, then extract the path
    $matchingpath = $1; 
    $recursiveflag = 1 if ($regex =~ /\(\?\!\/\)\.\)\*\.\*\)?$/);
  } else {
    return ($matchingpath,$recursiveflag);
  }

  # for slashes in character classes which make the regex non-matching if not beginning at the top level of the path
  if ( ($regex =~ /\//) && ($regex !~ "^\/.+") && (!(($basepathslashcharclassvalid == 1) && ($matchingpath =~ /^(\/)?$regex/))) ) {
    # split the matching rule (regex) into parts delimited by a slash to determine if it is within a character class
    @regexparts = split (/\//,$regex);
    my $numparts = $#regexparts;
    # now loop through every part
    foreach $regexpart (@regexparts) {
      $i++;
      # check if part might be a charclass (2nd capture not named char class)
      if ( $regexpart =~ /(\\*\[(?!\:)(.*))$/ ) {
        # extract the part with the character class meta characters
	my $charclasspart = $1;
        # extract only the content of the character class
	my $charclasscontent = $2;
	# actually check if part with character class meta chars is really a char class
        if (isCharClass($charclasspart)) {
	  # do not disable matching of regex pattern for a single character within a path ([^\/]{1}) - first part
	  if ( $charclasscontent !~ /\^/ ) {
            print "findMatch - Regex $regex with relevant comparison parts $charclasspart,/,$charclasscontent has a slash in a character class, so don't match!\n" if ($::verbose > 3);
	    # clear the matching path to be returned for not matching the rule
            $matchingpath = "";
            $recursiveflag = 0;
	  } else {
	    # a circumflex, maybe the begin of a one-char pattern so note that 
	    $lastcharclasscirc = 1;
	  }
        }
      } elsif ($lastcharclasscirc == 1) {
	# do not disable matching of regex pattern for a single character within a path ([^\/]{1}) - second part
        if ($regexpart !~ /(\]\{1\})/) {
	  my $charclasspart = $1;
          print "findMatch - Regex $regex with relevant comparison part $charclasspart has a slash in a character class, but isn't a one-char pattern, so don't match!\n" if ($::verbose > 3);
	  # clear the matching path to be returned for not matching the rule
	  $matchingpath = "";
          $recursiveflag = 0;
	}
	# reset the state being a char class with a circumflex
        $lastcharclasscirc = 0;
      }
    }
  }

  # for circumflex negated POSIX character classes which make the regex non-matching
  if ($regex =~ /\^/) {
    # split the matching rule (regex) into parts delimited by a circumflex to determine if it is within a character class
    @regexparts = split (/\^/,$regex);
    # now loop through every part
    foreach $regexpart (@regexparts) {
      # check if pattern might be a named charclass
      if ( $regexpart =~ /(\\*\[.*?)(\\*\[\:)$/ ) {
	# actually check if captures are really char classes
        if ( (isCharClass($1)) && (isCharClass($2)) ) {
          print "findMatch - Regepart $regexpart of Regex $regex with relevant comparison parts $1,$2 has a circumflex in a POSIX named class, so don't match!\n" if ($::verbose > 3);
	  # clear the matching path to be returned for not matching the rule
          $matchingpath = "";
          $recursiveflag = 0;
        }
      }  
    }
  }
  return ($matchingpath,$recursiveflag);
}

# this subroutine checks if a string ends with an escaped meta character
sub isEscapedMetachar {
  my $escaped;
  my $prefix;
  my $metachar;
  my $escapes = "";
  ($prefix,$metachar) = @_;
  $prefix =~ s/^(.*)$metachar$/$1/;
  $prefix =~ s/\\/\\\\/g;
  $escaped = 0;
  # looks that like an escape character?
  if ($prefix =~ /([\\]+)$/g) {
    $escapes = $1;
    if ( ( (length ($escapes) / 2 ) % 2) == 0) {
      # even number of escape characters, e.g. $prefix = "*";
      $escaped = 0;
    } else {
      # odd number of escape characters, e.g. $prefix = "\*";
      $escaped = 1;
    }
  }
  $prefix = "";
  return $escaped;
}

# this subroutine replaces variable references by references to the environment if not escaped and not in a character class
sub replaceVarRefs {
  my ($regex,@metachars) = @_;
  my @parts;
  my $part;
  my $pattern;
  my $newregex;
  my $escapes = "";
  my $varname;
  my $varvalue;
  my $newpart;
  my $prefix;
  my $suffix;
  # loop through meta characters used as a variable indicator
  foreach my $metachar (@metachars) {
    if ($regex =~ /$metachar/) {
      @parts = split (/$metachar/,$regex,-1);
      my $i = 0;
      my $escaped = 0;
      $newregex = "";
      # loop through every part splitted on given meta character to get the name of the variable
      foreach $part (@parts) {
	$prefix = "";
	$suffix = "";
	$pattern = $metachar;
	if (($part =~ /^(\{)(.*)(\})(.*)$/) && ($i > 0)) {
	  # get all parts for variable name in curly brackets
	  $prefix = $1;
	  $varname = $2;
	  $suffix = $3;
	  $newpart = $4;
	} elsif (($part =~ /^(.*?)(([[:punct:]]|$).*)/) && ($i > 0)) {
	  # get variable name and rest for variable name without curly brackets, delimited by punctuation mark
	  $varname = $1;
	  $newpart = $2;
	} else {
	  # nothing that looks like a variable is added as is
	  $newpart = $part;
	}
	# check if variable indicator is escaped or name is empty
	if ( ($escaped == 1) || ($varname eq "") ) {
	  # use variable indicator and name literally 
	  $pattern =~ s/\\($metachar)/$1$prefix$varname$suffix/;
	  $escaped = 0;
	} else {
	  # get and use variable contents
	  $varvalue = $ENV{$varname};
	  $pattern =~ s/\\$metachar/$varvalue/;
	}
	print "replaceVarRefs - Meta Character pattern: " . $pattern . ", variable name: " . $varname . " for part: " . $part . " seperated by metachar: " . $metachar . "\n" if ($::verbose > 3);
	if ($i == 0 ) {
	  # add first part
	  $newregex .= $newpart;
	} else {
	  # add 2nd and further parts
	  $newregex .= $pattern . $newpart;
	}
	print "replaceVarRefs - original Regex: " . $regex . ", new Regex: " . $newregex . "\n" if ($::verbose > 3);
	# looks that like an escape character?
        if ($part =~ /([\\]+)$/) {
          $escapes = $1;
          if ( (length ($escapes) % 2) == 0) {
	    # even number of escape characters, e.g. "$HOME", variable indicator not escaped
            $escaped = 0;
          } else {
	    # odd number of escape characters, e.g. "\$HOME", variable indicator escaped
            $escaped = 1;
          }
        } 
	$i++;
      }
      $regex = $newregex;
    }
  }
  return $regex;
}

# this subroutine reads the configuration file
sub readConf {
  my ($configfile) = @_;
  my %config;
  # localize glob of filehandle (because a filehandle cannot be localized)
  local *CONFIG;
  # open config file
  open ( CONFIG, $configfile ) or ::terminate (-1,"open $configfile: $!");
  # read line by line of config file
  while ( my $config = <CONFIG> ) {
    # ignore comments or empty lines consisting only of spaces
    next if (($config =~ /^#|;/) || ($config =~ /^\s*$/));
    # get option name and its value
    my ($opt,$value) = $config =~ /^(\w+)\s*=\s*(.*)/;
    # replace variables by their contents
    my @metachars = ("\\\$");
    $value = replaceVarRefs ($value,@metachars);
    # assign value to a configuration option
    $config{$opt} = $value;
    print ("readConf - Setting option " . $opt . " to value " . $value . "\n") if ( ($::verbose > 2) || ($config{VERBOSE} > 2) );
  }
  # close filehandle
  close (CONFIG);
  
  # give back configuration hash structure
  return %config;

}

sub writeStartXML{

  my ($id,$privkeyfile,$rsyncbin,$remotehost,$remoteuser,$writedir,$startxml,$schedulerxml,$minuteSelected,$hourSelected,$logfile,$version)=@_;

  # command to test whether the .sepiola directory already exists in the
  # ~/incoming/remotedir directory on the backup-server
  my $cmd="ssh $remoteuser\@$remotehost -i $privkeyfile 'ls -al $writedir'";

  # execute the command and capture return code. 
  system("$cmd >/dev/null 2>>$logfile");
  my $return_code=$? >> 8;

  # test if directory could be accessed, if yes the error code is 0 and 
  # everything is fine. Otherwise check what kind of error we have.
  if($return_code!=0){
  	# if the error-code is two, the directory does not exist, so let's 
  	# create it
  	if($return_code == 2){
	  writeLog("Creating $writedir directory","",$logfile);
	  print "Creating $writedir directory\n" if $::verbose>1;
	  $cmd="ssh $remoteuser\@$remotehost -i $privkeyfile 'mkdir -p $writedir'";
	  system($cmd);
  	}
	# otherwise log the error
	else{
	  writeLog("Cannot access $writedir directory: ".
	  $return_code.".","",$logfile);
	  print "Cannot access $writedir directory: ".
	  $return_code.".\n" if $::verbose>1;
	}
  }

  # now we can write the backupStared.xml file to this directory
  writeLog("Writting $startxml","",$logfile);
  print "Writting $startxml\n" if $::verbose>2;

  #TODO: date currently form client, would be better from server!! 
  # get the date for the XML file
  my $date=getXMLDateString();
  #$date=~s/\n//; # removes the newline at the end of the date string
  # generate the XML string which is then written to the file.
  my $XMLString="<?xml version=\"1.0\"?>
 
<backup_started
xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"
xsi:schemaLocation=\"http://xml.stepping-stone.ch/schema/backup_started backup_started.xsd\">
	<startdate>$date</startdate>
	<id>$id</id>
    <client>
        <identifier>Online Backup Perl Script</identifier>
        <version>$version</version>
        <operatingsystem>$OS</operatingsystem>
    </client>
</backup_started>";

  # Create a safe temporary file
  my ($tempfile, $tmp_filename) = tempfile();
  
  # Write the XML string to the XML file
  print $tempfile $XMLString;
  
  # generate the command to write the XML string to the file on the
  # remotehost
  $cmd="$rsyncbin -e \"ssh -i $privkeyfile\" $tmp_filename $remoteuser\@$remotehost:$writedir/$startxml";

  # execute the command and analyse the return code
  system("$cmd >/dev/null 2>>$logfile");
  if($? != 0){
	# if the return code is not equal to 0 there went something wrong
	# log it.
	writeLog("Could not write $startxml","",$logfile);
	print "Could not write $startxml\n" if $::verbose>1;
  }
  else{
	writeLog("$startxml written","",$logfile);
	print "$startxml written\n" if $::verbose>1;
  }
  
  # Remove the tempfile
  unlink ( $tmp_filename );

  # Now write the scheduler file to the same directory
  # extract the timezone from the date string.
  $date=~/T/;
  my $timezone=$';
  $timezone=~/(\+|\-)/;
  $timezone=$&.$';

  # generate the XML sting for the scheduler.xml file. 
  my $schedulerString = "<?xml version=\"1.0\"?>
 
<online_backup_schedule
xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"
xsi:schemaLocation=\"http://xml.stepping-stone.ch/schema/online_backup_schedule online_backup_schedule.xsd\">
 
  <custom_online_backup>
    <minutes>
      <minute_selected>$minuteSelected</minute_selected>
    </minutes>
    <hours>
      <hour_selected>$hourSelected</hour_selected>
    </hours>
    <days_of_month>
      <every_day_of_month>*</every_day_of_month>
    </days_of_month>
    <months>
      <everymonth>*</everymonth>
    </months>
    <days_of_week>
      <every_day_of_week>*</every_day_of_week>
    </days_of_week>
    <timezone>$timezone</timezone>
  </custom_online_backup>
  <client>
    <identifier>Online Backup Perl Script</identifier>
    <version>$version</version>
    <operatingsystem>$OS</operatingsystem>
  </client>
 
</online_backup_schedule>";

  # Create a safe temporary file
  my ($scheduler_tempfile, $scheduler_tmp_filename) = tempfile();
  
  # Write the XML string to the XML file
  print $scheduler_tempfile $schedulerString;


  $cmd="$rsyncbin -e \"ssh -i $privkeyfile\" $scheduler_tmp_filename $remoteuser\@$remotehost:$writedir/$schedulerxml";

  # execute the command and analyse the return code
  system("$cmd >/dev/null 2>>$logfile");
  if($? != 0){
	# if the return code is not equal to 0 there went something wrong
	# log it.
	writeLog("Could not write $schedulerxml","",$logfile);
	print "Could not write $schedulerxml\n" if $::verbose>1;
  }
  else{
	writeLog("$schedulerxml written","",$logfile);
	print "$schedulerxml written\n" if $::verbose>1;
  }

  # Remove the tmpfile
  unlink ( $scheduler_tmp_filename );

}


sub writeEndXML{

  my ($id,$privkeyfile,$rsyncbin,$remotehost,$remoteuser,$writedir,$endxml,$error,$logfile,$version)=@_;

  # now we can write the backupStared.xml file to this directory
  writeLog("Writting $endxml","",$logfile);
  print "Writting $endxml\n" if $::verbose>2;

  #TODO: date currently form client, would be better from server!! 
  # get the date for the XML file
  my $date=getXMLDateString();
  # $date=~s/\n//; # removes the newline at the end of the date string

  # check if the backup was successful
  my $success;
  if($error==0){
	$success=1;
  }
  else{
	$success=0;
  }
  
  # generate the XML string which is then written to the file.
  my $XMLString="<?xml version=\"1.0\"?>

<backup_ended
xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"
xsi:schemaLocation=\"http://xml.stepping-stone.ch/schema/backup_ended backup_ended.xsd\">
	<enddate>$date</enddate>
	<id>$id</id>
	<success>$success</success>
    <client>
        <identifier>Online Backup Perl Script</identifier>
        <version>$version</version>
        <operatingsystem>$OS</operatingsystem>
    </client>
</backup_ended>";


  # Create a safe temporary file
  my ($tempfile, $filename) = tempfile();
  
  # Write the XML string to the XML file
  print $tempfile $XMLString;
  
  # generate the command to upload the tempfile to the backup server
  my $cmd="$rsyncbin -e \"ssh -i $privkeyfile\" $filename $remoteuser\@$remotehost:$writedir/$endxml";

  # execute the command and analyse the return code
  system("$cmd >/dev/null 2>>$logfile");
  if($? != 0){
	# if the return code is not equal to 0 there went something wrong
	# log it.
	writeLog("Could not write $endxml","",$logfile);
	print "Could not write $endxml\n" if $::verbose>1;
  }
  else{
	writeLog("$endxml written","",$logfile);
	print "$endxml written\n" if $::verbose>1;
  }
  
  # Remove the temporary file
  unlink( $filename );

}

sub getXMLDateString{

  # get the time to feed localtime and gmtime
  my $time = time;

  # get the localtime, store in array as: second, minute, hour, day, month, year
  my @date = localtime($time);
  # add 1900 to the year, since year beginns at 1900
  $date[5]+=1900;

  # add 1 to the month (array counting != human being counting!!!!)
  $date[4]+=1;

  # calculate the timezone offset, by subtracting the gmt from the localtime
  # (hours and minutes only)
  my @gmt = gmtime($time);
  my $hour_offset = $date[2]-$gmt[2];
  my $minute_offset= $date[1]-$gmt[1];

  # calculate the offset by multiplying the hours by 60 and add the minutes
  my $timezone = ( $hour_offset * 60 ) + $minute_offset;
  # then divide by 60, now we have the timezone in hours (decimal), the
  # conversion to the time-format will be done later
  $timezone/=60;


  # go through the whole date array an formatt the numbers
  foreach my $piece (@date){

	# if the given number is smaller than 10 we need to add a 0 before the number
	# itslef
	if($piece < 10){
	  $piece="0".$piece;
	}

  } # end foreach my $piece (@date)

  # format the timezone like +04:30 or -05:00:
  # first check if the timezone is positive or negativ, then check if we need to
  # add a 0 before the number itself (2 => 02), and finally check if it's a 
  # integer (no decimal part) or if we have to calculate the decimal part to
  # minutes. 

  if($timezone > 0){
  
	# if the number is less than 10 we need to add a 0 before the number itself
	if ($timezone < 10){
	  $timezone="0".$timezone;
	} # end if timezone < 10

	# if the number is not an integer we need to calculate the decimal part into
	# minutes, what is easy here. There is only one case where the timezone is
	# not a integer, it the case where the timezone is 4.5 or 5.5 but it's
	# always *.5 so we can multiply by to get 30 minutes. 
	if($timezone=~/\./){
	  $timezone="+".$`.":".$'*6;
	}
	# otherwise just add :00 to the timezone number
	else{
	  $timezone="+".$timezone.":00";
	} # end if timezone=~/\./

  } # end if timezone > 0
  else{

	# if the timezone is negative we need to extract the number (actually we just
	# delete the '-')
	$timezone=~/(\d+.*\d*)/;
	$timezone=$&;

	# if the number is less than 10 we need to add a 0 before the number itself
	if($timezone < 10){
	  $timezone="0".$timezone;
	} # end if timezone < 10

	# if the number is not an integer we need to calculate the decimal part into
	# minutes, what is easy here. There is only one case where the timezone is
	# not a integer, it the case where the timezone is -4.5 or -5.5 but it's
	# always -*.5 so we can multiply by to get 30 minutes.
	if($timezone=~/\./){
	  $timezone="-".$`.":".$'*6;
	}
	# otherwise just add :00 to the timezone number
	else{
	  $timezone="-".$timezone.":00";
	} # end if timezone=~/\./
  } # end else from if timezone > 0

  return $date[5]."-".$date[4]."-".$date[3]."T".$date[2].":".$date[1].":".$date[0].$timezone;

}

1;
