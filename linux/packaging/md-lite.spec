# The binary is stripped and built with LTO; there is no separate debug info to package.
%global debug_package %{nil}
%global app_id io.github.glozahn.MDLite

Name:           md-lite
Version:        0.4.0
Release:        1%{?dist}
Summary:        A lightweight, native Markdown reader and editor

License:        MIT
URL:            https://github.com/glozahn/md-lite
Source0:        %{name}-%{version}.tar.gz

BuildRequires:  cargo >= 1.82
BuildRequires:  rust >= 1.82
BuildRequires:  make
BuildRequires:  pkgconfig(gtk4) >= 4.14
BuildRequires:  pkgconfig(libadwaita-1) >= 1.6
BuildRequires:  pkgconfig(webkitgtk-6.0)
BuildRequires:  pkgconfig(libsoup-3.0)
BuildRequires:  desktop-file-utils
BuildRequires:  appstream

Requires:       hicolor-icon-theme

%description
MD Lite reads and edits GitHub Flavored Markdown in a calm, native GTK 4 window:
Reading, Editor, Source and Split modes, tables, task lists, alerts, raw HTML,
syntax highlighting and Mermaid diagrams drawn offline. Tabs, side-by-side panes,
working folders, autosave and export to HTML and PDF.

%prep
%autosetup -n %{name}-%{version}

%build
cd linux
make build TARGET_DIR=%{_builddir}/%{name}-%{version}/linux/target

%install
cd linux
make install DESTDIR=%{buildroot} PREFIX=%{_prefix} TARGET_DIR=%{_builddir}/%{name}-%{version}/linux/target

%check
desktop-file-validate %{buildroot}%{_datadir}/applications/%{app_id}.desktop
appstreamcli validate --no-net %{buildroot}%{_metainfodir}/%{app_id}.metainfo.xml

%files
%doc README.md CHANGELOG.md
%{_bindir}/md-lite
%{_datadir}/applications/%{app_id}.desktop
%{_metainfodir}/%{app_id}.metainfo.xml
%{_datadir}/icons/hicolor/scalable/apps/%{app_id}.svg
%{_datadir}/icons/hicolor/symbolic/apps/%{app_id}-symbolic.svg
%dir %{_datadir}/licenses/md-lite
%license %{_datadir}/licenses/md-lite/LICENSE
%license %{_datadir}/licenses/md-lite/mermaid-LICENSE

%changelog
* Thu Oct 08 2026 MD Lite contributors - 0.4.0-1
- Version in step with the macOS release

* Thu Oct 08 2026 MD Lite contributors - 0.3.8-1
- Version in step with the macOS release

* Thu Oct 08 2026 MD Lite contributors - 0.3.7-1
- Version in step with the macOS release

* Wed Oct 07 2026 MD Lite contributors - 0.3.6-1
- First release of its own, with packages built in CI
- Checking a task in the reader no longer freezes the app

* Wed Oct 07 2026 MD Lite contributors - 0.3.5-1
- First native GTK 4 build for Linux
