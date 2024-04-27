## Private repository of Arch Linux packages
This is a repository of packages I maintain for my own machnies. It is self-contained and includes a compact set of maintenance tools.

### Dependencies
* just
* fish
* devtools
* jq

### Repository configuration
```ini
[aur]
SigLevel = Required
Server = https://repo.pierre-schmitz.com/$repo/os/$arch

[aur-restricted]
SigLevel = Required
Server = https://<user>:<password>@repo.pierre-schmitz.com/$repo/os/$arch
```
