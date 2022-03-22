# Instructions for deb packaging

To build deb packages for Debian/Ubuntu, checkout the debian branch of this repository and 
use youre favorit build chain.

## Update to new version

To update the debian package to a new version use the following steps:

1. checkout the debian branch
1. merge the master branch (or the version tag if available) into the debian branch
1. adapt the file debian/changelog by adding a new version (you could use dch or edit with vi)
1. commit the changes in debian/changelog into the debian branch

1. build the new package

if further changes in the /debian directory are necessary, you commit them into the
debian branch and adapt the debian/changelog file. Do not forget to increment the build number !

## Versioning

The debian package version consists of the program version (x.y.z), a dash and the
build number (eg. 2.0.6-1 is the first build of 2.0.6 program version).
