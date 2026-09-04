# linux-gts9wifi: mainline kernel for the Samsung Galaxy Tab S9 Wi-Fi.
# Built from an already-prepared tree (kernel/prepare.sh runs in the workflow
# and the result is fed in as Source0).  Translation of the postmarketOS
# APKBUILD package() to RPM.
%define flavor gts9wifi
%define debug_package %{nil}
%define kversion 7.2.0-rc3

Name:           linux-%{flavor}
Version:        7.2.0
Release:        0.2.rc3%{?dist}
Summary:        Mainline Linux kernel for Samsung Galaxy Tab S9 Wi-Fi (gts9wifi)
License:        GPL-2.0-only
URL:            https://www.kernel.org
BuildArch:      aarch64
ExclusiveArch:  aarch64
Provides:       kernel-uname-r
AutoReqProv:    no

Source0:        linux-prepared.tar.gz

%description
Mainline %{kversion} plus the gts9wifi port patch set: FTS1BA90A touch,
ANA38407 panel, SM5714/SM5440/PS5169 power & Type-C, Wacom WEZ01 pen,
Samsung-specific display/PCIe/WCN fixes.  Identical sources to the running
postmarketOS build, repackaged so Fedora can own the kernel.  The uname is
%{kversion}-%{flavor} (localversion), distinct from the pmOS kernel so both
module trees can coexist during the transition.

%prep
%setup -q -n linux-prepared

%build
unset LDFLAGS
make ARCH=arm64 LLVM=1 %{?_smp_mflags} \
     KBUILD_BUILD_VERSION="%{release}.%{flavor}"

%install
# The boot files are installed directly, not via "make zinstall": zinstall
# routes through the build host's installkernel/kernel-install hooks, and
# the rolling Fedora 44 CI container grew a 50-dracut.install that fails
# hard inside rpmbuild (no /lib/modules at the container root).  The hook
# chain produced nothing beyond these two files anyway.
krel=$(make ARCH=arm64 kernelrelease)
make ARCH=arm64 LLVM=1 \
     modules_install dtbs_install \
     INSTALL_MOD_PATH=%{buildroot}/usr \
     INSTALL_DTBS_PATH=%{buildroot}/boot/dtbs-%{kversion}-%{flavor} \
     INSTALL_MOD_STRIP=1
install -Dm0644 arch/arm64/boot/vmlinuz %{buildroot}/boot/vmlinuz-$krel
install -Dm0644 System.map %{buildroot}/boot/System.map-$krel

depmod -b %{buildroot}/usr -a %{kversion}-%{flavor}
rm -f %{buildroot}/usr/lib/modules/*/build %{buildroot}/usr/lib/modules/*/source

%files
%license COPYING
/boot/*
/usr/lib/modules/*

%changelog
* Sat Aug 29 2026 nacht20-de <318505313+nacht20-de@users.noreply.github.com> - 7.2.0-0.1.rc3
- First RPM packaging of the gts9wifi mainline kernel (pmOS APKBUILD translation).
