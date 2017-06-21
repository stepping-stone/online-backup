Name:    onlinebackup
Version: 2.0.5
Release: 1%{?dist}
Summary: stepping stone onlinebackup tool
URL:     https://github.com/stepping-stone/online-backup
License: EUPL 1.1
BuildArch: noarch
Vendor: stepping stone GmbH

Source0: https://github.com/stepping-stone/online-backup/archive/v%{version}.tar.gz

%description
This is the stepping stone GmbH online-backup utility.

%prep
%setup -n online-backup-%{version}

%build

%install
mkdir -p %{buildroot}%{_bindir}/
mkdir -p %{buildroot}%{perl_vendorlib}/
mkdir -p %{buildroot}%{_sysconfdir}/OnlineBackup/
mkdir -p %{buildroot}%{_defaultdocdir}/%{name}-%{version}/

install -m 755 bin/*.pl %{buildroot}%{_bindir}/
install -m 755 bin/*.sh %{buildroot}%{_bindir}/
install -m 644 bin/*.pm %{buildroot}%{perl_vendorlib}/
install -m 644 conf/*   %{buildroot}%{_sysconfdir}/OnlineBackup/
install -m 644 doc/*    %{buildroot}%{_defaultdocdir}/%{name}-%{version}/

%files
%{_bindir}/OnlineBackup.pl
%{_bindir}/OnlineRestore.pl
%{_bindir}/OnlineRestore.sh
%{perl_vendorlib}/OLBUtils.pm
%{_sysconfdir}/OnlineBackup/
%config(noreplace) %{_sysconfdir}/OnlineBackup/*
%config(noreplace) %{_defaultdocdir}/%{name}-%{version}/
%{_defaultdocdir}/%{name}-%{version}/*

%clean
rm -rf %{buildroot}
