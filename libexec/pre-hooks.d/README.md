This is the pre hook script directory.
All files within this directory having the executable bit set, will be executed in alphabetical order before the backup process has started.

It is recommended to prefix the scripts (or symlinks) with a two digit number, for example:
* <code>00-run-me-first.sh</code>
* <code>01-run-me-second.sh</code>
* <code>99-run-me-last.sh</code>
